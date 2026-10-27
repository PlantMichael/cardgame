'use strict';
// PgStore and PgSettleRepo against a real Postgres (spec 003, T050 groundwork).
//
// Every other suite here runs on MemoryStore and an in-memory settle repo, so
// until this file existed neither Postgres class had executed a single SQL
// statement: column names, types and the idempotency key were only ever
// checked by eye against the legacy relay code.
//
// SKIPPED unless DATABASE_URL points at a DISPOSABLE database - these tests
// TRUNCATE players, decks and the ranked_* tables.
//
//   docker run -d --name cardgame-pg -e POSTGRES_PASSWORD=pg -p 5433:5432 postgres:16
//   DATABASE_URL=postgres://postgres:pg@127.0.0.1:5433/postgres npm test
const test = require('node:test');
const assert = require('node:assert/strict');
const { Pool } = require('pg');
const { initLegacySchema } = require('../schema_legacy');
const { initSchema, PgStore } = require('../authoritative/schema');
const { settleRankedMatch, PgSettleRepo } = require('../authoritative/settle');
const { nextRankState, nextElo } = require('../ladder');
const { disposableDatabase } = require('./helpers');

const DB_URL = process.env.DATABASE_URL || '';

const skip = DB_URL
  ? (disposableDatabase(DB_URL) ? false : 'DATABASE_URL does not look disposable; refusing to truncate it')
  : 'DATABASE_URL is not set';

// A seed past 2^32: the column is BIGINT, which pg hands back as a string, and
// the host rejects a seed it cannot use as an integer.
const BIG_SEED = 4503599627370496;

let pool = null;
async function db() {
  if (!pool) {
    pool = new Pool({ connectionString: DB_URL, ssl: false, max: 4, connectionTimeoutMillis: 5000 });
    await initLegacySchema(pool);
    await initSchema(pool);
  }
  await pool.query(`TRUNCATE ranked_match_actions, ranked_match_audit, ranked_matches,
    ranked_settlements, decks, owned_cards, sessions, players RESTART IDENTITY CASCADE`);
  return pool;
}

test.after(async () => { if (pool) await pool.end(); });

async function newPlayer(p, username, over = {}) {
  const row = { rating: 1000, rank_bracket: 0, rank_lp: 0, ranked_win_streak: 0, ranked_wins: 0, ranked_losses: 0, ...over };
  const { rows } = await p.query(
    `INSERT INTO players (username, password_hash, salt, rating, rank_bracket, rank_lp,
       ranked_win_streak, ranked_wins, ranked_losses)
     VALUES ($1, 'x', 'y', $2, $3, $4, $5, $6, $7) RETURNING id`,
    [username, row.rating, row.rank_bracket, row.rank_lp, row.ranked_win_streak, row.ranked_wins, row.ranked_losses]);
  return rows[0].id;
}

const matchRow = (over = {}) => ({
  match_id: 'rk_pg_1', rules_version: 7, seed: BIG_SEED, first_seat: 'a',
  seat_a_player_id: null, seat_b_player_id: null,
  deck_a: ['g_001', 'g_002'], deck_b: ['c_001'], ...over,
});

test('a created match comes back with the fields resume() reads, typed as it expects', { skip }, async () => {
  const p = await db();
  const store = new PgStore(p);
  const a = await newPlayer(p, 'pg_a');
  const b = await newPlayer(p, 'pg_b');
  await store.createMatch(matchRow({ seat_a_player_id: a, seat_b_player_id: b }));

  const [row] = await store.loadActiveMatches();
  assert.equal(row.match_id, 'rk_pg_1');
  assert.equal(row.status, 'waiting');
  // resume() passes these straight to the host, so the JS types matter.
  assert.equal(typeof row.seed, 'number');
  assert.equal(row.seed, BIG_SEED);
  assert.equal(row.rules_version, 7);
  assert.equal(row.first_seat, 'a');
  assert.deepEqual(row.deck_a, ['g_001', 'g_002']);
  assert.deepEqual(row.deck_b, ['c_001']);
  assert.equal(row.seat_a_player_id, a);
  assert.equal(row.seat_b_player_id, b);
  assert.deepEqual(row.actions, []);
});

test('the primary key rejects a duplicate (match_id, seq)', { skip }, async () => {
  const p = await db();
  const store = new PgStore(p);
  await store.createMatch(matchRow());
  const act = { match_id: 'rk_pg_1', seq: 1, seat: 'a', kind: 'command', command: { type: 'end_turn' }, state_hash: 'h1' };
  await store.appendAction(act);
  await assert.rejects(() => store.appendAction({ ...act, state_hash: 'h2' }), /duplicate key|unique/i);
  // A match that does not exist is refused by the foreign key, not recorded.
  await assert.rejects(() => store.appendAction({ ...act, match_id: 'nope', seq: 1 }), /foreign key/i);
});

test('setStatus records the ending and keeps started_at across calls', { skip }, async () => {
  const p = await db();
  const store = new PgStore(p);
  await store.createMatch(matchRow());
  await store.setStatus('rk_pg_1', { status: 'active' });
  const first = await p.query('SELECT started_at, ended_at FROM ranked_matches WHERE match_id = $1', ['rk_pg_1']);
  assert.ok(first.rows[0].started_at, 'started_at set on activation');
  assert.equal(first.rows[0].ended_at, null);

  await store.setStatus('rk_pg_1', { status: 'active' }); // a second activation must not move it
  await store.setStatus('rk_pg_1', {
    status: 'finished', end_reason: 'completed', winner_seat: 'b',
    final_state_hash: 'deadbeef', facts: { turns: 12, cards_played: 30 },
  });
  const { rows } = await p.query('SELECT * FROM ranked_matches WHERE match_id = $1', ['rk_pg_1']);
  assert.equal(rows[0].started_at.getTime(), first.rows[0].started_at.getTime());
  assert.equal(rows[0].status, 'finished');
  assert.equal(rows[0].end_reason, 'completed');
  assert.equal(rows[0].winner_seat, 'b');
  assert.equal(rows[0].final_state_hash, 'deadbeef');
  assert.deepEqual(rows[0].facts, { turns: 12, cards_played: 30 });
  assert.ok(rows[0].ended_at);

  // COALESCE: a later status change with nothing else must not erase the result.
  await store.setStatus('rk_pg_1', { status: 'finished' });
  const after = await p.query('SELECT winner_seat, end_reason, facts FROM ranked_matches WHERE match_id = $1', ['rk_pg_1']);
  assert.equal(after.rows[0].winner_seat, 'b');
  assert.equal(after.rows[0].end_reason, 'completed');
  assert.deepEqual(after.rows[0].facts, { turns: 12, cards_played: 30 });
});

test('loadActiveMatches lists only live matches, with their actions in seq order', { skip }, async () => {
  const p = await db();
  const store = new PgStore(p);
  await store.createMatch(matchRow({ match_id: 'live_1' }));
  await store.createMatch(matchRow({ match_id: 'live_2' }));
  await store.createMatch(matchRow({ match_id: 'done_1' }));
  await store.setStatus('live_2', { status: 'active' });
  await store.setStatus('done_1', { status: 'finished', end_reason: 'completed' });

  // Inserted out of order on purpose: the ORDER BY is what resume() relies on.
  for (const seq of [3, 1, 2]) {
    await store.appendAction({
      match_id: 'live_2', seq, seat: seq % 2 ? 'a' : 'b',
      kind: seq === 3 ? 'timeout_default' : 'command',
      command: { type: 'end_turn', n: seq }, state_hash: `h${seq}`,
    });
  }
  const rows = await store.loadActiveMatches();
  assert.deepEqual(rows.map((r) => r.match_id), ['live_1', 'live_2']);
  const live2 = rows.find((r) => r.match_id === 'live_2');
  assert.deepEqual(live2.actions.map((a) => a.seq), [1, 2, 3]);
  assert.deepEqual(live2.actions.map((a) => a.kind), ['command', 'command', 'timeout_default']);
  assert.deepEqual(live2.actions[1].command, { type: 'end_turn', n: 2 });
  assert.equal(live2.actions.at(-1).state_hash, 'h3');
});

test('audit writes a row, and a failing audit never reaches the caller', { skip }, async () => {
  const p = await db();
  const store = new PgStore(p);
  const id = await newPlayer(p, 'pg_audit');
  await store.createMatch(matchRow());
  await store.audit({ match_id: 'rk_pg_1', player_id: id, reason: 'rate_limited', detail: { type: 'match_command' } });
  await store.audit({ reason: 'refused', detail: null }); // no match, no player: still allowed
  const { rows } = await p.query('SELECT match_id, player_id, reason, detail FROM ranked_match_audit ORDER BY id');
  assert.equal(rows.length, 2);
  assert.deepEqual(rows[0].detail, { type: 'match_command' });
  assert.equal(rows[1].match_id, null);

  // Auditing must never break a match in progress (schema.js swallows it).
  const broken = new PgStore({ query: async () => { throw new Error('connection terminated'); } });
  await broken.audit({ reason: 'whatever' });
});

test('loadDeck reads a stored deck and returns null for an unknown name', { skip }, async () => {
  const p = await db();
  const store = new PgStore(p);
  const id = await newPlayer(p, 'pg_decks');
  await p.query('INSERT INTO decks (player_id, name, faction_idx, card_ids) VALUES ($1, $2, $3, $4)',
    [id, 'Ladder', 2, JSON.stringify(['g_001', 'g_001', 'gen_001'])]);
  const deck = await store.loadDeck(id, 'Ladder');
  assert.equal(deck.faction_idx, 2);
  assert.deepEqual(deck.card_ids, ['g_001', 'g_001', 'gen_001']);
  assert.equal(await store.loadDeck(id, 'Missing'), null);
  assert.equal(await store.loadDeck(id + 999, 'Ladder'), null);
});

test('settlement moves both ladders once, by the same math as the legacy path', { skip }, async () => {
  const p = await db();
  const winner = await newPlayer(p, 'pg_w', { rating: 1000, rank_lp: 20 });
  const loser = await newPlayer(p, 'pg_l', { rating: 1100, rank_lp: 50 });
  const before = (await p.query('SELECT * FROM players WHERE id IN ($1, $2) ORDER BY id', [winner, loser])).rows;

  const out = await settleRankedMatch(new PgSettleRepo(p), {
    matchId: 'rk_pg_settle', seats: { a: winner, b: loser }, winner: 'a', endReason: 'completed',
  });

  const expectW = nextRankState(before[0], true);
  const expectL = nextRankState(before[1], false);
  assert.equal(out[winner].rank_lp, expectW.rank_lp);
  assert.equal(out[loser].rank_lp, expectL.rank_lp);
  assert.equal(out[winner].rating, nextElo(before[0].rating, before[1].rating, true));
  assert.equal(out[loser].rating, nextElo(before[1].rating, before[0].rating, false));

  const rows = (await p.query('SELECT id, rank_lp, rating, ranked_wins, ranked_losses, ranked_win_streak FROM players ORDER BY id')).rows;
  assert.equal(rows[0].rank_lp, expectW.rank_lp);
  assert.equal(rows[0].ranked_wins, 1);
  assert.equal(rows[0].ranked_win_streak, 1);
  assert.equal(rows[1].ranked_losses, 1);
  assert.equal(rows[1].rating, out[loser].rating);

  const settle = (await p.query('SELECT player_id, won, outcome FROM ranked_settlements WHERE match_id = $1 ORDER BY player_id', ['rk_pg_settle'])).rows;
  assert.equal(settle.length, 2);
  assert.equal(settle.find((r) => r.player_id === winner).won, true);
  assert.equal(settle.find((r) => r.player_id === loser).won, false);
  assert.equal(settle.find((r) => r.player_id === winner).outcome.rank_lp, expectW.rank_lp);
});

test('a repeated settlement replays the stored outcome and awards nothing twice', { skip }, async () => {
  const p = await db();
  const a = await newPlayer(p, 'pg_r1');
  const b = await newPlayer(p, 'pg_r2');
  const match = { matchId: 'rk_pg_retry', seats: { a, b }, winner: 'b', endReason: 'forfeit_disconnect' };

  const first = await settleRankedMatch(new PgSettleRepo(p), match);
  const afterFirst = (await p.query('SELECT id, rank_lp, rating, ranked_wins, ranked_losses FROM players ORDER BY id')).rows;

  const again = await settleRankedMatch(new PgSettleRepo(p), match);
  assert.equal(again[a].replayed, true);
  assert.equal(again[b].replayed, true);
  assert.equal(again[b].rank_lp, first[b].rank_lp);

  const afterSecond = (await p.query('SELECT id, rank_lp, rating, ranked_wins, ranked_losses FROM players ORDER BY id')).rows;
  assert.deepEqual(afterSecond, afterFirst, 'the second settlement moved nothing');
  const { rows } = await p.query('SELECT count(*)::int AS n FROM ranked_settlements WHERE match_id = $1', ['rk_pg_retry']);
  assert.equal(rows[0].n, 2);
});

test('two settlements racing for the same match still award once', { skip }, async () => {
  const p = await db();
  const a = await newPlayer(p, 'pg_race1');
  const b = await newPlayer(p, 'pg_race2');
  const match = { matchId: 'rk_pg_race', seats: { a, b }, winner: 'a', endReason: 'conceded' };

  const [one, two] = await Promise.all([
    settleRankedMatch(new PgSettleRepo(p), match),
    settleRankedMatch(new PgSettleRepo(p), match),
  ]);
  // Whichever transaction got there first awarded; the other replayed.
  const replayed = [one, two].filter((r) => r[a] && r[a].replayed).length;
  assert.equal(replayed, 1, 'exactly one of the two replayed');
  assert.equal(one[a].rank_lp, two[a].rank_lp);

  const rows = (await p.query('SELECT ranked_wins, ranked_losses FROM players ORDER BY id')).rows;
  assert.equal(rows[0].ranked_wins, 1);
  assert.equal(rows[1].ranked_losses, 1);
  const n = await p.query('SELECT count(*)::int AS n FROM ranked_settlements WHERE match_id = $1', ['rk_pg_race']);
  assert.equal(n.rows[0].n, 2);
});

test('an abandoned match settles nothing and writes no row', { skip }, async () => {
  const p = await db();
  const a = await newPlayer(p, 'pg_ab1');
  const b = await newPlayer(p, 'pg_ab2');
  const out = await settleRankedMatch(new PgSettleRepo(p), {
    matchId: 'rk_pg_abandon', seats: { a, b }, winner: null, endReason: 'abandoned',
  });
  assert.deepEqual(out, {});
  const n = await p.query('SELECT count(*)::int AS n FROM ranked_settlements');
  assert.equal(n.rows[0].n, 0);
  const rows = (await p.query('SELECT rank_lp, ranked_wins, ranked_losses FROM players')).rows;
  for (const r of rows) assert.deepEqual([r.rank_lp, r.ranked_wins, r.ranked_losses], [0, 0, 0]);
});

test('a player row that has gone missing settles nothing', { skip }, async () => {
  const p = await db();
  const a = await newPlayer(p, 'pg_gone');
  const out = await settleRankedMatch(new PgSettleRepo(p), {
    matchId: 'rk_pg_gone', seats: { a, b: a + 4242 }, winner: 'a', endReason: 'completed',
  });
  assert.deepEqual(out, {});
  const n = await p.query('SELECT count(*)::int AS n FROM ranked_settlements');
  assert.equal(n.rows[0].n, 0);
});
