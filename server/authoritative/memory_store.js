'use strict';
// In-memory implementation of the store interface in schema.js, used by tests
// (and usable for a database-less dev relay). Mirrors the Postgres behavior
// that matters: a duplicate (match_id, seq) is an error.

class MemoryStore {
  constructor({ decks = {} } = {}) {
    this.matches = new Map();
    this.actions = new Map();
    this.auditLog = [];
    this.decks = decks; // key `${player_id}:${deck_name}` -> { faction_idx, card_ids }
  }

  async createMatch(m) {
    if (this.matches.has(m.match_id)) throw new Error('duplicate match');
    this.matches.set(m.match_id, { ...m, status: 'waiting', end_reason: null, winner_seat: null, final_state_hash: null, facts: null });
    this.actions.set(m.match_id, []);
  }

  async appendAction(a) {
    const list = this.actions.get(a.match_id);
    if (!list) throw new Error('unknown match');
    if (list.some((x) => x.seq === a.seq)) throw new Error('duplicate (match_id, seq)');
    list.push({ seq: a.seq, seat: a.seat, kind: a.kind, command: JSON.parse(JSON.stringify(a.command)), state_hash: a.state_hash });
  }

  async setStatus(match_id, f) {
    const m = this.matches.get(match_id);
    if (!m) throw new Error('unknown match');
    Object.assign(m, {
      status: f.status,
      end_reason: f.end_reason ?? m.end_reason,
      winner_seat: f.winner_seat ?? m.winner_seat,
      final_state_hash: f.final_state_hash ?? m.final_state_hash,
      facts: f.facts ?? m.facts,
    });
  }

  async loadActiveMatches() {
    return [...this.matches.values()]
      .filter((m) => m.status === 'waiting' || m.status === 'active')
      .map((m) => ({ ...m, actions: [...this.actions.get(m.match_id)].sort((x, y) => x.seq - y.seq) }));
  }

  async audit(a) { this.auditLog.push({ ...a, at: Date.now() }); }

  async loadDeck(player_id, deck_name) { return this.decks[`${player_id}:${deck_name}`] || null; }
}

module.exports = { MemoryStore };
