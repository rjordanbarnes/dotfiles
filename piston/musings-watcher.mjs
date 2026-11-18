import { createHash, randomUUID } from 'node:crypto';
import { appendFile, mkdir, readFile, readdir, rename, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { broadcastMessage } from './ditzy-broadcast.mjs';

const publicTextExtensions = new Set(['.md', '.txt', '.json', '.yaml', '.yml']);
const urgentPattern =
	/\b(urgent|time[- ]sensitive|immediately|asap|today|breaking|security|blocker|stop work)\b/iu;
const defaultRoot = 'C:\\code\\piston\\user\\musings';
const defaultStateDirectory = path.join(
	process.env.LOCALAPPDATA ?? path.join(os.homedir(), 'AppData', 'Local'),
	'Ditzy',
	'MusingsWatcher'
);

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

async function logEvent(logPath, event) {
	await mkdir(path.dirname(logPath), { recursive: true });
	try {
		if ((await stat(logPath)).size > 1024 * 1024) {
			await writeFile(logPath, '', 'utf8');
		}
	} catch (error) {
		if (error.code !== 'ENOENT') throw error;
	}
	await appendFile(
		logPath,
		`${JSON.stringify({ timestamp: new Date().toISOString(), ...event })}\n`,
		'utf8'
	);
}

function isPrivate(relativePath) {
	return relativePath
		.split(/[\\/]/u)
		.some((segment) => segment.toLowerCase() === 'private');
}

async function walk(directory, root, files) {
	for (const entry of await readdir(directory, { withFileTypes: true })) {
		if (entry.name.startsWith('.')) continue;
		const fullPath = path.join(directory, entry.name);
		const relativePath = path.relative(root, fullPath);
		if (isPrivate(relativePath)) continue;
		if (entry.isDirectory()) {
			await walk(fullPath, root, files);
			continue;
		}
		if (!entry.isFile() || entry.name.endsWith('~') || entry.name.endsWith('.tmp')) continue;
		const data = await readFile(fullPath);
		const metadata = await stat(fullPath);
		files[relativePath.replaceAll('\\', '/')] = {
			hash: createHash('sha256').update(data).digest('hex'),
			size: data.length,
			mtimeMs: Math.trunc(metadata.mtimeMs),
			urgent:
				path.basename(fullPath).toLowerCase() === 'tenants.md' ||
				(publicTextExtensions.has(path.extname(fullPath).toLowerCase()) &&
					urgentPattern.test(data.toString('utf8')))
		};
	}
}

export async function snapshotMusings(root) {
	const files = {};
	await walk(root, root, files);
	return files;
}

export function diffSnapshots(previous, current) {
	const paths = new Set([...Object.keys(previous), ...Object.keys(current)]);
	return [...paths]
		.filter((file) => previous[file]?.hash !== current[file]?.hash)
		.sort()
		.map((file) => ({
			file,
			type: previous[file] ? (current[file] ? 'updated' : 'deleted') : 'created',
			urgent: Boolean(current[file]?.urgent)
		}));
}

export function composeBroadcast(changes, urgent) {
	const listed = changes.slice(0, 5).map((change) => `user/musings/${change.file}`);
	const remaining = changes.length - listed.length;
	const files = `${listed.join(', ')}${remaining > 0 ? `, and ${remaining} more` : ''}`;
	return urgent
		? `Time-sensitive: Jordan updated ${files}. Review the newest public musing before continuing work that may be affected. piston/user/private remains private.`
		: `Jordan updated ${files}. Review the newest public musing when it fits your current work. piston/user/private remains private.`;
}

function companyIsBusy(companyDatabase) {
	try {
		const database = new DatabaseSync(companyDatabase, { readOnly: true });
		try {
			const runningTurns = database
				.prepare("SELECT COUNT(*) AS count FROM turns WHERE status = 'running'")
				.get().count;
			const activeWork = database
				.prepare(
					"SELECT COUNT(*) AS count FROM work_items WHERE status IN ('active', 'review', 'blocked')"
				)
				.get().count;
			return runningTurns > 0 || activeWork > 0;
		} finally {
			database.close();
		}
	} catch {
		return false;
	}
}

export async function runWatcher(options = {}) {
	const now = options.now ?? Date.now();
	const root = options.root ?? process.env.DITZY_MUSINGS_ROOT ?? defaultRoot;
	const stateDirectory =
		options.stateDirectory ?? process.env.DITZY_MUSINGS_STATE ?? defaultStateDirectory;
	const statePath = path.join(stateDirectory, 'state.json');
	const logPath = path.join(stateDirectory, 'watcher.log');
	const companyDatabase =
		options.companyDatabase ??
		process.env.DITZY_COMPANY_DATABASE ??
		'C:\\code\\piston\\company\\.company\\company.db';
	const broadcast = options.broadcast ?? broadcastMessage;
	const current = await snapshotMusings(root);
	const state = await readJson(statePath, null);
	if (!state) {
		await writeJsonAtomic(statePath, {
			version: 1,
			files: current,
			pending: null,
			lastBroadcast: null
		});
		await logEvent(logPath, { event: 'baseline', fileCount: Object.keys(current).length });
		return { action: 'baseline' };
	}

	const changes = diffSnapshots(state.files ?? {}, current);
	state.files = current;
	if (changes.length > 0) {
		const files = new Map(
			(state.pending?.changes ?? []).map((change) => [change.file, change])
		);
		for (const change of changes) files.set(change.file, change);
		state.pending = {
			id: state.pending?.id ?? `musings-${randomUUID()}`,
			firstChangedAt: state.pending?.firstChangedAt ?? now,
			lastChangedAt: now,
			urgent: Boolean(state.pending?.urgent || changes.some((change) => change.urgent)),
			changes: [...files.values()].sort((left, right) => left.file.localeCompare(right.file))
		};
		await writeJsonAtomic(statePath, state);
		await logEvent(logPath, {
			event: 'changes-detected',
			changeCount: changes.length,
			urgent: state.pending.urgent
		});
		return { action: 'debouncing', changes };
	}

	if (!state.pending) {
		await writeJsonAtomic(statePath, state);
		return { action: 'idle' };
	}
	const quietMilliseconds = state.pending.urgent ? 60_000 : 5 * 60_000;
	if (now - state.pending.lastChangedAt < quietMilliseconds) {
		return { action: 'waiting', remainingMilliseconds: quietMilliseconds - (now - state.pending.lastChangedAt) };
	}
	if (
		!state.pending.urgent &&
		now - state.pending.firstChangedAt < 30 * 60_000 &&
		companyIsBusy(companyDatabase)
	) {
		await logEvent(logPath, { event: 'deferred-for-builders' });
		return { action: 'deferred' };
	}

	const message = composeBroadcast(state.pending.changes, state.pending.urgent);
	const result = await broadcast(message, {
		idempotencyKey: state.pending.id
	});
	state.lastBroadcast = {
		at: now,
		id: state.pending.id,
		urgent: state.pending.urgent,
		files: state.pending.changes.map((change) => change.file),
		broadcastId: result.broadcastId,
		messageId: result.messageId
	};
	state.pending = null;
	await writeJsonAtomic(statePath, state);
	await logEvent(logPath, {
		event: 'broadcast-sent',
		broadcastId: result.broadcastId,
		messageId: result.messageId
	});
	return { action: 'broadcast', message, result };
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
	try {
		const result = await runWatcher();
		process.stdout.write(`${JSON.stringify(result)}\n`);
	} catch (error) {
		const logPath = path.join(
			process.env.DITZY_MUSINGS_STATE ?? defaultStateDirectory,
			'watcher.log'
		);
		await logEvent(logPath, { event: 'failure', error: String(error) });
		console.error(error);
		process.exitCode = 1;
	}
}
