'use strict';
const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { Pool } = require('pg');
const { provisionRankedBots } = require('./ranked_bot_accounts');
const { killTree } = require('./bot_worker');
const ROOT = path.resolve(__dirname, '..');

async function runRankedBots({ pool, godotBin, relayUrl, signal = new AbortController().signal,
  maxMatches = Infinity, onEvent = () => {}, log = console.log }) {
  if (!godotBin || !relayUrl || !(maxMatches === Infinity || Number.isSafeInteger(maxMatches) && maxMatches > 0)) throw new Error('invalid ranked worker configuration');
  const url = new URL(relayUrl);
  if (!['ws:', 'wss:'].includes(url.protocol) || url.username || url.password || url.hash || url.search) throw new Error('invalid ranked relay URL');
  const lock = await pool.connect();
  const controller = new AbortController();
  let accounts = [], child, directory, lockError, lockTimer;
  const stop = () => { clearInterval(lockTimer); controller.abort(); killTree(child); };
  const lostLock = error => { lockError = error; stop(); };
  signal.addEventListener('abort', stop, { once: true });
  lock.on('error', lostLock);
  if (signal.aborted) stop();
  try {
    const owned = await lock.query('SELECT pg_try_advisory_lock(731204, 2) AS owned');
    if (!owned.rows[0].owned) throw new Error('another ranked bot worker is active');
    if (controller.signal.aborted) return 0;
    // An idle TCP connection can stay silently open after the DB releases its
    // lock. Bound that uncertainty rather than waiting for a socket error.
    let probing = false;
    lockTimer = setInterval(async () => {
      if (probing) return;
      probing = true;
      try {
        const result = await lock.query({ text: `SELECT EXISTS (
          SELECT 1 FROM pg_locks WHERE locktype='advisory' AND classid=731204
          AND objid=2 AND pid=pg_backend_pid() AND granted) AS owned`, query_timeout: 5000 });
        if (!result.rows[0].owned) throw new Error('lock ownership lost');
      } catch (error) {
        if (!controller.signal.aborted) lostLock(error);
      } finally { probing = false; }
    }, 5000);
    accounts = await provisionRankedBots(pool);
    directory = await fs.mkdtemp(path.join(os.tmpdir(), 'cardgame-ranked-bots-'));
    const completed = new Set();
    await new Promise((resolve, reject) => {
      let output = '', lines = '';
      child = spawn(godotBin, ['--headless', '--path', ROOT, '--', '--ranked-bots'], {
        env: { ...process.env, APPDATA: directory, XDG_DATA_HOME: directory,
          RANKED_BOT_URL: url.href, RANKED_BOT_SESSIONS: JSON.stringify(accounts) },
        windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
      });
      child.stdout.on('data', data => {
        output = (output + data).slice(-8192);
        lines += data;
        let newline;
        while ((newline = lines.indexOf('\n')) !== -1) {
          const line = lines.slice(0, newline).trim(); lines = lines.slice(newline + 1);
          if (!line.startsWith('RANKED_BOT_EVENT ')) continue;
          let event;
          try { event = JSON.parse(line.slice(17)); } catch { continue; }
          log(`Ranked bot ${event.bot}: ${event.event}`);
          onEvent(event);
          if (event.event === 'completed') completed.add(event.match_id);
          if (completed.size >= maxMatches) stop();
        }
        if (lines.length > 8192) lines = lines.slice(-8192);
      });
      child.stderr.on('data', data => {
        output = (output + data).slice(-8192);
        if (/SCRIPT ERROR|Parse Error/.test(output)) killTree(child);
      });
      child.once('error', reject);
      child.once('close', code => {
        if (controller.signal.aborted) resolve();
        else reject(new Error(`ranked bot process exited (${code}): ${output}`));
      });
      if (controller.signal.aborted) killTree(child);
    });
    if (lockError) throw new Error(`ranked worker database lock lost: ${lockError.message}`);
    return completed.size;
  } finally {
    stop(); signal.removeEventListener('abort', stop); lock.off('error', lostLock);
    if (accounts.length) await pool.query('DELETE FROM sessions WHERE token=ANY($1::text[])', [accounts.map(a => a.token)])
      .catch(() => log('Could not remove ranked worker sessions; operator cleanup may be needed'));
    if (!lockError) await lock.query('SELECT pg_advisory_unlock(731204, 2)').catch(() => {});
    lock.release(true);
    if (directory) {
      if (path.dirname(directory) !== path.resolve(os.tmpdir()) || !path.basename(directory).startsWith('cardgame-ranked-bots-')) throw new Error('unsafe worker cleanup path');
      await fs.rm(directory, { recursive: true, force: true });
    }
  }
}

async function main() {
  const controller = new AbortController();
  process.once('SIGINT', () => controller.abort()); process.once('SIGTERM', () => controller.abort());
  const args = process.argv.slice(2);
  if (args.length > 1 || args[0] && !/^--matches=[1-9]\d*$/.test(args[0]) || !process.env.DATABASE_URL) {
    console.error('Usage: node ranked_bot_worker.js [--matches=N]; DATABASE_URL, GODOT_BIN and RANKED_BOT_URL required');
    process.exitCode = 1;
  } else {
    const url = new URL(process.env.DATABASE_URL);
    const pool = new Pool({ connectionString: url.toString(), max: 4, connectionTimeoutMillis: 10000, query_timeout: 10000,
      keepAlive: true, keepAliveInitialDelayMillis: 10000,
      ssl: ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) || url.hostname.endsWith('.railway.internal') ? false : { rejectUnauthorized: false } });
    await runRankedBots({ pool, godotBin: process.env.GODOT_BIN, relayUrl: process.env.RANKED_BOT_URL,
      signal: controller.signal, maxMatches: args[0] ? Number(args[0].split('=')[1]) : Infinity })
      .finally(() => pool.end());
  }
}
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
module.exports = { runRankedBots };
