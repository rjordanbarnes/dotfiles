import { createHash, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const maxBroadcastCharacters = 32_000;
const defaultCredentialFile = path.join(
	process.env.APPDATA ?? path.join(os.homedir(), 'AppData', 'Roaming'),
	'dev.piston.switchboard',
	'agents',
	'ditzy',
	'credential.json'
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

async function loadCredential(credentialFile) {
	const credential = JSON.parse(await readFile(credentialFile, 'utf8'));
	if (
		credential.principalId !== 'ditzy' ||
		typeof credential.token !== 'string' ||
		typeof credential.endpointFile !== 'string'
	) {
		throw new Error('Ditzy Switchboard credential is invalid.');
	}
	const endpoint = (await readFile(credential.endpointFile, 'utf8')).trim();
	if (!endpoint.startsWith('http://127.0.0.1:')) {
		throw new Error('Switchboard API endpoint is unavailable.');
	}
	return { ...credential, endpoint };
}

async function switchboardRequest(credential, route, options = {}) {
	const response = await fetch(`${credential.endpoint}${route}`, {
		...options,
		headers: {
			authorization: `Bearer ${credential.token}`,
			...(options.body ? { 'content-type': 'application/json' } : {}),
			...options.headers
		}
	});
	const body = await response.text();
	const value = body ? JSON.parse(body) : null;
	if (!response.ok) {
		throw new Error(value?.error || `Switchboard request failed with HTTP ${response.status}.`);
	}
	return value;
}

export async function broadcastMessage(message, options = {}) {
	validateBroadcastMessage(message);
	const credentialFile =
		options.credentialFile ??
		process.env.SWITCHBOARD_CREDENTIAL_FILE ??
		defaultCredentialFile;
	const broadcastId = options.idempotencyKey
		? deterministicUuid(options.idempotencyKey)
		: randomUUID();
	const credential = await loadCredential(credentialFile);
	const conversations = await switchboardRequest(credential, '/v1/conversations');
	const announcements = conversations.find(
		(conversation) => conversation.slug === 'announcements'
	);
	if (!announcements) {
		throw new Error('Switchboard #announcements is unavailable.');
	}
	const sent = await switchboardRequest(
		credential,
		`/v1/conversations/${encodeURIComponent(announcements.id)}/messages`,
		{
			method: 'POST',
			body: JSON.stringify({
				operationId: broadcastId,
				body: message
			})
		}
	);
	return {
		broadcastId,
		conversationId: announcements.id,
		messageId: sent.id,
		sequence: sent.sequence
	};
}

const tool = {
	name: 'broadcast_message',
	title: 'Broadcast a verbatim user message to every persona',
	description:
		'Use only when the user explicitly asks to broadcast. Pass message exactly with no added text. Switchboard persists it in #announcements for every Piston persona.',
	inputSchema: {
		type: 'object',
		properties: {
			message: {
				type: 'string',
				maxLength: maxBroadcastCharacters,
				description: 'The exact verbatim message the user asked to broadcast.'
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
							serverInfo: { name: 'ditzy-broadcast', version: '2.0.0' },
							instructions:
								'Broadcast only explicit user messages verbatim through Switchboard #announcements.'
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
						idempotencyKey: args.idempotencyKey
					});
					send({
						jsonrpc: '2.0',
						id: request.id,
						result: {
							content: [
								{
									type: 'text',
									text: `Broadcast persisted to Switchboard #announcements as message ${result.messageId}.`
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
	const idempotencyIndex = process.argv.indexOf('--idempotency-key');
	const result = await broadcastMessage(message, {
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
