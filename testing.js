// SPDX-License-Identifier: BSD-2-Clause

const { spawn } = require('child_process');
const path = require('path');

const helperPath = './zig-out/bin/helper';

console.log(`Starting helper: ${helperPath}`);

const child = spawn(helperPath, [], {
  stdio: ['pipe', 'pipe', 'pipe']
});

// Read messages using Native Messaging protocol
let buffer = Buffer.alloc(0);

child.stdout.on('data', (data) => {
  console.log(`[stdout] Received ${data.length} bytes`);
  buffer = Buffer.concat([buffer, data]);

  while (buffer.length >= 4) {
    const messageLength = buffer.readUInt32LE(0);

    if (buffer.length >= 4 + messageLength) {
      const messageBuffer = buffer.slice(4, 4 + messageLength);
      const message = JSON.parse(messageBuffer.toString('utf8'));
      console.log('[received]', message);

      if (message.msgType === 'info') {
        console.log('[info]', message.details);
      } else if (message.msgType === 'version') {
        console.log('[version]', message.details);
      }

      buffer = buffer.slice(4 + messageLength);
    } else {
      break;
    }
  }
});

child.stderr.on('data', (data) => {
  console.error(`[stderr]`, data.toString());
});

child.on('error', (err) => {
  console.error('[spawn error]', err);
});

child.on('close', (code) => {
  console.log(`[exit] code: ${code}`);
});

function sendNativeMessage(message) {
  const json = JSON.stringify(message);
  const length = Buffer.byteLength(json, 'utf8');
  const buffer = Buffer.alloc(4 + length);
  buffer.writeUInt32LE(length, 0);
  buffer.write(json, 4, 'utf8');

  console.log(`[send] ${json}`);

  child.stdin.write(buffer, (err) => {
    if (err) {
      console.error('[write error]', err);
    } else {
      console.log('[write] completed');
    }
  });
}

// Wait a bit for process to fully start
setTimeout(() => {
  sendNativeMessage({
    command: 'getAppVersion'
  });
}, 1000);

setTimeout(() => {
  sendNativeMessage({
    command: 'closeDevice'
  });
}, 3000);
