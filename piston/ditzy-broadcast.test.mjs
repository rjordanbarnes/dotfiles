import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
	broadcastMessage,
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

test('broadcast sends the exact message to switchboard announcements', async (t) => {
	const requests = [];
	const server = http.createServer((request, response) => {
		let body = '';
		request.setEncoding('utf8');
		request.on('data', (chunk) => (body += chunk));
		request.on('end', () => {
			requests.push({
				method: request.method,
				url: request.url,
				authorization: request.headers.authorization,
				body: body ? JSON.parse(body) : null
			});
			response.writeHead(200, { 'content-type': 'application/json' });
			if (request.url === '/v1/conversations') {
				response.end(
					JSON.stringify([
						{
							id: 'channel-announcements',
							slug: 'announcements'
						}
					])
				);
				return;
			}
			response.end(
				JSON.stringify({
					id: 'message-1',
					conversationId: 'channel-announcements',
					sequence: 7
				})
			);
		});
	});
	await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
	t.after(() => server.close());
	const address = server.address();
	assert(address && typeof address !== 'string');

	const directory = await mkdtemp(path.join(os.tmpdir(), 'ditzy-switchboard-'));
	t.after(() => rm(directory, { recursive: true, force: true }));
	const endpointFile = path.join(directory, 'api-endpoint');
	const credentialFile = path.join(directory, 'credential.json');
	await writeFile(endpointFile, `http://127.0.0.1:${address.port}`, 'utf8');
	await writeFile(
		credentialFile,
		JSON.stringify({
			principalId: 'ditzy',
			token: 'test-token',
			endpointFile
		}),
		'utf8'
	);

	const message = '  Send this exactly.\n';
	const result = await broadcastMessage(message, {
		credentialFile,
		idempotencyKey: 'same-announcement'
	});

	assert.equal(result.broadcastId, deterministicUuid('same-announcement'));
	assert.deepEqual(requests, [
		{
			method: 'GET',
			url: '/v1/conversations',
			authorization: 'Bearer test-token',
			body: null
		},
		{
			method: 'POST',
			url: '/v1/conversations/channel-announcements/messages',
			authorization: 'Bearer test-token',
			body: {
				operationId: deterministicUuid('same-announcement'),
				body: message
			}
		}
	]);
});

test('musings watcher debounces public changes and excludes private paths', async (t) => {
	const directory = await mkdtemp(path.join(os.tmpdir(), 'ditzy-musings-'));
	const root = path.join(directory, 'musings');
	const stateDirectory = path.join(directory, 'state');
	const companyDatabase = path.join(directory, 'company.db');
	await mkdir(path.join(root, 'private'), { recursive: true });
	await writeFile(path.join(root, 'first.md'), 'initial', 'utf8');
	await writeFile(path.join(root, 'private', 'secret.md'), 'never inspect', 'utf8');
	t.after(() => rm(directory, { recursive: true, force: true }));

	const snapshot = await snapshotMusings(root);
	assert.deepEqual(Object.keys(snapshot), ['first.md']);
	assert.equal(
		(await runWatcher({ root, stateDirectory, companyDatabase, now: 1_000 })).action,
		'baseline'
	);

	await writeFile(path.join(root, 'first.md'), 'updated', 'utf8');
	assert.equal(
		(await runWatcher({ root, stateDirectory, companyDatabase, now: 2_000 })).action,
		'debouncing'
	);
	assert.equal(
		(
			await runWatcher({
				root,
				stateDirectory,
				companyDatabase,
				now: 2_000 + 5 * 60_000 - 1
			})
		).action,
		'waiting'
	);

	const calls = [];
	const result = await runWatcher({
		root,
		stateDirectory,
		companyDatabase,
		now: 2_000 + 5 * 60_000,
		broadcast: async (message, options) => {
			calls.push({ message, options });
			return {
				broadcastId: 'broadcast-id',
				conversationId: 'channel-announcements',
				messageId: 'message-1'
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
				conversationId: 'channel-announcements',
				messageId: 'message-1'
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
