'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { spawn, execFile } = require('node:child_process');
const { randomUUID, randomInt } = require('node:crypto');
const { Pool } = require('pg');
const { profiles, initBotSchema, normalizeBotMatch, saveBotMatch } = require('./bot_matches');

const ROOT = path.resolve(__dirname, '..');
const PAIRS = profiles.flatMap((p, i) => [...profiles.slice(i + 1).map(q => [p.id, q.id]), [p.id, 'standard']]);
function jobAt(cursor) {
  const round = Math.floor(cursor / PAIRS.length), [a, b] = PAIRS[cursor % PAIRS.length];
  return { a, b, factionA: Math.floor(round / 2) % 5, factionB: Math.floor(round / 10) % 5, first: round % 2 ? 'b' : 'a' };
}
async function writeState(file, state) {
  await fs.writeFile(file + '.tmp', JSON.stringify(state), { mode: 0o600 });
  await fs.rename(file + '.tmp', file);
}
async function readState(file) {
  try {
    const state = JSON.parse(await fs.readFile(file, 'utf8'));
    if (!Number.isSafeInteger(state.cursor) || state.cursor < 0 || state.cursor > Number.MAX_SAFE_INTEGER - 1) throw new Error('invalid worker cursor');
    if (state.pending) {
      normalizeBotMatch(state.pending.result);
      if (typeof state.pending.id !== 'string') throw new Error('invalid pending id');
    }
    return state;
  } catch (e) { if (e.code === 'ENOENT') return { cursor: 0 }; throw e; }
}
function killTree(child) {
  if (!child || !child.pid || child.exitCode !== null || child.signalCode !== null) return;
  if (process.platform === 'win32') {
    execFile(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32/taskkill.exe'), ['/PID', String(child.pid), '/T', '/F'], () => {});
  } else child.kill('SIGKILL');
}
function sleep(ms, signal) {
  if (signal.aborted) return Promise.resolve();
  return new Promise(resolve => {
    const done = () => { clearTimeout(timer); signal.removeEventListener('abort', done); resolve(); };
    const timer = setTimeout(done, ms);
    signal.addEventListener('abort', done, { once: true });
  });
}

async function simulate(job, { godotBin, signal, timeoutMs = 660000 }) {
  if (signal.aborted) throw new Error('worker stopped');
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'cardgame-moon-'));
  const resultPath = path.join(dir, 'result.json');
  const gameSeed = randomInt(2147483647);
  let child;
  try {
    await new Promise((resolve, reject) => {
      let output = '', expired = false;
      child = spawn(godotBin, ['--headless', '--path', ROOT, '--', '--bot-match',
        `--bot-a=${job.a}`, `--bot-b=${job.b}`, `--bot-faction-a=${job.factionA}`, `--bot-faction-b=${job.factionB}`,
        `--bot-first=${job.first}`, `--bot-seed=${gameSeed}`, `--bot-result=${resultPath}`],
      { env: { ...process.env, APPDATA: dir, XDG_DATA_HOME: dir }, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
      const capture = data => { output = (output + data).slice(-8192); };
      child.stdout.on('data', capture); child.stderr.on('data', capture);
      const stop = () => killTree(child);
      const timer = setTimeout(() => { expired = true; stop(); }, timeoutMs);
      signal.addEventListener('abort', stop, { once: true });
      const cleanup = () => { clearTimeout(timer); signal.removeEventListener('abort', stop); };
      child.once('error', e => { cleanup(); reject(e); });
      child.once('close', code => {
        cleanup();
        if (code === 0 && !expired && !signal.aborted && !/SCRIPT ERROR|Parse Error/.test(output)) resolve();
        else reject(new Error(`bot process failed (${expired ? 'timeout' : code}): ${output}`));
      });
      if (signal.aborted) stop();
    });
    const info = await fs.stat(resultPath);
    if (info.size > 65536) throw new Error('oversize match result');
    const result = normalizeBotMatch(JSON.parse(await fs.readFile(resultPath, 'utf8')));
    if (result.a.id !== job.a || result.b.id !== job.b || result.factionA !== job.factionA || result.factionB !== job.factionB ||
        result.first !== job.first || result.seed !== gameSeed) throw new Error('wrong match result');
    return result;
  } finally {
    // mkdtemp owns this unique child directory, never the operator's user profile.
    killTree(child);
    if (path.dirname(dir) !== path.resolve(os.tmpdir()) || !path.basename(dir).startsWith('cardgame-moon-')) throw new Error('unsafe temporary cleanup path');
    await fs.rm(dir, { recursive: true, force: true });
  }
}

async function runWorker({ pool, godotBin, stateDir, matches = Infinity, pauseMs = 60000,
  signal = new AbortController().signal, timeoutMs, log = console.log }) {
  if (!godotBin || !stateDir) throw new Error('GODOT_BIN and BOT_STATE_DIR are required');
  if (!(matches === Infinity || Number.isSafeInteger(matches) && matches > 0) || !Number.isSafeInteger(pauseMs) || pauseMs < 0) throw new Error('invalid worker bounds');
  await fs.mkdir(stateDir, { recursive: true });
  const file = path.join(stateDir, 'state.json');
  const lock = await pool.connect();
  const controller = new AbortController();
  const stop = () => controller.abort();
  let lockError;
  const lostLock = error => { lockError = error; stop(); };
  signal.addEventListener('abort', stop, { once: true });
  lock.on('error', lostLock); // Stop play before another worker can acquire a lost lock.
  if (signal.aborted) stop();
  try {
    const owned = await lock.query('SELECT pg_try_advisory_lock(731204, 1) AS owned');
    if (!owned.rows[0].owned) throw new Error('another moon-bot worker is active');
    await initBotSchema(pool);
    let state = await readState(file), completed = 0;
    while (completed < matches && !controller.signal.aborted) {
      try {
        if (!state.pending) {
          const job = jobAt(state.cursor);
          log(`Playing ${job.a} vs ${job.b} (${job.first} first)`);
          const result = await simulate(job, { godotBin, signal: controller.signal, timeoutMs });
          state = { cursor: state.cursor, pending: { id: randomUUID(), result } };
        }
        await writeState(file, state);
        await saveBotMatch(pool, state.pending.id, state.pending.result);
        const next = { cursor: state.cursor + 1 };
        await writeState(file, next);
        state = next; completed++;
        log(`Saved match ${state.cursor}`);
        if (completed < matches) await sleep(pauseMs, controller.signal);
      } catch (e) {
        if (controller.signal.aborted) break;
        log(`Bot attempt failed; retrying in 30 seconds: ${e.message}`);
        await sleep(30000, controller.signal);
      }
    }
    if (lockError) throw new Error(`worker database lock lost: ${lockError.message}`);
    return completed;
  } finally {
    stop(); signal.removeEventListener('abort', stop); lock.off('error', lostLock);
    // Destroy, rather than pool, the session holding the advisory lock.
    await lock.query('SELECT pg_advisory_unlock(731204, 1)').catch(() => {});
    lock.release(true);
  }
}

if (require.main === module) {
  const controller = new AbortController();
  process.once('SIGINT', () => controller.abort()); process.once('SIGTERM', () => controller.abort());
  const args = process.argv.slice(2);
  const matchArg = args[0];
  if (args.length > 1 || (matchArg && !/^--matches=[1-9]\d*$/.test(matchArg)) || !process.env.DATABASE_URL) {
    console.error('Usage: node bot_worker.js [--matches=N]; DATABASE_URL, GODOT_BIN and BOT_STATE_DIR required');
    process.exitCode = 1;
  } else {
    const url = new URL(process.env.DATABASE_URL);
    const pool = new Pool({ connectionString: url.toString(), max: 4, connectionTimeoutMillis: 10000, query_timeout: 10000,
      ssl: ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) || url.hostname.endsWith('.railway.internal') ? false : { rejectUnauthorized: false } });
    runWorker({ pool, godotBin: process.env.GODOT_BIN, stateDir: process.env.BOT_STATE_DIR,
      matches: matchArg ? Number(matchArg.split('=')[1]) : Infinity, pauseMs: Number(process.env.BOT_PAUSE_MS ?? 60000), signal: controller.signal })
      .catch(e => { console.error(e.message); process.exitCode = 1; }).finally(() => pool.end());
  }
}
module.exports = { jobAt, simulate, runWorker, readState, writeState, killTree };
