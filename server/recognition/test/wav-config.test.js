import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeConfig, readConfigFromEnv, AUDD_URL } from '../src/config.js';
import { validateWav } from '../src/wav.js';
import { clientIp } from '../src/server.js';
import { wav } from './helpers.js';

test('configuration has no default token, validates env and fixes production upstream', () => {
  const config = readConfigFromEnv({});
  assert.equal(config.token, '');
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.port, 8787);
  assert.equal(config.upstreamUrl, AUDD_URL);
  assert.equal(config.ipLimit, 10);
  assert.equal(config.dailyLimit, 100);
  assert.equal(config.concurrency, 2);
  assert.doesNotThrow(() => normalizeConfig(config));
  for (const env of [
    { PORT: '0' }, { PORT: '8787oops' }, { MAX_CONCURRENT: '2.5' },
    { TRUST_PROXY_LOOPBACK: 'yes' }, { AUDD_API_TOKEN: 'test' },
    { AUDD_API_TOKEN: 'testtoken' }, { AUDD_API_TOKEN: 'my-secret\nheader' },
    { HOST: 'example.org' }, { DAILY_LIMIT: '-1' },
  ]) assert.throws(() => readConfigFromEnv(env));
  assert.equal(readConfigFromEnv({ NODE_ENV: 'test', AUDD_API_TOKEN: 'test' }).token, 'test');
  for (const upstreamUrl of ['http://127.0.0.1:123/', 'https://evil.example/']) {
    assert.throws(() => normalizeConfig({ upstreamUrl }));
  }
  for (const upstreamUrl of ['http://example.com/', 'http://localhost/', 'http://127.0.0.1@evil.example/', 'http://127.0.0.1/?url=evil']) {
    assert.throws(() => normalizeConfig({ nodeEnv: 'test', upstreamUrl }));
  }
  assert.doesNotThrow(() => normalizeConfig({ nodeEnv: 'test', upstreamUrl: 'http://[::1]:123/' }));
});

test('WAV accepts exactly PCM16 mono, supported rates and 1..12.5 seconds', () => {
  assert.deepEqual(validateWav(wav()), { sampleRate: 8000, duration: 1 });
  assert.equal(validateWav(wav(48000, 12)).duration, 12);
  assert.equal(validateWav(wav(8000, 12.5)).duration, 12.5);
  assert.equal(validateWav(wav(384000, 1)).sampleRate, 384000);
  const cases = [Buffer.alloc(0), wav(8000, 0.5), wav(8000, 13), wav(7999), wav(200000)];
  for (const [offset, value, width] of [[4, 0, 4], [20, 3, 2], [22, 2, 2], [28, 10, 4], [32, 4, 2], [34, 24, 2], [40, 3, 4]]) {
    const sample = wav();
    sample.writeUIntLE(value, offset, width);
    cases.push(sample);
  }
  const unknown = wav(); unknown.write('LIST', 36); cases.push(unknown);
  const truncated = wav().subarray(0, 100); truncated.writeUInt32LE(92, 4); cases.push(truncated);
  const trailing = Buffer.concat([wav(), Buffer.alloc(8)]); trailing.writeUInt32LE(trailing.length - 8, 4); cases.push(trailing);
  const duplicate = Buffer.concat([wav(), wav().subarray(36)]); duplicate.writeUInt32LE(duplicate.length - 8, 4); cases.push(duplicate);
  const oversized = Buffer.alloc(8 * 1024 * 1024 + 1); cases.push(oversized);
  for (const sample of cases) assert.throws(() => validateWav(sample), { code: 'invalid_audio' });
});

test('forwarded IP is opt-in, loopback-only and takes last valid IP', () => {
  const request = (peer, forwarded) => ({ socket: { remoteAddress: peer }, headers: { 'x-forwarded-for': forwarded } });
  assert.equal(clientIp(request('127.0.0.1', '8.8.8.8'), false), '127.0.0.1');
  assert.equal(clientIp(request('203.0.113.1', '8.8.8.8'), true), '203.0.113.1');
  assert.equal(clientIp(request('127.0.0.1', '1.1.1.1, 203.0.113.3, invalid'), true), '203.0.113.3');
  assert.equal(clientIp(request('::ffff:127.0.0.1', 'invalid'), true), '127.0.0.1');
  assert.equal(clientIp(request('::1', '2001:0db8:0:0:0:0:0:1'), true), '[2001:db8::1]');
});
