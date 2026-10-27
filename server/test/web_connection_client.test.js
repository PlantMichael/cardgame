'use strict';
// Exercise real Godot screen lifetimes without opening a production connection.
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { godotBin, PROJECT_DIR, killTree } = require('./helpers');

test('connection deadlines and autoload callbacks respect screen lifetime', {
  skip: !godotBin() ? 'requires GODOT_BIN' : false,
  timeout: 45000,
}, async (t) => {
  const proc = spawn(godotBin(), ['--headless', '--path', PROJECT_DIR,
    'res://server/test/fixtures/web_connection_client.tscn'], { stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => killTree(proc));
  let log = '';
  proc.stdout.on('data', (data) => { log += data; });
  proc.stderr.on('data', (data) => { log += data; });
  const code = await new Promise((resolve, reject) => {
    proc.once('error', reject);
    proc.once('exit', resolve);
  });
  assert.equal(code, 0, log);
  assert.match(log, /WEB_CONNECTION_RESULT.*"failures":\[\]/, log);
  assert.doesNotMatch(log, /SCRIPT ERROR|ERROR:|RuntimeError/, log);
});
