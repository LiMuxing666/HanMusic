import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, rename, mkdir, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRecognitionServer } from '../src/server.js';
import { readConfigFromEnv } from '../src/config.js';
import { fixture, post, bodyOf, deferred, listen } from './helpers.js';

test('daily limit is persisted before upstream and survives a server restart', async (t) => {
  let calls = 0;
  let file;
  const f = await fixture(t, { dailyLimit: 1 }, async (request, response) => {
    await bodyOf(request);
    calls++;
    assert.equal(JSON.parse(await readFile(file)).used, 1, 'debit precedes request');
    response.statusCode = 500;
    response.end();
  });
  file = f.config.budgetFile;
  assert.equal((await post(f.url)).status, 502);
  await f.server.shutdown();
  const restarted = await createRecognitionServer(f.config);
  t.after(() => restarted.shutdown());
  const url = await listen(restarted);
  assert.equal((await post(url)).body.error.code, 'daily_limit');
  assert.equal(calls, 1);
  assert.equal(JSON.parse(await readFile(file)).used, 1);
});

test('concurrent admissions cannot exceed the last daily slot', async (t) => {
  let calls = 0;
  const f = await fixture(t, { dailyLimit: 1, concurrency: 4 }, async (request, response) => {
    await bodyOf(request); calls++;
    response.end(JSON.stringify({ status: 'success', result: null }));
  });
  const results = await Promise.all(Array.from({ length: 4 }, () => post(f.url)));
  assert.equal(results.filter((result) => result.status === 200).length, 1);
  assert.equal(results.filter((result) => result.body.error?.code === 'daily_limit').length, 3);
  assert.equal(calls, 1);
  assert.equal(JSON.parse(await readFile(f.config.budgetFile)).used, 1);
});

test('per-IP admission is atomic and ignores client XFF by default', async (t) => {
  const f = await fixture(t, { ipLimit: 1, concurrency: 4 });
  const results = await Promise.all(Array.from({ length: 4 }, (_, index) =>
    post(f.url, undefined, { 'x-forwarded-for': `203.0.113.${index + 1}` })));
  assert.equal(results.filter((result) => result.status === 200).length, 1);
  assert.equal(results.filter((result) => result.body.error?.code === 'rate_limited').length, 3);
  assert.equal(JSON.parse(await readFile(f.config.budgetFile)).used, 1);
});

test('bounded IP cache fails closed and expires old hourly entries', async (t) => {
  let now = Date.parse('2026-10-30T12:00:00Z');
  const f = await fixture(t, { ipCacheSize: 1, ipLimit: 1, trustProxyLoopback: true, now: () => now });
  assert.equal((await post(f.url, undefined, { 'x-forwarded-for': '203.0.113.1' })).status, 200);
  assert.equal((await post(f.url, undefined, { 'x-forwarded-for': '203.0.113.2' })).body.error.code, 'rate_limited');
  now += 3600001;
  assert.equal((await post(f.url, undefined, { 'x-forwarded-for': '203.0.113.2' })).status, 200);
});

test('UTC daily rollover resets quota but a backwards clock cannot reset it', async (t) => {
  let now = Date.parse('2026-10-30T23:59:59Z');
  const f = await fixture(t, { dailyLimit: 1, now: () => now });
  assert.equal((await post(f.url)).status, 200);
  assert.equal((await post(f.url)).body.error.code, 'daily_limit');
  now += 2000;
  assert.equal((await post(f.url)).status, 200);
  assert.equal(JSON.parse(await readFile(f.config.budgetFile)).day, '2026-10-31');
  now -= 86400000;
  assert.equal((await post(f.url)).body.error.code, 'daily_limit');
});

test('two active uploads/upstream calls block a third without spending budget', async (t) => {
  const twoStarted = deferred();
  const responses = [];
  const f = await fixture(t, {}, async (request, response) => {
    await bodyOf(request);
    responses.push(response);
    if (responses.length === 2) twoStarted.resolve();
  });
  const first = post(f.url);
  const second = post(f.url);
  await twoStarted.promise;
  assert.equal((await post(f.url)).body.error.code, 'rate_limited');
  assert.equal(JSON.parse(await readFile(f.config.budgetFile)).used, 2);
  for (const response of responses) response.end(JSON.stringify({ status: 'success', result: null }));
  assert.equal((await first).status, 200);
  assert.equal((await second).status, 200);
});

test('budget write failure prevents upstream, stays fail-closed, and fails readiness', async (t) => {
  let calls = 0;
  const f = await fixture(t, {}, (_request, response) => { calls++; response.end(); });
  await rename(f.config.budgetFile, `${f.config.budgetFile}.saved`);
  await mkdir(f.config.budgetFile);
  assert.equal((await post(f.url)).body.error.code, 'service_unavailable');
  assert.equal((await post(f.url)).status, 503);
  const health = await fetch(`${f.url}/healthz`);
  assert.equal(health.status, 503);
  assert.deepEqual(await health.json(), { status: 'unavailable' });
  assert.equal(calls, 0);
});

test('corrupt persisted budget fails startup rather than silently resetting', async (t) => {
  const f = await fixture(t);
  await f.server.shutdown();
  await writeFile(f.config.budgetFile, '{broken budget');
  await assert.rejects(createRecognitionServer(f.config), /Budget storage unavailable/);
});

test('production env config starts without token and exposes readiness 503 without audio', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'hanmusic-prod-'));
  const config = readConfigFromEnv({ NODE_ENV: 'production', BUDGET_FILE: join(directory, 'budget.json') });
  const server = await createRecognitionServer(config);
  t.after(async () => { await server.shutdown(); await rm(directory, { recursive: true, force: true }); });
  const url = await listen(server);
  const health = await fetch(`${url}/healthz`);
  assert.equal(health.status, 503);
  assert.deepEqual(await health.json(), { status: 'unavailable' });
  assert.equal((await post(url)).status, 503);
  assert.equal(JSON.parse(await readFile(config.budgetFile)).used, 0);
});
