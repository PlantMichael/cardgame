'use strict';
// Owns server-run matches on the relay side: pairing -> match creation, seats,
// the command path (validate -> host -> LOG -> ack), clocks, disconnects,
// forfeits, settlement hand-off and resume-after-restart.
//
// The rules themselves run in the Godot match host (scripts/game/match_host.gd);
// this module never decides a game outcome. It only decides WHO may speak for a
// seat, in WHAT ORDER, and what happens when someone stops speaking.
//
// It is transport-agnostic: a "connection" is any object with send(obj) and
// close(); relay.js adapts websockets to it, tests use plain fakes.
const crypto = require('crypto');
const { validateDeck } = require('./decks');
const { validateClientMessage, publicReason, RateLimiter } = require('./protocol');

const DEFAULTS = {
  turnSeconds: 90,
  mulliganSeconds: 90,
  graceSeconds: 60,
  maxLiveMatches: 100,
  maxConsecutiveTimeouts: 3,
  finishedRetentionSeconds: 120,
};

const SEAT_ID = { a: 'host', b: 'guest' }; // internal player ids used by the host's views
const other = (letter) => (letter === 'a' ? 'b' : 'a');

class Seat {
  constructor(letter, playerId, now) {
    this.letter = letter;
    this.playerId = playerId;
    this.conn = null;
    this.epoch = 0;
    this.disconnectedAt = now; // nobody is connected until they join
    this.lastClientSeq = 0;
    this.limiter = null; // set by MatchManager._newSeat with the manager's clock
    this.consecutiveTimeouts = 0;
  }
}

class Session {
  constructor(matchId, meta) {
    this.id = matchId;
    Object.assign(this, meta); // seed, firstSeat, rulesVersion, deckA, deckB
    this.seats = {};
    this.seq = 0;
    this.status = 'waiting'; // waiting | active | finished | voided
    this.lastHash = '';
    this.views = { a: null, b: null };
    this.queue = Promise.resolve();
    this.clockKey = '';
    this.deadline = null; // epoch ms the responsible seat must act by
    this.mulliganDeadline = null;
    this.hostDown = false;
    this.finishedAt = null;
  }
}

class MatchManager {
  constructor({ store, host, cards, settle = null, now = () => Date.now(), config = {}, log = console }) {
    this.store = store;
    this.host = host;
    this.cards = cards;
    this.settle = settle;
    this.now = now;
    this.cfg = { ...DEFAULTS, ...config };
    this.log = log;
    this.sessions = new Map();
    this.byPlayer = new Map(); // playerId -> matchId (their current server-run match)
    if (host && host.on) {
      host.on('down', () => this._onHostDown());
      host.on('ready', () => this._onHostReady());
    }
  }

  // --- capacity / lookup ---------------------------------------------------

  liveCount() {
    let n = 0;
    for (const s of this.sessions.values()) if (s.status === 'waiting' || s.status === 'active') n += 1;
    return n;
  }

  canStart() {
    return this.host.ready && this.liveCount() < this.cfg.maxLiveMatches;
  }

  matchOf(playerId) {
    const id = this.byPlayer.get(playerId);
    return id ? this.sessions.get(id) || null : null;
  }

  _seatFor(sess, playerId) {
    for (const letter of ['a', 'b']) if (sess.seats[letter] && sess.seats[letter].playerId === playerId) return sess.seats[letter];
    return null;
  }

  _exclusive(sess, fn) {
    const run = sess.queue.then(fn, fn);
    sess.queue = run.catch(() => {});
    return run;
  }

  async _audit(reason, sess, playerId, detail) {
    await this.store.audit({ match_id: sess ? sess.id : null, player_id: playerId ?? null, reason, detail });
  }

  // --- creation --------------------------------------------------------------

  /**
   * Pairing -> match. Both decks are read from the database by name and validated
   * here; nothing about a deck, seed, first seat or participants comes from a client.
   */
  async createMatch({ matchId, a, b }) {
    if (!this.canStart()) return { ok: false, error: this.host.ready ? 'busy' : 'unavailable' };
    const decks = {};
    for (const [letter, p] of [['a', a], ['b', b]]) {
      const row = await this.store.loadDeck(p.playerId, p.deckName);
      if (!row) return { ok: false, error: 'invalid_deck', seat: letter, detail: 'no such deck' };
      const v = validateDeck(row.card_ids, row.faction_idx, this.cards);
      if (!v.ok) return { ok: false, error: 'invalid_deck', seat: letter, detail: v.error };
      decks[letter] = v.cardIds;
    }
    const seed = crypto.randomInt(0, 2 ** 47);
    const firstSeat = crypto.randomInt(0, 2) === 0 ? 'a' : 'b';
    const rulesVersion = this.host.rulesVersion;
    await this.store.createMatch({
      match_id: matchId, rules_version: rulesVersion, seed, first_seat: firstSeat,
      seat_a_player_id: a.playerId, seat_b_player_id: b.playerId, deck_a: decks.a, deck_b: decks.b,
    });
    const created = await this.host.request('create', {
      match_id: matchId, seed, first_seat: firstSeat, deck_a: decks.a, deck_b: decks.b, rules_version: rulesVersion,
    });
    if (!created.ok) {
      await this.store.setStatus(matchId, { status: 'voided', end_reason: 'voided_fault' });
      return { ok: false, error: 'unavailable', detail: created.error };
    }
    const sess = new Session(matchId, { seed, firstSeat, rulesVersion, deckA: decks.a, deckB: decks.b });
    sess.seats.a = this._newSeat('a', a.playerId);
    sess.seats.b = this._newSeat('b', b.playerId);
    sess.views = created.views;
    sess.lastHash = created.state_hash;
    this.sessions.set(matchId, sess);
    this.byPlayer.set(a.playerId, matchId);
    this.byPlayer.set(b.playerId, matchId);
    return { ok: true, matchId, firstSeat, seats: { a: a.playerId, b: b.playerId } };
  }

  _newSeat(letter, playerId) {
    const seat = new Seat(letter, playerId, this.now());
    seat.limiter = new RateLimiter(20, this.now);
    return seat;
  }

  // --- client messages ---------------------------------------------------------

  /** Entry point for every `match_*` message from an authenticated player. */
  async handleMessage(playerId, raw, conn) {
    const v = validateClientMessage(raw);
    if (!v.ok) {
      await this._audit('bad_frame', null, playerId, { reason: v.reason });
      this._send(conn, { type: 'match_error', reason: 'invalid' });
      return;
    }
    const msg = v.msg;
    const sess = this.sessions.get(msg.match_id);
    const seat = sess ? this._seatFor(sess, playerId) : null;
    if (!sess || !seat) {
      // Same answer for "no such match" and "not yours": a probe learns nothing.
      await this._audit(sess ? 'not_a_participant' : 'unknown_match', sess, playerId, { type: msg.type });
      this._send(conn, { type: 'match_error', match_id: msg.match_id, client_seq: msg.client_seq, reason: 'unknown_match' });
      return;
    }
    switch (msg.type) {
      case 'match_join': return this._exclusive(sess, () => this._join(sess, seat, msg, conn));
      case 'match_ping': return this._send(conn, { type: 'match_clock', match_id: sess.id, clock: this._clock(sess) });
      case 'match_command': case 'match_mulligan':
        return this._exclusive(sess, () => this._command(sess, seat, msg, conn, 'command'));
      case 'match_concede':
        return this._exclusive(sess, () => this._command(sess, seat, { ...msg, client_seq: seat.lastClientSeq + 1, cmd: { type: 'concede' } }, conn, 'concede'));
      default: return undefined;
    }
  }

  _send(conn, obj) {
    try { if (conn) conn.send(obj); } catch (e) { this.log.warn?.('send failed', e.message); }
  }

  _sendSeat(sess, letter, obj) {
    const seat = sess.seats[letter];
    if (seat && seat.conn) this._send(seat.conn, { match_id: sess.id, ...obj });
  }

  // --- join / reconnect -----------------------------------------------------------

  async _join(sess, seat, msg, conn) {
    if (sess.status === 'finished' || sess.status === 'voided') {
      this._send(conn, { type: 'match_error', match_id: sess.id, reason: 'unknown_match' });
      return;
    }
    // A seat has exactly one controlling connection; a newer one takes over.
    if (seat.conn && seat.conn !== conn) {
      await this._audit('seat_takeover', sess, seat.playerId, null);
      const old = seat.conn;
      seat.conn = null;
      try { old.close?.(); } catch { /* already gone */ }
    }
    const wasDisconnected = seat.disconnectedAt !== null;
    seat.epoch += 1;
    seat.conn = conn;
    seat.disconnectedAt = null;
    seat.consecutiveTimeouts = 0;
    conn.seatOf = conn.seatOf || new Map();
    conn.seatOf.set(sess.id, { letter: seat.letter, epoch: seat.epoch });

    const view = await this.host.request('view', { match_id: sess.id, seat: seat.letter });
    if (!view.ok) {
      this._send(conn, { type: 'match_error', match_id: sess.id, reason: 'unavailable' });
      return;
    }
    this._send(conn, {
      type: 'match_view', match_id: sess.id, seq: view.seq, you: SEAT_ID[seat.letter], seat: seat.letter,
      view: view.view, events: [], clock: this._clock(sess),
    });
    if (wasDisconnected) this._sendSeat(sess, other(seat.letter), { type: 'opponent_reconnected' });

    if (sess.status === 'waiting' && sess.seats.a.conn && sess.seats.b.conn) {
      sess.status = 'active';
      sess.mulliganDeadline = this.now() + this.cfg.mulliganSeconds * 1000;
      await this.store.setStatus(sess.id, { status: 'active' });
      for (const letter of ['a', 'b']) this._sendSeat(sess, letter, { type: 'match_clock', clock: this._clock(sess) });
    }
  }

  // --- the command path ---------------------------------------------------------------

  async _command(sess, seat, msg, conn, kind) {
    const refuse = async (reason, internal) => {
      await this._audit(internal || reason, sess, seat.playerId, { type: msg.cmd && msg.cmd.type });
      this._send(conn, { type: 'match_error', match_id: sess.id, client_seq: msg.client_seq, reason: publicReason(reason) });
    };
    // Only the seat's CURRENT connection may speak for it.
    if (seat.conn !== conn) return refuse('illegal', 'stale_connection');
    if (sess.status !== 'active' && sess.status !== 'waiting') return refuse('illegal', 'match_not_active');
    if (sess.hostDown) return refuse('unavailable', 'host_down');
    if (!seat.limiter.take()) return refuse('rate_limited');
    if (msg.client_seq <= seat.lastClientSeq) return refuse('duplicate');
    seat.lastClientSeq = msg.client_seq;

    const reply = await this.host.request('command', { match_id: sess.id, seat: seat.letter, cmd: msg.cmd, expect_seq: sess.seq });
    if (!reply.ok) {
      if (reply.error === 'host_fault') return refuse('unavailable', 'host_fault');
      return refuse(reply.error === 'stale_seq' ? 'stale' : 'illegal', `refused:${reply.error}`);
    }
    await this._accept(sess, seat, reply, kind === 'concede' ? 'concede' : (msg.cmd.type === 'answer_choice' ? 'answer' : 'command'), msg.cmd);
    seat.consecutiveTimeouts = 0;
    this._send(conn, { type: 'match_ack', match_id: sess.id, client_seq: msg.client_seq });
    await this._broadcast(sess, reply);
  }

  /** Logs an accepted host reply BEFORE anything is acknowledged or shown. */
  async _accept(sess, seat, reply, kind, cmd) {
    try {
      await this.store.appendAction({
        match_id: sess.id, seq: reply.seq, seat: seat.letter, kind, command: cmd, state_hash: reply.state_hash,
      });
    } catch (e) {
      // The match advanced in the host but could not be logged: it can no longer
      // be resumed or audited, so it must not continue.
      this.log.error?.('action log failed; voiding match', sess.id, e.message);
      await this._void(sess, 'voided_fault');
      throw e;
    }
    sess.seq = reply.seq;
    sess.lastHash = reply.state_hash;
    sess.views = reply.views;
  }

  async _broadcast(sess, reply) {
    this._updateClock(sess);
    for (const letter of ['a', 'b']) {
      this._sendSeat(sess, letter, {
        type: 'match_view', seq: reply.seq, you: SEAT_ID[letter], seat: letter,
        view: reply.views[letter], events: reply.events[letter], clock: this._clock(sess),
      });
    }
    if (reply.over) await this._finish(sess, reply.over);
  }

  // --- clocks -----------------------------------------------------------------------------

  /** Who must act now: the open choice's owner, else the active player. */
  _responsible(sess) {
    const va = sess.views.a;
    if (!va) return null;
    if (va.pending_choice && va.pending_choice.id) return { seat: 'a', key: `choice:${va.pending_choice.id}` };
    const vb = sess.views.b;
    if (vb && vb.pending_choice && vb.pending_choice.id) return { seat: 'b', key: `choice:${vb.pending_choice.id}` };
    const active = va.active_player_id === 'host' ? 'a' : 'b';
    return { seat: active, key: `turn:${va.turn_number}:${va.active_player_id}` };
  }

  _updateClock(sess) {
    const mulligan = sess.views.a && Object.keys(sess.views.a.mulligan_pending || {}).length > 0;
    if (mulligan) return; // the mulligan clock runs on mulliganDeadline
    sess.mulliganDeadline = null;
    const r = this._responsible(sess);
    if (!r) return;
    if (r.key !== sess.clockKey) {
      sess.clockKey = r.key;
      sess.responsibleSeat = r.seat;
      sess.deadline = this.now() + this.cfg.turnSeconds * 1000;
    }
  }

  _clock(sess) {
    const t = this.now();
    const out = {};
    if (sess.mulliganDeadline) out.mulligan_remaining_s = Math.max(0, Math.ceil((sess.mulliganDeadline - t) / 1000));
    else if (sess.deadline) { out.turn_remaining_s = Math.max(0, Math.ceil((sess.deadline - t) / 1000)); out.responsible = sess.responsibleSeat; }
    for (const letter of ['a', 'b']) {
      const s = sess.seats[letter];
      if (s && s.disconnectedAt !== null && sess.status === 'active') {
        out[`${letter}_disconnect_remaining_s`] = Math.max(0, Math.ceil((s.disconnectedAt + this.cfg.graceSeconds * 1000 - t) / 1000));
      }
    }
    return out;
  }

  /** Called by a 1-second timer in relay.js (and directly, with a fake clock, in tests). */
  async tick() {
    const t = this.now();
    for (const sess of [...this.sessions.values()]) {
      if (sess.status === 'finished' || sess.status === 'voided') {
        if (sess.finishedAt && t - sess.finishedAt > this.cfg.finishedRetentionSeconds * 1000) this._forget(sess);
        continue;
      }
      if (sess.status !== 'active' || sess.hostDown) continue;
      await this._exclusive(sess, () => this._tickSession(sess, t));
    }
  }

  async _tickSession(sess, t) {
    if (sess.status !== 'active') return;
    const g = this.cfg.graceSeconds * 1000;
    const gone = ['a', 'b'].filter((l) => sess.seats[l].disconnectedAt !== null && t - sess.seats[l].disconnectedAt >= g);
    if (gone.length === 2) return this._abandon(sess);
    if (gone.length === 1) return this._forfeit(sess, gone[0], 'forfeit_disconnect');

    if (sess.mulliganDeadline) {
      if (t >= sess.mulliganDeadline) {
        const pending = Object.keys(sess.views.a.mulligan_pending || {});
        for (const id of pending) await this._timeout(sess, id === 'host' ? 'a' : 'b');
      }
      return undefined;
    }
    if (sess.deadline && t >= sess.deadline) {
      const letter = sess.responsibleSeat;
      const seat = sess.seats[letter];
      seat.consecutiveTimeouts += 1;
      if (seat.consecutiveTimeouts >= this.cfg.maxConsecutiveTimeouts) return this._forfeit(sess, letter, 'forfeit_timeout');
      await this._timeout(sess, letter);
    }
    return undefined;
  }

  async _timeout(sess, letter) {
    const reply = await this.host.request('timeout', { match_id: sess.id, seat: letter });
    if (!reply.ok) {
      this.log.warn?.('timeout refused', sess.id, reply.error);
      sess.deadline = this.now() + this.cfg.turnSeconds * 1000;
      return;
    }
    await this._accept(sess, sess.seats[letter], reply, 'timeout_default', { type: 'timeout_default' });
    sess.clockKey = '';
    await this._broadcast(sess, reply);
  }

  // --- disconnects / endings ----------------------------------------------------------------

  /** A connection closed. Only the seat's CURRENT connection counts as leaving. */
  onClose(conn) {
    for (const sess of this.sessions.values()) {
      for (const letter of ['a', 'b']) {
        const seat = sess.seats[letter];
        if (seat && seat.conn === conn) {
          seat.conn = null;
          seat.disconnectedAt = this.now();
          if (sess.status === 'active' || sess.status === 'waiting') {
            this._sendSeat(sess, other(letter), { type: 'opponent_disconnected', remaining_s: this.cfg.graceSeconds });
          }
        }
      }
    }
  }

  async _forfeit(sess, loserLetter, reason) {
    const reply = await this.host.request('command', { match_id: sess.id, seat: loserLetter, cmd: { type: 'concede' }, expect_seq: sess.seq });
    if (!reply.ok) return this._void(sess, 'voided_fault');
    await this._accept(sess, sess.seats[loserLetter], reply, 'forfeit', { type: 'concede' });
    for (const letter of ['a', 'b']) {
      this._sendSeat(sess, letter, {
        type: 'match_view', seq: reply.seq, you: SEAT_ID[letter], seat: letter,
        view: reply.views[letter], events: reply.events[letter], clock: this._clock(sess),
      });
    }
    return this._finish(sess, reply.over, reason);
  }

  async _abandon(sess) {
    sess.status = 'finished';
    sess.finishedAt = this.now();
    await this.store.setStatus(sess.id, { status: 'finished', end_reason: 'abandoned', final_state_hash: sess.lastHash });
    await this.host.request('drop', { match_id: sess.id });
    // Nobody is connected to be told; nothing is settled.
    this._release(sess);
  }

  async _void(sess, reason) {
    if (sess.status === 'voided') return;
    sess.status = 'voided';
    sess.finishedAt = this.now();
    await this.store.setStatus(sess.id, { status: 'voided', end_reason: reason });
    await this.host.request('drop', { match_id: sess.id });
    for (const letter of ['a', 'b']) this._sendSeat(sess, letter, { type: 'match_voided', reason: 'no_rank_change' });
    this._release(sess);
  }

  async _finish(sess, over, endReasonOverride) {
    if (sess.status === 'finished') return;
    sess.status = 'finished';
    sess.finishedAt = this.now();
    const endReason = endReasonOverride || over.reason || 'completed';
    await this.store.setStatus(sess.id, {
      status: 'finished', end_reason: endReason, winner_seat: over.winner || null,
      final_state_hash: sess.lastHash, facts: over.facts || null,
    });
    await this.host.request('drop', { match_id: sess.id });
    let outcomes = {};
    if (this.settle) {
      try { outcomes = (await this.settle(sess, { winner: over.winner, endReason, facts: over.facts || null })) || {}; }
      catch (e) { this.log.error?.('settlement failed', sess.id, e.message); await this._audit('settle_failed', sess, null, { message: e.message }); }
    }
    for (const letter of ['a', 'b']) {
      const seat = sess.seats[letter];
      this._sendSeat(sess, letter, {
        type: 'match_over', end_reason: endReason, winner_is_me: over.winner === letter,
        draw: !over.winner, ranked_outcome: outcomes[seat.playerId] || null,
      });
    }
    this._release(sess);
  }

  _release(sess) {
    for (const letter of ['a', 'b']) {
      const seat = sess.seats[letter];
      if (seat && this.byPlayer.get(seat.playerId) === sess.id) this.byPlayer.delete(seat.playerId);
    }
  }

  _forget(sess) { this.sessions.delete(sess.id); this._release(sess); }

  // --- host restarts: resume from the log ----------------------------------------------------------

  _onHostDown() {
    for (const sess of this.sessions.values()) if (sess.status === 'active' || sess.status === 'waiting') sess.hostDown = true;
  }

  async _onHostReady() {
    await this.resume();
  }

  /**
   * Rebuilds every live match in the host from its logged commands. A match whose
   * replay does not end on the last logged state hash is voided (no rank change).
   */
  async resume() {
    const rows = await this.store.loadActiveMatches();
    for (const row of rows) {
      let sess = this.sessions.get(row.match_id);
      if (!sess) {
        sess = new Session(row.match_id, {
          seed: row.seed, firstSeat: row.first_seat, rulesVersion: row.rules_version, deckA: row.deck_a, deckB: row.deck_b,
        });
        sess.seats.a = this._newSeat('a', row.seat_a_player_id);
        sess.seats.b = this._newSeat('b', row.seat_b_player_id);
        sess.status = row.status;
        this.sessions.set(row.match_id, sess);
        this.byPlayer.set(row.seat_a_player_id, row.match_id);
        this.byPlayer.set(row.seat_b_player_id, row.match_id);
      }
      await this._exclusive(sess, async () => {
        const actions = row.actions.map((a) => ({ seat: a.seat, kind: a.kind === 'timeout_default' ? 'timeout_default' : 'command', cmd: a.command }));
        const rep = await this.host.request('replay', {
          match_id: row.match_id, seed: row.seed, first_seat: row.first_seat, rules_version: row.rules_version,
          deck_a: row.deck_a, deck_b: row.deck_b, actions,
        });
        const expected = row.actions.length ? row.actions[row.actions.length - 1].state_hash : null;
        if (!rep.ok || (expected && rep.state_hash !== expected)) {
          await this._audit('resume_mismatch', sess, null, { error: rep.error, expected, got: rep.state_hash });
          await this._void(sess, 'voided_fault');
          return;
        }
        sess.seq = rep.seq;
        sess.lastHash = rep.state_hash;
        for (const letter of ['a', 'b']) {
          const v = await this.host.request('view', { match_id: row.match_id, seat: letter });
          if (v.ok) sess.views[letter] = v.view;
        }
        sess.clockKey = '';
        this._updateClock(sess);
        sess.hostDown = false;
      });
    }
    // Sessions the host no longer knows and the store no longer lists are void.
    for (const sess of this.sessions.values()) if (sess.hostDown && sess.status === 'active') await this._void(sess, 'voided_fault');
  }
}

module.exports = { MatchManager, DEFAULTS, SEAT_ID };
