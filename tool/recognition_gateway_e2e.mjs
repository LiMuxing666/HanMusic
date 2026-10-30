// Offline end-to-end acceptance: actual Dart client -> Node gateway -> local
// AudD fixture. Only a generated tone and a deliberately fake server secret.
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRecognitionServer } from '../server/recognition/src/server.js';

const root = fileURLToPath(new URL('../', import.meta.url));
const dart = process.argv[2] || 'dart';
const work = await mkdtemp(join(tmpdir(), 'hanmusic-gateway-e2e-'));
const secret = 'backend-only-fixture-secret';
let upstreamCalls = 0;
let upstreamHasSecret = false;
let clientHasSecret = false;
let rawWavReceived = false;
let gateway;
const upstream = http.createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = Buffer.concat(chunks);
  upstreamCalls++;
  upstreamHasSecret = body.includes(Buffer.from(secret)) && body.includes(Buffer.from('name="api_token"'));
  body.fill(0);
  response.writeHead(200, { 'content-type': 'application/json' });
  response.end(JSON.stringify({ status: 'success', private_debug: secret, result: {
    title: '本地网关联调', artist: '合成测试', album: '部署验收', api_token: secret,
  } }));
});

try {
  await new Promise((done) => upstream.listen(0, '127.0.0.1', done));
  gateway = await createRecognitionServer({
    nodeEnv: 'test', token: secret, port: 0,
    budgetFile: join(work, 'budget.json'),
    upstreamUrl: `http://127.0.0.1:${upstream.address().port}/`,
  });
  gateway.on('request', (request) => {
    const chunks = [];
    clientHasSecret ||= JSON.stringify(request.headers).includes(secret) || 'authorization' in request.headers;
    request.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
    request.on('end', () => {
      const body = Buffer.concat(chunks);
      rawWavReceived = request.headers['content-type'] === 'audio/wav' && body.toString('ascii', 0, 4) === 'RIFF';
      clientHasSecret ||= body.includes(Buffer.from(secret)) || body.includes(Buffer.from('api_token'));
      body.fill(0);
      for (const chunk of chunks) chunk.fill(0);
    });
  });
  await new Promise((done) => gateway.listen(0, '127.0.0.1', done));
  const endpoint = `http://127.0.0.1:${gateway.address().port}/v1/recognize`;
  const output = await new Promise((done, reject) => {
    const child = spawn(dart, [resolve(root, 'tool/recognition_gateway_probe.dart'), endpoint], { cwd: root, windowsHide: true });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => { child.kill(); reject(new Error('Dart client timed out')); }, 45000);
    child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
    child.on('error', (error) => { clearTimeout(timer); reject(error); });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code !== 0) reject(new Error(`Dart client failed (${code}): ${stderr.slice(0, 500)}`));
      else done(stdout);
    });
  });
  const result = JSON.parse(output.trim());
  assert.equal(result.gatewayResponded, true);
  assert.equal(result.title, '本地网关联调');
  assert.equal(output.includes(secret), false);
  assert.equal(upstreamCalls, 1);
  assert.equal(rawWavReceived, true);
  assert.equal(clientHasSecret, false);
  assert.equal(upstreamHasSecret, true);
  assert.equal(JSON.parse(await readFile(join(work, 'budget.json'), 'utf8')).used, 1);
  console.log(JSON.stringify({ passed: true, chain: 'Dart client -> Node gateway -> local upstream fixture', rawWavReceived, clientHasSecret, upstreamHasServerSecret: upstreamHasSecret, chargedBudgetSlots: 1, externalNetworkRequests: 0 }));
} finally {
  await gateway?.shutdown();
  await new Promise((done) => { upstream.close(done); upstream.closeAllConnections(); });
  // mkdtemp created this dedicated diagnostic directory; no user files enter it.
  const cleanupPath = resolve(work);
  if (dirname(cleanupPath) !== resolve(tmpdir()) || !basename(cleanupPath).startsWith('hanmusic-gateway-e2e-')) {
    throw new Error('Refusing to clean an unexpected diagnostic directory');
  }
  await rm(cleanupPath, { recursive: true, force: true });
}
