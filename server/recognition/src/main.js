import { createRecognitionServer } from './server.js';
import { readConfigFromEnv } from './config.js';

try {
  const config = readConfigFromEnv();
  const server = await createRecognitionServer(config);
  server.on('error', () => {
    console.error('Recognition gateway could not listen. Check host and port.');
    process.exitCode = 1;
  });
  server.listen(config.port, config.host, () => {
    console.log('Recognition gateway is listening.');
  });
  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    await server.shutdown();
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
} catch {
  // Configuration values, paths and underlying exception text may contain
  // secrets. Keep startup failure output constant as well.
  console.error('Recognition gateway could not start. Check configuration and budget storage.');
  process.exitCode = 1;
}
