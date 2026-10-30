import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtemp, rm, writeFile, symlink, link } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createRecognitionServer } from '../src/server.js';
import { listen } from './helpers.js';

async function setup(t) {
  const directory = await mkdtemp(join(tmpdir(), 'hanmusic-lock-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return { budgetFile: join(directory, 'budget.json') };
}

test('same budget rejects a second instance independent of HTTP port/path casing', async (t) => {
  const config = await setup(t);
  const first = await createRecognitionServer(config);
  t.after(() => first.shutdown());
  const alias = process.platform === 'win32' ? config.budgetFile.toUpperCase() : config.budgetFile;
  await assert.rejects(createRecognitionServer({ ...config, budgetFile: alias, port: 9876 }), /already in use/);
  await first.shutdown();
  const next = await createRecognitionServer(config);
  await next.shutdown();
});

test('shutdown before listen is idempotent and releases the kernel lock', async (t) => {
  const config = await setup(t);
  const server = await createRecognitionServer(config);
  await Promise.all([server.shutdown(), server.shutdown()]);
  const next = await createRecognitionServer(config);
  await next.shutdown();
});

test('HTTP listen failure releases budget lock without requiring explicit shutdown', async (t) => {
  const config = await setup(t);
  const occupied = http.createServer();
  await listen(occupied);
  t.after(() => new Promise((resolve) => occupied.close(resolve)));
  const server = await createRecognitionServer(config);
  const error = once(server, 'error');
  server.listen(occupied.address().port, '127.0.0.1');
  assert.equal((await error)[0].code, 'EADDRINUSE');
  await new Promise((resolve) => setImmediate(resolve));
  const next = await createRecognitionServer(config);
  await next.shutdown();
  await server.shutdown();
});

test('corrupt-budget startup releases its lock for a later repaired startup', async (t) => {
  const config = await setup(t);
  await writeFile(config.budgetFile, 'bad budget');
  await assert.rejects(createRecognitionServer(config), /storage unavailable/);
  await writeFile(config.budgetFile, JSON.stringify({ version: 1, day: '2026-10-30', used: 5 }));
  const next = await createRecognitionServer(config);
  await next.shutdown();
});

test('another process cannot acquire lock, and a killed owner leaves no stale lock', { timeout: 10000 }, async (t) => {
  const config = await setup(t);
  const child = spawn(process.execPath, [fileURLToPath(new URL('./lock-child.js', import.meta.url)), config.budgetFile], { stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => { if (child.exitCode === null) child.kill(); });
  await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', () => reject(new Error('Lock owner exited early')));
    child.stdout.on('data', (chunk) => { if (chunk.toString().includes('READY')) resolve(); });
  });
  await assert.rejects(createRecognitionServer(config), /already in use/);
  const stopped = once(child, 'exit');
  child.kill('SIGKILL');
  await stopped;
  const restarted = await createRecognitionServer(config);
  await restarted.shutdown();
});

test('budget file symlink is refused before atomic replacement can change lock identity', async (t) => {
  const config = await setup(t);
  const target = `${config.budgetFile}.target`;
  await writeFile(target, JSON.stringify({ version: 1, day: '2026-10-30', used: 0 }));
  try { await symlink(target, config.budgetFile, 'file'); }
  catch (error) {
    if (error.code === 'EPERM') { t.skip('Host does not allow creating file symlinks'); return; }
    throw error;
  }
  await assert.rejects(createRecognitionServer(config), /storage unavailable/);
});

test('hard-linked budget files cannot create independent lock identities', async (t) => {
  const config = await setup(t);
  await writeFile(config.budgetFile, JSON.stringify({ version: 1, day: '2026-10-30', used: 0 }));
  await link(config.budgetFile, `${config.budgetFile}.alias`);
  await assert.rejects(createRecognitionServer(config), /storage unavailable/);
});
