import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
	deterministicUuid,
	validateBroadcastMessage
} from './ditzy-broadcast.mjs';
import {
	composeBroadcast,
	runWatcher,
	snapshotMusings
} from './musings-watcher.mjs';

test('broadcast validation preserves text and rejects unsafe controls', () => {
	const message = '  exact\nmessage\t ';
	assert.equal(validateBroadcastMessage(message), message);
	assert.throws(() => validateBroadcastMessage(' \n\t'), /cannot be empty/u);
	assert.throws(() => validateBroadcastMessage('bad\u0000message'), /control characters/u);
	assert.equal(
		deterministicUuid('same-key'),
		deterministicUuid('same-key')
	);
	assert.notEqual(
		deterministicUuid('same-key'),
		deterministicUuid('other-key')
	);
});

test('musings watcher debounces public changes and excludes private paths', async (t) => {
	const directory = await mkdtemp(path.join(os.tmpdir(), 'ditzy-musings-'));
	const root = path.join(directory, 'musings');
	const stateDirectory = path.join(directory, 'state');
	await mkdir(path.join(root, 'private'), { recursive: true });
	await writeFile(path.join(root, 'first.md'), 'initial', 'utf8');
	await writeFile(path.join(root, 'private', 'secret.md'), 'never inspect', 'utf8');
	t.after(() => rm(directory, { recursive: true, force: true }));

	const snapshot = await snapshotMusings(root);
	assert.deepEqual(Object.keys(snapshot), ['first.md']);
	assert.equal(
		(await runWatcher({ root, stateDirectory, now: 1_000 })).action,
		'baseline'
	);

	await writeFile(path.join(root, 'first.md'), 'updated', 'utf8');
	assert.equal(
		(await runWatcher({ root, stateDirectory, now: 2_000 })).action,
		'debouncing'
	);
	assert.equal(
		(
			await runWatcher({
				root,
				stateDirectory,
				now: 2_000 + 5 * 60_000 - 1
			})
		).action,
		'waiting'
	);

	const calls = [];
	const result = await runWatcher({
		root,
		stateDirectory,
		now: 2_000 + 5 * 60_000,
		broadcast: async (message, options) => {
			calls.push({ message, options });
			return {
				broadcastId: 'broadcast-id',
				karRecipientCount: 2,
				companyMessages: []
			};
		}
	});
	assert.equal(result.action, 'broadcast');
	assert.equal(calls.length, 1);
	assert.match(calls[0].message, /user\/musings\/first\.md/u);
	assert.match(calls[0].message, /piston\/user\/private remains private/u);
	assert.match(calls[0].options.idempotencyKey, /^musings-/u);
});

test('tenants changes use the urgent quiet period', async (t) => {
	const directory = await mkdtemp(path.join(os.tmpdir(), 'ditzy-tenants-'));
	const root = path.join(directory, 'musings');
	const stateDirectory = path.join(directory, 'state');
	await mkdir(root, { recursive: true });
	await writeFile(path.join(root, 'tenants.md'), 'initial', 'utf8');
	t.after(() => rm(directory, { recursive: true, force: true }));
	await runWatcher({ root, stateDirectory, now: 1_000 });
	await writeFile(path.join(root, 'tenants.md'), 'updated', 'utf8');
	await runWatcher({ root, stateDirectory, now: 2_000 });

	const calls = [];
	const waiting = await runWatcher({
		root,
		stateDirectory,
		now: 61_999,
		broadcast: async () => {
			throw new Error('not due');
		}
	});
	assert.equal(waiting.action, 'waiting');
	const sent = await runWatcher({
		root,
		stateDirectory,
		now: 62_000,
		broadcast: async (message) => {
			calls.push(message);
			return {
				broadcastId: 'urgent-broadcast',
				karRecipientCount: 2,
				companyMessages: []
			};
		}
	});
	assert.equal(sent.action, 'broadcast');
	assert.match(calls[0], /^Time-sensitive:/u);
	assert.match(
		composeBroadcast([{ file: 'tenants.md' }], true),
		/user\/musings\/tenants\.md/u
	);
});
