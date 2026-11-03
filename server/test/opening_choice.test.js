'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');
const { godotBin, PROJECT_DIR, killTree } = require('./helpers');

test('real opening picker handles keyboard, timeout, remote mulligan and AI Coin play', {
  skip: !godotBin() ? 'requires GODOT_BIN' : false, timeout: 30000,
}, async t => {
  const projectArgs = process.env.GODOT_PACK ? ['--main-pack', path.resolve(process.env.GODOT_PACK)] : ['--path', PROJECT_DIR];
  const proc = spawn(godotBin(), ['--headless', ...projectArgs, 'res://server/test/fixtures/opening_choice.tscn'], { stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => killTree(proc));
  let log = '';
  proc.stdout.on('data', data => { log += data; });
  proc.stderr.on('data', data => { log += data; });
  const code = await new Promise((resolve, reject) => { proc.once('error', reject); proc.once('exit', resolve); });
  assert.equal(code, 0, log);
  assert.match(log, /OPENING_CHOICE_RESULT.*"failures":\[\]/, log);
  assert.doesNotMatch(log, /SCRIPT ERROR|ERROR:/, log);
});
