import { MAX_AUDIO_BYTES } from './config.js';
import { ServiceError } from './errors.js';

function invalid() { throw new ServiceError('invalid_audio'); }

export function validateWav(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 44 || bytes.length > MAX_AUDIO_BYTES ||
      bytes.toString('ascii', 0, 4) !== 'RIFF' || bytes.toString('ascii', 8, 12) !== 'WAVE' ||
      bytes.readUInt32LE(4) !== bytes.length - 8) invalid();
  let offset = 12;
  let format;
  let dataLength;
  while (offset < bytes.length) {
    if (bytes.length - offset < 8) invalid();
    const id = bytes.toString('ascii', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    offset += 8;
    if (size > bytes.length - offset) invalid();
    // The native bridge emits exactly a PCM fmt chunk followed by data. A
    // narrow allowlist excludes embedded files, metadata, URLs and extra audio.
    if (id === 'fmt ' && !format && dataLength === undefined && size === 16) {
      const encoding = bytes.readUInt16LE(offset);
      const channels = bytes.readUInt16LE(offset + 2);
      const sampleRate = bytes.readUInt32LE(offset + 4);
      const byteRate = bytes.readUInt32LE(offset + 8);
      const alignment = bytes.readUInt16LE(offset + 12);
      const bits = bytes.readUInt16LE(offset + 14);
      if (encoding !== 1 || channels !== 1 || bits !== 16 || alignment !== 2 ||
          sampleRate < 8000 || (sampleRate > 192000 && sampleRate !== 384000) ||
          byteRate !== sampleRate * 2) invalid();
      format = { sampleRate, byteRate };
    } else if (id === 'data' && format && dataLength === undefined) {
      if (size === 0 || size % 2 !== 0) invalid();
      dataLength = size;
    } else {
      invalid();
    }
    offset += size + (size & 1);
    if (offset > bytes.length) invalid();
  }
  if (!format || dataLength === undefined || offset !== bytes.length) invalid();
  const duration = dataLength / format.byteRate;
  if (duration < 1 || duration > 12.5) invalid();
  return Object.freeze({ sampleRate: format.sampleRate, duration });
}
