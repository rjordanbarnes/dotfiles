import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const maxBroadcastCharacters = 32_000;
const defaultKarState = path.join(
	process.env.LOCALAPPDATA ?? path.join(os.homedir(), 'AppData', 'Local'),
	'dev.local.kar'
);
const defaultCompanyRoot = 'C:\\code\\piston-company';
const defaultStatePath = path.join(
	process.env.LOCALAPPDATA ?? path.join(os.homedir(), 'AppData', 'Local'),
	'Ditzy',
	'Broadcast',
	'state.json'
);

export function validateBroadcastMessage(message) {
	if (typeof message !== 'string') throw new Error('Broadcast message must be text.');
	if (!message.trim()) throw new Error('Broadcast message cannot be empty.');
	if ([...message].length > maxBroadcastCharacters) {
		throw new Error(`Broadcast message must be ${maxBroadcastCharacters} characters or fewer.`);
	}
	if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(message)) {
		throw new Error(
			'Broadcast message cannot contain terminal control characters other than tabs and line breaks.'
		);
	}
	return message;
}

export function deterministicUuid(value) {
	const bytes = Buffer.from(createHash('sha256').update(value).digest().subarray(0, 16));
	bytes[6] = (bytes[6] & 0x0f) | 0x50;
	bytes[8] = (bytes[8] & 0x3f) | 0x80;
	const hex = bytes.toString('hex');
	return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function readJson(file, fallback) {
	try {
		return JSON.parse(await readFile(file, 'utf8'));
	} catch (error) {
		if (error.code === 'ENOENT') return fallback;
		throw error;
	}
}

async function writeJsonAtomic(file, value) {
	await mkdir(path.dirname(file), { recursive: true });
	const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
	await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
	await rename(temporary, file);
}

function daemonRequest(socketName, auth, request) {
	return new Promise((resolve, reject) => {
		const socket = net.createConnection(`\\\\.\\pipe\\${socketName}`);
		let response = '';
		socket.setEncoding('utf8');
		socket.once('connect', () => {
			socket.write(`${JSON.stringify({ id: 1, auth, request })}\n`);
		});
		socket.on('data', (chunk) => (response += chunk));
		socket.once('error', reject);
		socket.once('end', () => {
			try {
				const message = JSON.parse(response.trim());
				if (message.error) reject(new Error(message.error));
				else resolve(message.result);
			} catch (error) {
				reject(error);
			}
		});
	});
}

async function broadcastToKar(message, broadcastId, stateDirectory) {
	const databasePath = path.join(stateDirectory, 'workspace.sqlite3');
	if (!existsSync(databasePath)) throw new Error('Kar workspace state is unavailable.');
	const database = new DatabaseSync(databasePath, { readOnly: true });
	let source;
	try {
		source = database
			.prepare(
				`SELECT tabs.id, tabs.session_id, tabs.run_token
				 FROM tabs
				 LEFT JOIN tab_awakeness ON tab_awakeness.tab_id = tabs.id
				 WHERE tabs.run_token IS NOT NULL AND tab_awakeness.tab_id IS NULL
				 ORDER BY tabs.position
				 LIMIT 1`
			)
			.get();
	} finally {
		database.close();
	}
	if (!source) throw new Error('No awake Kar runtime is available to send the broadcast.');
	const auth = (await readFile(path.join(stateDirectory, 'daemon-token'), 'utf8')).trim();
	if (!auth) throw new Error('Kar daemon token is empty.');
	const socketName = `kar-${databasePath.replace(/[\\/:]/g, '-')}`;
	const current = await daemonRequest(socketName, auth, { type: 'snapshot' });
	const snapshot = current?.snapshot;
	if (current?.type !== 'snapshot' || !snapshot?.epoch || !Number.isInteger(snapshot.revision)) {
		throw new Error('Kar did not return a versioned workspace snapshot.');
	}
	const reply = await daemonRequest(socketName, auth, {
		type: 'operate',
		operation: {
			operationId: broadcastId,
			actor: 'ditzy-broadcast-mcp',
			base: { epoch: snapshot.epoch, revision: snapshot.revision },
			command: {
				type: 'broadcast-message',
				id: broadcastId,
				sourceTab: source.id,
				sourceToken: source.run_token,
				message
			}
		}
	});
	if (reply?.type !== 'operation' || reply.outcome?.type !== 'broadcast-queued') {
		throw new Error('Kar did not confirm the broadcast.');
	}
	return {
		broadcastId: reply.outcome.broadcastId,
		recipientCount: reply.outcome.recipientCount,
		excludedSourceSessionId: source.session_id
	};
}

function companyRecipients(companyRoot) {
	const configPath = path.join(companyRoot, 'company.config.json');
	if (!existsSync(configPath)) return [];
	const config = JSON.parse(readFileSync(configPath, 'utf8'));
	return config.employees
		.filter((employee) => employee.kind === 'agent')
		.map((employee) => ({
			employeeId: employee.id,
			sessionId: employee.sessionId ?? null
		}));
}

function queueCompanyMessage(companyRoot, recipient, subject, message) {
	const environment = { ...process.env };
	delete environment.COMPANY_EMPLOYEE_ID;
	const result = spawnSync(
		process.execPath,
		[
			path.join(companyRoot, 'bin', 'company.mjs'),
			'send',
			recipient.employeeId,
			'--subject',
			subject,
			'--body',
			message
		],
		{
			cwd: companyRoot,
			env: environment,
			encoding: 'utf8',
			windowsHide: true
		}
	);
	if (result.status !== 0) {
		throw new Error(
			result.stderr.trim() || result.stdout.trim() || `Company send exited ${result.status}.`
		);
	}
	const match = /Queued message (\d+) for/u.exec(result.stdout);
	if (!match) throw new Error(`Could not parse company message result: ${result.stdout.trim()}`);
	return Number(match[1]);
}

export async function broadcastMessage(message, options = {}) {
	validateBroadcastMessage(message);
	const karStateDirectory = options.karStateDirectory ?? process.env.DITZY_KAR_STATE_DIR ?? defaultKarState;
	const companyRoot = options.companyRoot ?? process.env.DITZY_COMPANY_ROOT ?? defaultCompanyRoot;
	const statePath = options.statePath ?? process.env.DITZY_BROADCAST_STATE ?? defaultStatePath;
	const idempotencyKey = options.idempotencyKey ?? null;
	const broadcastId = idempotencyKey ? deterministicUuid(idempotencyKey) : randomUUID();
	const state = await readJson(statePath, { version: 1, broadcasts: {} });
	const entry = state.broadcasts[broadcastId] ?? {
		messageHash: createHash('sha256').update(message).digest('hex'),
		companyMessages: {}
	};
	if (entry.messageHash !== createHash('sha256').update(message).digest('hex')) {
		throw new Error('Broadcast idempotency key was reused for another message.');
	}
	if (entry.completed) return entry.result;

	if (process.env.DITZY_BROADCAST_DRY_RUN === '1') {
		return {
			broadcastId,
			karRecipientCount: 0,
			liveSessionIds: companyRecipients(companyRoot)
				.map((recipient) => recipient.sessionId)
				.filter(Boolean),
			companyMessages: [],
			dryRun: true
		};
	}

	if (!entry.kar) {
		entry.kar = await broadcastToKar(message, broadcastId, karStateDirectory);
		state.broadcasts[broadcastId] = entry;
		await writeJsonAtomic(statePath, state);
	}

	const subject = options.subject ?? `Ditzy broadcast ${broadcastId.slice(0, 8)}`;
	const recipients = companyRecipients(companyRoot);
	for (const recipient of recipients) {
		if (entry.companyMessages[recipient.employeeId]) continue;
		entry.companyMessages[recipient.employeeId] = {
			messageId: queueCompanyMessage(companyRoot, recipient, subject, message),
			sessionId: recipient.sessionId
		};
		state.broadcasts[broadcastId] = entry;
		await writeJsonAtomic(statePath, state);
	}

	const liveSessionIds = new Set(
		recipients.map((recipient) => recipient.sessionId).filter(Boolean)
	);
	if (entry.kar.excludedSourceSessionId) {
		liveSessionIds.add(entry.kar.excludedSourceSessionId);
	}
	const result = {
		broadcastId,
		karRecipientCount: entry.kar.recipientCount,
		excludedSourceSessionId: entry.kar.excludedSourceSessionId,
		liveSessionIds: [...liveSessionIds],
		companyMessages: Object.entries(entry.companyMessages).map(([employeeId, value]) => ({
			employeeId,
			...value
		}))
	};
	entry.completed = true;
	entry.result = result;
	state.broadcasts[broadcastId] = entry;
	await writeJsonAtomic(statePath, state);
	return result;
}

const tool = {
	name: 'broadcast_message',
	title: 'Broadcast a verbatim user message to every persona',
	description:
		'Use only when the user explicitly asks to broadcast. Pass message exactly with no added text. This durably queues Kar and piston-company delivery. After success, immediately send the same original message verbatim with send_session_message to every liveSessionId returned, including excludedSourceSessionId, so active standalone personas receive it now.',
	inputSchema: {
		type: 'object',
		properties: {
			message: {
				type: 'string',
				maxLength: maxBroadcastCharacters,
				description: 'The exact verbatim message the user asked to broadcast.'
			},
			subject: {
				type: 'string',
				description: 'Optional short durable company-inbox subject.'
			},
			idempotencyKey: {
				type: 'string',
				description: 'Optional stable key for retry-safe automated broadcasts.'
			}
		},
		required: ['message'],
		additionalProperties: false
	}
};

function send(message) {
	process.stdout.write(`${JSON.stringify(message)}\n`);
}

async function runMcp() {
	const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
	for await (const line of lines) {
		if (!line.trim()) continue;
		const request = JSON.parse(line);
		if (request.method === 'notifications/initialized' || request.method === 'notifications/cancelled') {
			continue;
		}
		if (request.id === undefined) continue;
		try {
			switch (request.method) {
				case 'initialize':
					send({
						jsonrpc: '2.0',
						id: request.id,
						result: {
							protocolVersion: request.params?.protocolVersion ?? '2025-11-25',
							capabilities: { tools: {} },
							serverInfo: { name: 'ditzy-broadcast', version: '1.0.0' },
							instructions:
								'Broadcast only explicit user messages verbatim. After calling the tool, relay the original message to every returned liveSessionId with send_session_message.'
						}
					});
					break;
				case 'ping':
					send({ jsonrpc: '2.0', id: request.id, result: {} });
					break;
				case 'tools/list':
					send({ jsonrpc: '2.0', id: request.id, result: { tools: [tool] } });
					break;
				case 'tools/call': {
					if (request.params?.name !== tool.name) {
						throw new Error(`Unknown tool: ${request.params?.name ?? ''}`);
					}
					const args = request.params.arguments ?? {};
					const result = await broadcastMessage(args.message, {
						subject: args.subject,
						idempotencyKey: args.idempotencyKey
					});
					send({
						jsonrpc: '2.0',
						id: request.id,
						result: {
							content: [
								{
									type: 'text',
									text: `Broadcast queued for ${result.karRecipientCount} Kar recipients and ${result.companyMessages.length} company personas. Relay it verbatim to ${result.liveSessionIds.length} live session(s).`
								}
							],
							structuredContent: result
						}
					});
					break;
				}
				default:
					send({
						jsonrpc: '2.0',
						id: request.id,
						error: { code: -32601, message: `Method not found: ${request.method}` }
					});
			}
		} catch (error) {
			send({
				jsonrpc: '2.0',
				id: request.id,
				result: {
					content: [{ type: 'text', text: String(error) }],
					isError: true
				}
			});
		}
	}
}

async function runCli() {
	const fileIndex = process.argv.indexOf('--message-file');
	if (fileIndex === -1 || !process.argv[fileIndex + 1]) {
		throw new Error('CLI usage requires --message-file <path>.');
	}
	const message = await readFile(process.argv[fileIndex + 1], 'utf8');
	const subjectIndex = process.argv.indexOf('--subject');
	const idempotencyIndex = process.argv.indexOf('--idempotency-key');
	const result = await broadcastMessage(message, {
		subject: subjectIndex === -1 ? undefined : process.argv[subjectIndex + 1],
		idempotencyKey:
			idempotencyIndex === -1 ? undefined : process.argv[idempotencyIndex + 1]
	});
	process.stdout.write(`${JSON.stringify(result)}\n`);
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
	if (process.argv.length > 2) await runCli();
	else await runMcp();
}
