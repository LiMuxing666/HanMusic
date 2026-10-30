import { createRecognitionServer } from '../src/server.js';

// Invoked explicitly by lock.test.js; a plain node --test discovery is a no-op.
if (process.argv[2]) {
  await createRecognitionServer({ budgetFile: process.argv[2] });
  process.stdout.write('READY\n');
}
