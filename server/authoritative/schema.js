'use strict';
// Persistence for server-run matches (data-model.md): DDL plus the Postgres
// store the match manager talks to. The manager depends only on the store
// interface, so tests use MemoryStore (memory_store.js) and need no database.

const DDL = [
  `CREATE TABLE IF NOT EXISTS ranked_matches (
    match_id TEXT PRIMARY KEY,
    mode TEXT NOT NULL DEFAULT 'authoritative',
    status TEXT NOT NULL,
    end_reason TEXT,
    rules_version INTEGER NOT NULL,
    seed BIGINT NOT NULL,
    first_seat TEXT NOT NULL,
    seat_a_player_id INTEGER REFERENCES players(id) ON DELETE SET NULL,
    seat_b_player_id INTEGER REFERENCES players(id) ON DELETE SET NULL,
    deck_a JSONB NOT NULL,
    deck_b JSONB NOT NULL,
    winner_seat TEXT,
    final_state_hash TEXT,
    facts JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ
  )`,
  `CREATE TABLE IF NOT EXISTS ranked_match_actions (
    match_id TEXT NOT NULL REFERENCES ranked_matches(match_id) ON DELETE CASCADE,
    seq INTEGER NOT NULL,
    seat TEXT NOT NULL,
    kind TEXT NOT NULL,
    command JSONB NOT NULL,
    state_hash TEXT NOT NULL,
    at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (match_id, seq)
  )`,
  `CREATE TABLE IF NOT EXISTS ranked_match_audit (
    id SERIAL PRIMARY KEY,
    match_id TEXT,
    player_id INTEGER,
    at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reason TEXT NOT NULL,
    detail JSONB
  )`,
  'CREATE INDEX IF NOT EXISTS ranked_matches_status_idx ON ranked_matches (status)',
];

async function initSchema(pool) {
  for (const sql of DDL) await pool.query(sql);
}

class PgStore {
  constructor(pool) { this.pool = pool; }

  async createMatch(m) {
    await this.pool.query(
      `INSERT INTO ranked_matches (match_id, status, rules_version, seed, first_seat,
         seat_a_player_id, seat_b_player_id, deck_a, deck_b)
       VALUES ($1, 'waiting', $2, $3, $4, $5, $6, $7, $8)`,
      [m.match_id, m.rules_version, m.seed, m.first_seat, m.seat_a_player_id, m.seat_b_player_id,
        JSON.stringify(m.deck_a), JSON.stringify(m.deck_b)],
    );
  }

  // The PRIMARY KEY (match_id, seq) is what enforces a single ordering: a
  // duplicate or out-of-order insert throws instead of being recorded.
  async appendAction(a) {
    await this.pool.query(
      `INSERT INTO ranked_match_actions (match_id, seq, seat, kind, command, state_hash)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [a.match_id, a.seq, a.seat, a.kind, JSON.stringify(a.command), a.state_hash],
    );
  }

  async setStatus(match_id, f) {
    await this.pool.query(
      `UPDATE ranked_matches SET status = $2,
         end_reason = COALESCE($3, end_reason),
         winner_seat = COALESCE($4, winner_seat),
         final_state_hash = COALESCE($5, final_state_hash),
         facts = COALESCE($6, facts),
         started_at = CASE WHEN $2 = 'active' THEN COALESCE(started_at, now()) ELSE started_at END,
         ended_at = CASE WHEN $2 IN ('finished', 'voided') THEN now() ELSE ended_at END
       WHERE match_id = $1`,
      [match_id, f.status, f.end_reason ?? null, f.winner_seat ?? null, f.final_state_hash ?? null,
        f.facts ? JSON.stringify(f.facts) : null],
    );
  }

  async loadActiveMatches() {
    const { rows } = await this.pool.query(
      `SELECT * FROM ranked_matches WHERE status IN ('waiting', 'active') ORDER BY created_at`,
    );
    const out = [];
    for (const r of rows) {
      const acts = await this.pool.query(
        'SELECT seq, seat, kind, command, state_hash FROM ranked_match_actions WHERE match_id = $1 ORDER BY seq',
        [r.match_id],
      );
      out.push({ ...r, seed: Number(r.seed), actions: acts.rows });
    }
    return out;
  }

  async audit(a) {
    try {
      await this.pool.query(
        'INSERT INTO ranked_match_audit (match_id, player_id, reason, detail) VALUES ($1, $2, $3, $4)',
        [a.match_id ?? null, a.player_id ?? null, a.reason, a.detail ? JSON.stringify(a.detail) : null],
      );
    } catch (e) {
      console.error('audit write failed', e.message); // never let auditing break a match
    }
  }

  async loadDeck(player_id, deck_name) {
    const { rows } = await this.pool.query(
      'SELECT faction_idx, card_ids FROM decks WHERE player_id = $1 AND name = $2',
      [player_id, deck_name],
    );
    return rows[0] ? { faction_idx: rows[0].faction_idx, card_ids: rows[0].card_ids } : null;
  }
}

module.exports = { DDL, initSchema, PgStore };
