'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { mkdtempSync, rmSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { godotBin, PROJECT_DIR, killTree } = require('./helpers');

test('AI searches choices, lethal and retrieval sequences through core and live play', {
  skip: !godotBin() ? 'requires GODOT_BIN' : false,
  timeout: 120000,
}, async (t) => {
  // Give the fixture its own user-data directory; no real sessions or saves.
  const scratch = mkdtempSync(path.join(os.tmpdir(), 'cardgame-ai-planning-'));
  const proc = spawn(godotBin(), ['--headless', '--path', PROJECT_DIR,
    'res://server/test/fixtures/ai_planning.tscn'], {
    env: { ...process.env, APPDATA: scratch, XDG_DATA_HOME: scratch },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => {
    killTree(proc);
    assert.equal(path.dirname(path.resolve(scratch)), path.resolve(os.tmpdir()));
    rmSync(scratch, { recursive: true, force: true });
  });
  let log = '';
  proc.stdout.on('data', data => { log += data; });
  proc.stderr.on('data', data => { log += data; });
  const code = await new Promise((resolve, reject) => {
    proc.once('error', reject);
    proc.once('exit', resolve);
  });
  assert.equal(code, 0, log);
  assert.match(log, /AI_PLANNING_RESULT.*"failures":\[\]/, log);
  assert.doesNotMatch(log, /SCRIPT ERROR|ERROR:/, log);
});
