'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { godotBin, PROJECT_DIR, killTree } = require('./helpers');

test('deck builder supports collection controls, keyboard inspection and offline save lifecycle', {
  skip: !godotBin() ? 'requires GODOT_BIN' : false, timeout: 60000,
}, async t => {
  // Fresh synthetic user storage; never read or edit the player's real saves.
  const storage = fs.mkdtempSync(path.join(os.tmpdir(), 'cardgame-deck-ui-'));
  const projectArgs = process.env.GODOT_PACK ? ['--main-pack', path.resolve(process.env.GODOT_PACK)] : ['--path', PROJECT_DIR];
  const proc = spawn(godotBin(), ['--headless', ...projectArgs,
    'res://server/test/fixtures/deck_builder.tscn'], {
    env: { ...process.env, APPDATA: storage, XDG_DATA_HOME: storage },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => { killTree(proc); fs.rmSync(storage, { recursive: true, force: true }); });
  let log = '';
  proc.stdout.on('data', data => { log += data; });
  proc.stderr.on('data', data => { log += data; });
  const code = await new Promise((resolve, reject) => {
    proc.once('error', reject); proc.once('exit', resolve);
  });
  assert.equal(code, 0, log);
  assert.match(log, /DECK_BUILDER_RESULT.*"failures":\[\]/, log);
  assert.doesNotMatch(log, /SCRIPT ERROR|ERROR:/, log);
});
