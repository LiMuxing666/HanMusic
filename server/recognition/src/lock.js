import net from 'node:net';
import { createHash } from 'node:crypto';
import { lstat, realpath } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';

export async function acquireBudgetLock(file) {
  // The directory exists before this call. Resolve aliases/junctions even when
  // the initial budget file has not been created yet.
  let canonical;
  try {
    const info = await lstat(file);
    // Atomic replacement must not replace a file symlink and thereby change
    // the canonical identity while an instance holds its original lock. Hard
    // links likewise let distinct paths start with the same budget contents.
    if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1) {
      throw new Error('Budget must be a regular, singly linked file');
    }
    canonical = await realpath(file);
  }
  catch (error) {
    if (error.code !== 'ENOENT') throw new Error('Budget storage unavailable');
    canonical = join(await realpath(dirname(file)), basename(file));
  }
  if (process.platform === 'win32') canonical = canonical.toLowerCase();
  const digest = createHash('sha256').update(canonical).digest('hex');
  let path;
  if (process.platform === 'win32') path = `\\\\.\\pipe\\hanmusic-recognition-${digest}`;
  else if (process.platform === 'linux') path = `\0hanmusic-recognition-${digest}`;
  else throw new Error('Budget locking requires Linux or Windows');

  // An OS-owned listener is the mutex; it carries no HTTP/data protocol. Named
  // pipes/abstract sockets disappear when their owner dies, including crashes.
  // Never unlink a file or delete another process's potentially live lock.
  const guard = net.createServer((socket) => socket.destroy());
  guard.maxConnections = 1;
  try {
    await new Promise((resolve, reject) => {
      guard.once('error', reject);
      guard.listen({ path, exclusive: true }, resolve);
    });
  } catch {
    throw new Error('Budget is already in use or its lock is unavailable');
  }
  let closed;
  return () => {
    closed ??= new Promise((resolve) => guard.close(resolve));
    return closed;
  };
}
