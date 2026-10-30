import http from 'node:http';
import { isIP } from 'node:net';
import { randomBytes } from 'node:crypto';
import { normalizeConfig, isLoopback, MAX_AUDIO_BYTES } from './config.js';
import { ServiceError, HTTP_STATUS } from './errors.js';
import { validateWav } from './wav.js';
import { createBudget } from './budget.js';

const MAX_RESPONSE_BYTES = 1024 * 1024;

function canonicalIp(address) {
  if (address.startsWith('::ffff:') && isIP(address.slice(7)) === 4) return address.slice(7);
  if (isIP(address) === 6) return new URL(`http://[${address}]/`).hostname;
  return address;
}

export function clientIp(request, trustProxyLoopback) {
  const peer = request.socket.remoteAddress ?? 'unknown';
  if (trustProxyLoopback && isLoopback(peer)) {
    const forwarded = request.headers['x-forwarded-for'];
    if (typeof forwarded === 'string') {
      for (const item of forwarded.split(',').reverse()) {
        const address = item.trim();
        if (isIP(address)) return canonicalIp(address);
      }
    }
  }
  return canonicalIp(peer);
}

function json(response, status, body, headers = {}) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...headers,
  });
  response.end(JSON.stringify(body));
}

function errorResponse(request, response, error) {
  if (error.code === 'client_closed' || response.destroyed) return;
  const code = Object.hasOwn(HTTP_STATUS, error.code) ? error.code : 'service_unavailable';
  const headers = { connection: 'close' };
  if (error.retryAfter) headers['retry-after'] = String(error.retryAfter);
  // Never serialize Error.message, stack, the upstream response, or config.
  json(response, HTTP_STATUS[code], { status: 'error', error: { code } }, headers);
  if (!request.complete) response.once('finish', () => request.destroy());
}

function readBody(request, signal, timeoutMs) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    const timer = setTimeout(() => fail(new ServiceError('invalid_audio')), timeoutMs);
    const cleanup = () => {
      clearTimeout(timer);
      request.off('data', data);
      request.off('end', end);
      request.off('error', failed);
      signal.removeEventListener('abort', aborted);
    };
    const wipe = () => { for (const chunk of chunks) chunk.fill(0); chunks.length = 0; };
    const fail = (error) => {
      if (settled) return;
      settled = true;
      request.pause();
      cleanup();
      wipe();
      reject(error);
    };
    const data = (chunk) => {
      size += chunk.length;
      if (size > MAX_AUDIO_BYTES) {
        chunk.fill(0);
        fail(new ServiceError('invalid_audio'));
      } else chunks.push(chunk);
    };
    const end = () => {
      if (settled) return;
      settled = true;
      cleanup();
      const bytes = Buffer.concat(chunks, size);
      wipe();
      resolve(bytes);
    };
    const failed = () => fail(new ServiceError('client_closed'));
    const aborted = () => fail(new ServiceError('client_closed'));
    request.on('data', data);
    request.once('end', end);
    request.once('error', failed);
    signal.addEventListener('abort', aborted, { once: true });
    if (signal.aborted) aborted();
  });
}

function multipart(audio, token) {
  const boundary = `hanmusic-${randomBytes(24).toString('hex')}`;
  const prefix = Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="api_token"\r\n\r\n${token}\r\n` +
    `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="sample.wav"\r\n` +
    'Content-Type: audio/wav\r\n\r\n');
  const suffix = Buffer.from(`\r\n--${boundary}--\r\n`);
  try {
    return { boundary, bytes: Buffer.concat([prefix, audio, suffix]) };
  } finally { prefix.fill(0); suffix.fill(0); }
}

async function boundedJson(response, controller) {
  const length = response.headers.get('content-length');
  if (length && (!/^\d+$/.test(length) || Number(length) > MAX_RESPONSE_BYTES)) {
    controller.abort();
    throw new ServiceError('upstream_failure');
  }
  const chunks = [];
  let size = 0;
  let bytes;
  try {
    if (!response.body) throw new ServiceError('upstream_failure');
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > MAX_RESPONSE_BYTES) {
        controller.abort();
        throw new ServiceError('upstream_failure');
      }
      chunks.push(Buffer.from(chunk));
    }
    bytes = Buffer.concat(chunks, size);
    return JSON.parse(bytes.toString('utf8'));
  } catch {
    throw new ServiceError('upstream_failure');
  } finally {
    bytes?.fill(0);
    for (const chunk of chunks) chunk.fill(0);
  }
}

function trimResult(payload, token) {
  if (payload?.status !== 'success' || !Object.hasOwn(payload, 'result')) {
    throw new ServiceError('upstream_failure');
  }
  if (payload.result === null) return { status: 'success', result: null };
  const item = payload.result;
  const valid = (value, limit) => typeof value === 'string' && value.trim().length > 0 &&
    value.length <= limit && !/[\x00-\x1f\x7f]/.test(value) && !value.includes(token);
  if (!item || !valid(item.title, 512) || !valid(item.artist, 512)) {
    throw new ServiceError('upstream_failure');
  }
  const result = { title: item.title.trim(), artist: item.artist.trim() };
  if (valid(item.album, 512)) result.album = item.album.trim();
  if (valid(item.release_date, 32)) result.release_date = item.release_date.trim();
  return { status: 'success', result };
}

async function recognize(audio, config, clientSignal) {
  const controller = new AbortController();
  const aborted = () => controller.abort();
  clientSignal.addEventListener('abort', aborted, { once: true });
  if (clientSignal.aborted) aborted();
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; controller.abort(); }, config.upstreamTimeoutMs);
  const body = multipart(audio, config.token);
  try {
    if (clientSignal.aborted) throw new ServiceError('client_closed');
    const response = await fetch(config.upstreamUrl, {
      method: 'POST',
      headers: { 'content-type': `multipart/form-data; boundary=${body.boundary}` },
      body: body.bytes,
      redirect: 'error',
      signal: controller.signal,
    });
    if (response.status === 429) {
      await response.body?.cancel();
      throw new ServiceError('rate_limited', 60);
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new ServiceError('upstream_failure');
    }
    return trimResult(await boundedJson(response, controller), config.token);
  } catch (error) {
    if (clientSignal.aborted) throw new ServiceError('client_closed');
    if (timedOut) throw new ServiceError('upstream_timeout');
    if (error instanceof ServiceError) throw error;
    throw new ServiceError('upstream_failure');
  } finally {
    clearTimeout(timer);
    clientSignal.removeEventListener('abort', aborted);
    controller.abort();
    body.bytes.fill(0);
  }
}

export async function createRecognitionServer(input = {}) {
  const config = normalizeConfig(input);
  const budget = await createBudget(config);
  let active = 0;
  const clients = new Set();
  const server = http.createServer({
    maxHeaderSize: 16 * 1024,
    headersTimeout: config.bodyTimeoutMs,
    requestTimeout: config.bodyTimeoutMs,
    connectionsCheckingInterval: Math.min(1000, config.bodyTimeoutMs),
  }, async (request, response) => {
    if (request.url === '/healthz' && request.method === 'GET') {
      const ready = Boolean(config.token) && !budget.failed;
      json(response, ready ? 200 : 503, { status: ready ? 'ok' : 'unavailable' });
      return;
    }
    if (request.url !== '/v1/recognize' || request.method !== 'POST') {
      response.writeHead(request.url === '/v1/recognize' ? 405 : 404, { connection: 'close' });
      response.end();
      return;
    }
    const controller = new AbortController();
    const disconnected = () => { if (!response.writableFinished) controller.abort(); };
    request.once('aborted', disconnected);
    response.once('close', disconnected);
    clients.add(controller);
    let counted = false;
    let audio;
    try {
      if (!config.token || budget.failed) throw new ServiceError('service_unavailable');
      if (active >= config.concurrency) throw new ServiceError('rate_limited', 1);
      if (request.headers['content-type']?.toLowerCase() !== 'audio/wav' ||
          (request.headers['content-encoding'] && request.headers['content-encoding'] !== 'identity')) {
        throw new ServiceError('invalid_audio');
      }
      const length = request.headers['content-length'];
      if (length !== undefined && (!/^\d+$/.test(length) || Number(length) < 44 || Number(length) > MAX_AUDIO_BYTES)) {
        throw new ServiceError('invalid_audio');
      }
      active += 1;
      counted = true;
      audio = await readBody(request, controller.signal, config.bodyTimeoutMs);
      validateWav(audio);
      await budget.consume(clientIp(request, config.trustProxyLoopback), controller.signal);
      if (controller.signal.aborted) throw new ServiceError('client_closed');
      json(response, 200, await recognize(audio, config, controller.signal));
    } catch (error) {
      errorResponse(request, response, error);
    } finally {
      audio?.fill(0);
      if (counted) active -= 1;
      clients.delete(controller);
      request.off('aborted', disconnected);
      response.off('close', disconnected);
    }
  });
  server.maxHeadersCount = 32;
  server.maxConnections = 64;
  server.keepAliveTimeout = 5000;
  server.setTimeout(config.bodyTimeoutMs + config.upstreamTimeoutMs + 1000, (socket) => socket.destroy());
  server.on('checkContinue', (request, response) => errorResponse(request, response, new ServiceError('invalid_audio')));
  server.on('clientError', (error, socket) => {
    if (error.code === 'ERR_HTTP_REQUEST_TIMEOUT' && socket.writable) {
      // Node's parser deadline can beat the per-body timer. Preserve the same
      // bounded public error instead of racing it with a bare TCP reset.
      const body = '{"status":"error","error":{"code":"invalid_audio"}}';
      socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n' +
        'Content-Type: application/json\r\nCache-Control: no-store\r\n' +
        `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
      socket.setTimeout(1000, () => socket.destroy());
    } else socket.destroy();
  });
  // A caller may use ordinary server.close() or fail to bind its HTTP port.
  // Both must release the independent budget lock, even before listen succeeds.
  server.once('close', () => { void budget.close(); });
  server.once('error', () => { void budget.close(); });
  let shutdown;
  server.shutdown = () => {
    shutdown ??= (async () => {
      for (const controller of clients) controller.abort();
      await new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); });
      await budget.close();
    })();
    return shutdown;
  };
  return server;
}
