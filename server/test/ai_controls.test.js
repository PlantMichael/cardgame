'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { godotBin, PROJECT_DIR, killTree } = require('./helpers');

test('difficulty selections reach matches and the live AI executes Pilot', {
  skip: !godotBin() ? 'requires GODOT_BIN' : false,
  timeout: 30000,
}, async (t) => {
  const proc = spawn(godotBin(), ['--headless', '--path', PROJECT_DIR,
    'res://server/test/fixtures/ai_controls.tscn'], { stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => killTree(proc));
  let log = '';
  proc.stdout.on('data', data => { log += data; });
  proc.stderr.on('data', data => { log += data; });
  const code = await new Promise((resolve, reject) => {
    proc.once('error', reject);
    proc.once('exit', resolve);
  });
  assert.equal(code, 0, log);
  assert.match(log, /AI_CONTROLS_RESULT.*"failures":\[\]/, log);
  assert.doesNotMatch(log, /SCRIPT ERROR|ERROR:/, log);
});
