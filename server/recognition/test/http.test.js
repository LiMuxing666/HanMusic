import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fixture, post, bodyOf, wav, TOKEN, deferred } from './helpers.js';

test('actual HTTP sends server token only upstream and trims successful metadata', async (t) => {
  let received;
  const f = await fixture(t, {}, async (request, response) => {
    received = { body: await bodyOf(request), headers: request.headers, url: request.url };
    response.end(JSON.stringify({ status: 'success', result: {
      title: ' Song ', artist: 'Artist', album: 'Album', release_date: '2020-01-02',
      secret: TOKEN, spotify: { token: TOKEN }, song_link: 'https://example.com/',
    }, debug: TOKEN }));
  });
  const health = await fetch(`${f.url}/healthz`);
  assert.deepEqual(await health.json(), { status: 'ok' });
  const audio = wav();
  const result = await post(f.url, audio, { authorization: 'never-forward-me' });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { status: 'success', result: { title: 'Song', artist: 'Artist', album: 'Album', release_date: '2020-01-02' } });
  assert.match(received.headers['content-type'], /^multipart\/form-data; boundary=hanmusic-/);
  assert.equal(received.headers.authorization, undefined);
  assert.equal(received.url, '/');
  assert(received.body.includes(Buffer.from(`name="api_token"\r\n\r\n${TOKEN}\r\n`)));
  assert(received.body.includes(Buffer.from('name="file"; filename="sample.wav"')));
  assert(received.body.includes(audio));
  assert(!JSON.stringify(result).includes(TOKEN));
  const budget = JSON.parse(await readFile(f.config.budgetFile));
  assert.equal(budget.used, 1);
  assert(!JSON.stringify(budget).includes(TOKEN));
});

test('missing token returns 503 without upstream call or quota consumption', async (t) => {
  let calls = 0;
  const f = await fixture(t, { token: '' }, (_request, response) => { calls++; response.end(); });
  assert.deepEqual((await post(f.url)).body, { status: 'error', error: { code: 'service_unavailable' } });
  assert.equal((await post(f.url)).status, 503);
  assert.equal(calls, 0);
  assert.equal(JSON.parse(await readFile(f.config.budgetFile)).used, 0);
});

test('no match remains a successful null result', async (t) => {
  const f = await fixture(t);
  assert.deepEqual(await post(f.url).then(({ status, body }) => ({ status, body })), {
    status: 200, body: { status: 'success', result: null },
  });
});

test('invalid audio, content type, compression and oversized body never reach upstream', async (t) => {
  let calls = 0;
  const f = await fixture(t, {}, (_request, response) => { calls++; response.end(); });
  for (const [audio, headers] of [
    [Buffer.from('not a WAV'), {}], [wav(), { 'content-type': 'application/json' }],
    [wav(), { 'content-encoding': 'gzip' }],
  ]) {
    const result = await post(f.url, audio, headers);
    assert.equal(result.status, 400);
    assert.equal(result.body.error.code, 'invalid_audio');
  }
  // Send the oversized declaration without uploading it. A client that keeps
  // streaming after an early rejection may receive a TCP reset instead; the
  // chunked test below separately verifies the actual streaming size cap.
  const oversized = await new Promise((resolve, reject) => {
    const request = http.request(`${f.url}/v1/recognize`, {
      method: 'POST', headers: { 'content-type': 'audio/wav', 'content-length': 8 * 1024 * 1024 + 1 },
    }, async (response) => resolve({ status: response.statusCode, body: JSON.parse((await bodyOf(response)).toString()) }));
    request.on('error', reject);
    request.flushHeaders();
  });
  assert.equal(oversized.status, 400);
  assert.equal(oversized.body.error.code, 'invalid_audio');
  assert.equal(calls, 0);
  assert.equal(JSON.parse(await readFile(f.config.budgetFile)).used, 0);
});

test('chunked body over 8 MiB is rejected with a bounded response', async (t) => {
  let calls = 0;
  const f = await fixture(t, {}, (_request, response) => { calls++; response.end(); });
  const result = await new Promise((resolve, reject) => {
    const request = http.request(`${f.url}/v1/recognize`, { method: 'POST', headers: { 'content-type': 'audio/wav' } }, async (response) => {
      resolve({ status: response.statusCode, body: JSON.parse((await bodyOf(response)).toString()) });
    });
    request.on('error', reject);
    request.write(Buffer.alloc(8 * 1024 * 1024));
    request.end(Buffer.alloc(100));
  });
  assert.equal(result.status, 400);
  assert.equal(result.body.error.code, 'invalid_audio');
  assert.equal(calls, 0);
});

test('upstream timeout aborts its socket and still spends daily budget', async (t) => {
  const closed = deferred();
  const f = await fixture(t, { upstreamTimeoutMs: 100 }, async (request, response) => {
    await bodyOf(request);
    response.once('close', closed.resolve);
  });
  const result = await post(f.url);
  assert.equal(result.status, 504);
  assert.equal(result.body.error.code, 'upstream_timeout');
  await closed.promise;
  assert.equal(JSON.parse(await readFile(f.config.budgetFile)).used, 1);
});

test('client disconnect cancels upstream and cannot refund its quota', async (t) => {
  const started = deferred();
  const closed = deferred();
  const f = await fixture(t, { dailyLimit: 1 }, async (request, response) => {
    await bodyOf(request);
    response.once('close', closed.resolve);
    started.resolve();
  });
  const request = http.request(`${f.url}/v1/recognize`, { method: 'POST', headers: { 'content-type': 'audio/wav' } });
  request.on('error', () => {});
  request.end(wav());
  await started.promise;
  request.destroy();
  await closed.promise;
  assert.equal((await post(f.url)).body.error.code, 'daily_limit');
});

test('upstream failures, token echoes, huge output and redirects are redacted', async (t) => {
  let mode = 'error';
  let calls = 0;
  const f = await fixture(t, { ipLimit: 100 }, async (request, response) => {
    await bodyOf(request); calls++;
    if (mode === 'error') { response.statusCode = 500; response.end(TOKEN); }
    if (mode === 'echo') response.end(JSON.stringify({ status: 'success', result: { title: TOKEN, artist: 'Artist' } }));
    if (mode === 'huge') { response.write(' '.repeat(1024 * 1024)); response.end(TOKEN); }
    if (mode === 'length') { response.writeHead(200, { 'content-length': 2 * 1024 * 1024 }); response.end(TOKEN); }
    if (mode === 'redirect') { response.writeHead(302, { location: f.config.upstreamUrl }); response.end(); }
    if (mode === 'invalid') response.end(`not JSON ${TOKEN}`);
    if (mode === 'limited') { response.statusCode = 429; response.end(TOKEN); }
  });
  for (mode of ['error', 'echo', 'huge', 'length', 'redirect', 'invalid', 'limited']) {
    const result = await post(f.url);
    assert.equal(result.status, mode === 'limited' ? 429 : 502, mode);
    assert(!JSON.stringify(result).includes(TOKEN));
    assert.deepEqual(Object.keys(result.body.error), ['code']);
  }
  assert.equal(calls, 7, 'redirect is not followed');
});

test('body read timeout closes an incomplete upload without upstream work', async (t) => {
  let calls = 0;
  const f = await fixture(t, { bodyTimeoutMs: 150 }, (_request, response) => { calls++; response.end(); });
  const result = await new Promise((resolve, reject) => {
    const request = http.request(`${f.url}/v1/recognize`, { method: 'POST', headers: { 'content-type': 'audio/wav' } }, async (response) => {
      resolve({ status: response.statusCode, body: JSON.parse((await bodyOf(response)).toString()) });
    });
    request.on('error', reject);
    request.write(wav().subarray(0, 44));
  });
  assert.equal(result.status, 400);
  assert.equal(result.body.error.code, 'invalid_audio');
  assert.equal(calls, 0);
});
