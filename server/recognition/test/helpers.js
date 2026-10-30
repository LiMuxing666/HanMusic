import http from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRecognitionServer } from '../src/server.js';

export const TOKEN = 'private-server-token-7f13';

export function wav(rate = 8000, seconds = 1) {
  const bytes = Buffer.alloc(44 + rate * seconds * 2);
  bytes.write('RIFF', 0);
  bytes.writeUInt32LE(bytes.length - 8, 4);
  bytes.write('WAVEfmt ', 8);
  bytes.writeUInt32LE(16, 16);
  bytes.writeUInt16LE(1, 20);
  bytes.writeUInt16LE(1, 22);
  bytes.writeUInt32LE(rate, 24);
  bytes.writeUInt32LE(rate * 2, 28);
  bytes.writeUInt16LE(2, 32);
  bytes.writeUInt16LE(16, 34);
  bytes.write('data', 36);
  bytes.writeUInt32LE(bytes.length - 44, 40);
  bytes.writeInt16LE(100, 44);
  return bytes;
}

export async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return `http://127.0.0.1:${server.address().port}`;
}

export async function fixture(t, overrides = {}, upstreamHandler = (_request, response) => {
  response.end(JSON.stringify({ status: 'success', result: null }));
}) {
  const directory = await mkdtemp(join(tmpdir(), 'hanmusic-gateway-'));
  const upstream = http.createServer(upstreamHandler);
  const upstreamUrl = `${await listen(upstream)}/`;
  const config = {
    nodeEnv: 'test', token: TOKEN, budgetFile: join(directory, 'budget.json'),
    upstreamUrl, port: 0, ...overrides,
  };
  const server = await createRecognitionServer(config);
  const url = await listen(server);
  t.after(async () => {
    await server.shutdown();
    await new Promise((resolve) => { upstream.close(resolve); upstream.closeAllConnections(); });
    await rm(directory, { recursive: true, force: true });
  });
  return { server, upstream, url, config, directory };
}

export async function post(url, audio = wav(), headers = {}) {
  const response = await fetch(`${url}/v1/recognize`, {
    method: 'POST', headers: { 'content-type': 'audio/wav', ...headers }, body: audio,
  });
  return { status: response.status, body: await response.json(), headers: response.headers };
}

export async function bodyOf(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks);
}

export function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}
