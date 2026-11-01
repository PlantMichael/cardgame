'use strict';
// DDL for the account/ladder tables the relay has always owned (players,
// sessions, decks, owned_cards, ranked_settlements).
//
// This lived inside relay.js, which cannot be required without starting a
// WebSocket server, so a test had no way to create the schema it tests
// against except by re-typing it. Re-typed DDL drifts from the deployed
// shape and makes the test lie; relay.js now calls this module, so a
// DB-backed test runs against exactly the statements the relay runs.
//
// The server-run match tables (ranked_matches, ranked_match_actions,
// ranked_match_audit) are in authoritative/schema.js and reference players(id),
// so this schema has to exist first.

const LEGACY_DDL = [
  `CREATE TABLE IF NOT EXISTS players (
      id SERIAL PRIMARY KEY,
      username TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      salt TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      wins INTEGER NOT NULL DEFAULT 0,
      losses INTEGER NOT NULL DEFAULT 0,
      rating INTEGER NOT NULL DEFAULT 1000
    )`,
  // The players table above already exists on deployed databases, so new
  // columns must be added with ALTER TABLE — CREATE TABLE IF NOT EXISTS only
  // affects table creation, it won't retrofit columns onto an existing table.
  `ALTER TABLE players ADD COLUMN IF NOT EXISTS rank_bracket INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS rank_in_legend BOOLEAN NOT NULL DEFAULT false;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS rank_legend_rating INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS rank_lp INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS ranked_win_streak INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players DROP COLUMN IF EXISTS rank_floor;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS ranked_wins INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS ranked_losses INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS currency INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS dust INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS last_daily_reward_at DATE;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS pfp_id TEXT NOT NULL DEFAULT '';`,
  `CREATE TABLE IF NOT EXISTS sessions (
      token TEXT PRIMARY KEY,
      player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )`,
  // Custom decks, tied to the account instead of the browser (see save_deck/
  // delete_deck in relay.js) — one row per deck, keyed by (player_id, name) so
  // saving under an existing name overwrites it, mirroring the old
  // per-browser storage's filename-keyed behavior.
  `CREATE TABLE IF NOT EXISTS decks (
      id SERIAL PRIMARY KEY,
      player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      faction_idx INTEGER NOT NULL DEFAULT 0,
      card_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      UNIQUE (player_id, name)
    )`,
  // Card ownership (currency/shop/pack-unboxing feature) - one row per
  // (player, card) the player has ever obtained. No ownership concept
  // existed before this table; the deck builder previously treated every
  // card as available to everyone.
  `CREATE TABLE IF NOT EXISTS owned_cards (
      player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      card_id TEXT NOT NULL,
      quantity INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (player_id, card_id)
    )`,
  // One row per (match, player) that has been settled, holding the outcome
  // that was awarded. The primary key is what makes settlement idempotent:
  // a retry hits the existing row and is replayed the stored result instead
  // of moving the ladder a second time.
  `CREATE TABLE IF NOT EXISTS ranked_settlements (
      match_id TEXT NOT NULL,
      player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
      won BOOLEAN NOT NULL,
      outcome JSONB NOT NULL,
      settled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (match_id, player_id)
    )`,
  // Nullable for old clients and PvP. ALTER also upgrades populated installs.
  'ALTER TABLE ranked_settlements ADD COLUMN IF NOT EXISTS ai_match JSONB',
  // Site accounts / Google sign-in (additive; safe to rerun, safe on populated
  // installs). A player may sign in with a password, with one linked Google
  // identity, or both. The Google `sub` is the identity key: it is unique, and
  // an e-mail or display name is never used to find or merge a player.
  // password_hash/salt become nullable so a Google-only player is modelled
  // honestly instead of with a made-up password; the CHECK below keeps every
  // row with at least one usable way to sign in, and existing hashes/salts are
  // untouched.
  `ALTER TABLE players ADD COLUMN IF NOT EXISTS google_sub TEXT;
    ALTER TABLE players ADD COLUMN IF NOT EXISTS google_linked_at TIMESTAMPTZ;
    ALTER TABLE players ALTER COLUMN password_hash DROP NOT NULL;
    ALTER TABLE players ALTER COLUMN salt DROP NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS players_google_sub_key ON players (google_sub) WHERE google_sub IS NOT NULL;`,
  `DO $$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'players_has_sign_in' AND conrelid = 'players'::regclass) THEN
        ALTER TABLE players ADD CONSTRAINT players_has_sign_in
          CHECK ((password_hash IS NOT NULL AND salt IS NOT NULL) OR google_sub IS NOT NULL);
      END IF;
    END $$`,
];

async function initLegacySchema(pool) {
  for (const sql of LEGACY_DDL) await pool.query(sql);
}

module.exports = { LEGACY_DDL, initLegacySchema };
