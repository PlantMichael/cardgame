#!/usr/bin/env node
'use strict';
// Maintainer CLI for server-run ranked matches (spec 003 T071). Reads the
// database directly (DATABASE_URL); there is no network endpoint. Every call
// appends a row to ranked_match_audit so use of the tool is itself recorded.
//
//   node tools/matches.js status
//   node tools/matches.js history <match_id>
//   node tools/matches.js replay  <match_id>     (needs GODOT_BIN: re-runs the log and checks the hash)
//   node tools/matches.js audit [limit]
const { Pool } = require('pg');
const { HostProcess } = require('../authoritative/host_process');

const NO_SSL_HOSTS = ['railway.internal', 'localhost', '127.0.0.1'];

function poolFromEnv(env = process.env) {
  const url = env.DATABASE_URL;
  if (!url) throw new Error('DATABASE_URL is not set');
  return new Pool({
    connectionString: url,
    ssl: NO_SSL_HOSTS.some((h) => url.includes(h)) ? false : { rejectUnauthorized: false },
  });
}

async function logUse(pool, command, matchId) {
  await pool.query(
    'INSERT INTO ranked_match_audit (match_id, reason, detail) VALUES ($1, $2, $3)',
    [matchId || null, `cli_${command}`, JSON.stringify({ at: new Date().toISOString() })],
  );
}

async function status(pool) {
  const byStatus = await pool.query('SELECT status, count(*)::int AS n FROM ranked_matches GROUP BY status ORDER BY status');
  const recent = await pool.query(
    `SELECT end_reason, count(*)::int AS n FROM ranked_matches
     WHERE ended_at > now() - interval '24 hours' GROUP BY end_reason ORDER BY n DESC`);
  const faults = await pool.query(
    `SELECT match_id, end_reason, ended_at FROM ranked_matches
     WHERE end_reason = 'voided_fault' ORDER BY ended_at DESC LIMIT 5`);
  const live = byStatus.rows.filter((r) => r.status === 'active' || r.status === 'waiting').reduce((n, r) => n + r.n, 0);
  return {
    live_matches: live,
    ceiling: Number(process.env.RANKED_MAX_LIVE_MATCHES) || 100,
    by_status: byStatus.rows,
    ended_last_24h_by_reason: recent.rows,
    recent_failures: faults.rows,
  };
}

async function history(pool, matchId) {
  const m = await pool.query('SELECT * FROM ranked_matches WHERE match_id = $1', [matchId]);
  if (!m.rows[0]) return { error: 'no such match' };
  const a = await pool.query('SELECT seq, seat, kind, command, state_hash, at FROM ranked_match_actions WHERE match_id = $1 ORDER BY seq', [matchId]);
  const { deck_a, deck_b, ...row } = m.rows[0];
  return { match: row, deck_sizes: { a: deck_a.length, b: deck_b.length }, actions: a.rows };
}

/** Re-runs a match's log in a fresh host and checks it lands on the stored hash. */
async function replay(pool, matchId) {
  const m = await pool.query('SELECT * FROM ranked_matches WHERE match_id = $1', [matchId]);
  const row = m.rows[0];
  if (!row) return { error: 'no such match' };
  const acts = await pool.query('SELECT seq, seat, kind, command, state_hash FROM ranked_match_actions WHERE match_id = $1 ORDER BY seq', [matchId]);
  const host = new HostProcess({ log: { warn() {}, error() {}, log() {} } });
  await host.start();
  try {
    const actions = acts.rows.map((r) => ({ seat: r.seat, kind: r.kind === 'timeout_default' ? 'timeout_default' : 'command', cmd: r.command }));
    const rep = await host.request('replay', {
      match_id: `replay_${matchId}`, seed: Number(row.seed), first_seat: row.first_seat, rules_version: row.rules_version,
      deck_a: row.deck_a, deck_b: row.deck_b, actions,
    });
    const expected = acts.rows.length ? acts.rows[acts.rows.length - 1].state_hash : null;
    return {
      ok: rep.ok && (!expected || rep.state_hash === expected),
      actions: actions.length, expected_hash: expected, replayed_hash: rep.state_hash || null,
      error: rep.ok ? undefined : rep.error,
    };
  } finally {
    await host.stop();
  }
}

async function audit(pool, limit) {
  const r = await pool.query('SELECT at, match_id, player_id, reason, detail FROM ranked_match_audit ORDER BY id DESC LIMIT $1', [limit]);
  return r.rows;
}

async function main(argv) {
  const [command, arg] = argv;
  if (!['status', 'history', 'replay', 'audit'].includes(command)) {
    console.error('usage: matches.js status | history <match_id> | replay <match_id> | audit [limit]');
    return 2;
  }
  if ((command === 'history' || command === 'replay') && !arg) {
    console.error(`${command} needs a match id`);
    return 2;
  }
  const pool = poolFromEnv();
  try {
    await logUse(pool, command, ['history', 'replay'].includes(command) ? arg : null);
    let out;
    if (command === 'status') out = await status(pool);
    else if (command === 'history') out = await history(pool, arg);
    else if (command === 'replay') out = await replay(pool, arg);
    else out = await audit(pool, Math.min(500, Number(arg) || 50));
    console.log(JSON.stringify(out, null, 2));
    return out && out.ok === false ? 1 : 0;
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  main(process.argv.slice(2)).then((code) => process.exit(code), (e) => { console.error(e.message); process.exit(1); });
}

module.exports = { status, history, replay, audit, poolFromEnv };
