import { mkdir, open, readFile, rename, stat, unlink } from 'node:fs/promises';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { ServiceError } from './errors.js';
import { acquireBudgetLock } from './lock.js';

const HOUR = 60 * 60 * 1000;
const utcDay = (time) => new Date(time).toISOString().slice(0, 10);

async function replaceFile(file, value) {
  const temporary = `${file}.${randomUUID()}.tmp`;
  let handle;
  try {
    handle = await open(temporary, 'wx', 0o600);
    await handle.writeFile(`${JSON.stringify(value)}\n`, 'utf8');
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(temporary, file);
    // Linux deployment: persist the rename as well as file contents. Windows
    // does not support opening directory handles with this Node API.
    if (process.platform !== 'win32') {
      const directory = await open(dirname(file), 'r');
      try { await directory.sync(); } finally { await directory.close(); }
    }
  } finally {
    await handle?.close().catch(() => {});
    await unlink(temporary).catch(() => {});
  }
}

export async function createBudget(config) {
  await mkdir(dirname(config.budgetFile), { recursive: true, mode: 0o700 });
  const releaseLock = await acquireBudgetLock(config.budgetFile);
  let state;
  try {
    try {
      if ((await stat(config.budgetFile)).size > 4096) throw new Error('Invalid budget');
      state = JSON.parse(await readFile(config.budgetFile, 'utf8'));
      if (state?.version !== 1 || !/^\d{4}-\d{2}-\d{2}$/.test(state.day) ||
          utcDay(Date.parse(`${state.day}T00:00:00.000Z`)) !== state.day ||
          !Number.isSafeInteger(state.used) || state.used < 0) throw new Error('Invalid budget');
    } catch (error) {
      if (error.code !== 'ENOENT') throw new Error('Budget storage unavailable');
      state = { version: 1, day: utcDay(config.now()), used: 0 };
      await replaceFile(config.budgetFile, state);
    }
  } catch (error) {
    await releaseLock();
    throw error;
  }
  let serial = Promise.resolve();
  let failed = false;
  let closing = false;
  let closed;
  const ips = new Map();
  return {
    get failed() { return failed; },
    close() {
      closing = true;
      closed ??= serial.then(releaseLock);
      return closed;
    },
    consume(ip, signal) {
      // Admission, the IP counter and the durable daily debit form one serial
      // operation. No concurrent request can spend the same remaining slot.
      const operation = serial.then(async () => {
        if (signal.aborted) throw new ServiceError('client_closed');
        if (failed || closing) throw new ServiceError('service_unavailable');
        const now = config.now();
        const day = utcDay(now);
        if (day < state.day || (day === state.day && state.used >= config.dailyLimit)) {
          throw new ServiceError('daily_limit', 86400);
        }
        for (const [key, timestamps] of ips) {
          while (timestamps.length && timestamps[0] <= now - HOUR) timestamps.shift();
          if (timestamps.length === 0) ips.delete(key);
        }
        const timestamps = ips.get(ip) ?? [];
        if (timestamps.length >= config.ipLimit || (!ips.has(ip) && ips.size >= config.ipCacheSize)) {
          throw new ServiceError('rate_limited', 3600);
        }
        const next = { version: 1, day, used: day === state.day ? state.used + 1 : 1 };
        try {
          await replaceFile(config.budgetFile, next);
        } catch {
          // A failed rename/fsync has an uncertain commit point. Do not keep
          // serving from stale in-memory state; restart requires re-reading it.
          failed = true;
          throw new ServiceError('service_unavailable');
        }
        state = next;
        timestamps.push(now);
        ips.set(ip, timestamps);
      });
      serial = operation.catch(() => {});
      return operation;
    },
  };
}
