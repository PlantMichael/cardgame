'use strict';
// Client <-> relay message validation for server-run matches
// (contracts/client-match-protocol.md). A client message is untrusted input:
// every field is checked, copied into a fresh object and anything unknown is
// dropped, so nothing a modified client adds can reach the rules.

const MAX_FRAME_BYTES = 8192;
const ACTIONS_PER_SECOND = 20;
const MATCH_ID = /^[A-Za-z0-9_-]{1,64}$/;

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isStr = (v, max = 96) => typeof v === 'string' && v.length <= max && !v.includes('\0');
const isInt = (v, lo = -1e9, hi = 1e9) => Number.isInteger(v) && v >= lo && v <= hi;

// type -> field spec. `req` fields must be present; `opt` are copied if valid.
const COMMANDS = {
  play_creature: { req: { card_uid: (v) => isStr(v, 64) }, opt: { at_index: (v) => isInt(v, -1, 20) } },
  play_stratagem: {
    req: { card_uid: (v) => isStr(v, 64) },
    opt: { target_instance_id: (v) => isStr(v), target_player_id: (v) => isStr(v, 16) },
  },
  attack: {
    req: { attacker_instance_id: (v) => isStr(v) },
    opt: { target_instance_id: (v) => isStr(v), target_player_id: (v) => isStr(v, 16) },
  },
  pilot: { req: { pilot_instance_id: (v) => isStr(v), target_instance_id: (v) => isStr(v) }, opt: {} },
  end_turn: { req: {}, opt: {} },
  answer_choice: { req: { choice_id: (v) => isStr(v, 64) }, opt: { selection: (v) => isStr(v) } },
  concede: { req: {}, opt: {} },
  mulligan: { req: { card_uids: (v) => Array.isArray(v) && v.length <= 10 && v.every((x) => isStr(x, 64)) }, opt: {} },
};

/** Copies a command into a fresh object with only its allowed, valid fields. */
function sanitizeCommand(cmd) {
  if (!isObj(cmd) || typeof cmd.type !== 'string') return { ok: false, reason: 'bad_command' };
  const spec = COMMANDS[cmd.type];
  if (!spec) return { ok: false, reason: 'bad_command' };
  const out = { type: cmd.type };
  for (const [k, check] of Object.entries(spec.req)) {
    if (!check(cmd[k])) return { ok: false, reason: 'bad_command' };
    out[k] = cmd[k];
  }
  for (const [k, check] of Object.entries(spec.opt)) {
    if (cmd[k] === undefined) continue;
    if (!check(cmd[k])) return { ok: false, reason: 'bad_command' };
    out[k] = cmd[k];
  }
  return { ok: true, cmd: out };
}

/**
 * Validates one client message. Returns { ok: true, msg } with a sanitized
 * copy, or { ok: false, reason }. Reasons are for the audit log; clients only
 * ever see the generic public reasons below.
 */
function validateClientMessage(raw) {
  if (!isObj(raw) || typeof raw.type !== 'string') return { ok: false, reason: 'bad_frame' };
  if (!isStr(raw.match_id, 64) || !MATCH_ID.test(raw.match_id)) return { ok: false, reason: 'bad_match_id' };
  const base = { type: raw.type, match_id: raw.match_id };
  switch (raw.type) {
    case 'match_join':
      if (raw.since_n !== undefined && !isInt(raw.since_n, 0)) return { ok: false, reason: 'bad_frame' };
      return { ok: true, msg: { ...base, since_n: raw.since_n ?? 0 } };
    case 'match_command': {
      if (!isInt(raw.client_seq, 1)) return { ok: false, reason: 'bad_frame' };
      const c = sanitizeCommand(raw.cmd);
      if (!c.ok) return c;
      return { ok: true, msg: { ...base, client_seq: raw.client_seq, cmd: c.cmd } };
    }
    case 'match_mulligan': {
      if (!isInt(raw.client_seq, 1)) return { ok: false, reason: 'bad_frame' };
      const c = sanitizeCommand({ type: 'mulligan', card_uids: raw.card_uids });
      if (!c.ok) return c;
      return { ok: true, msg: { ...base, client_seq: raw.client_seq, cmd: c.cmd } };
    }
    case 'match_concede':
      return { ok: true, msg: base };
    case 'match_ping':
      return { ok: true, msg: base };
    default:
      return { ok: false, reason: 'bad_frame' };
  }
}

// What a client is told when something is refused: deliberately coarse, so a
// probe learns nothing about other players' matches or the state of the rules.
const PUBLIC_REASONS = new Set(['illegal', 'stale', 'duplicate', 'rate_limited', 'unknown_match', 'not_a_participant', 'invalid']);

function publicReason(internal) {
  switch (internal) {
    case 'stale_seq': case 'stale': return 'stale';
    case 'duplicate': return 'duplicate';
    case 'rate_limited': return 'rate_limited';
    case 'unknown_match': case 'not_a_participant': return 'unknown_match';
    case 'bad_frame': case 'bad_command': case 'bad_match_id': return 'invalid';
    default: return 'illegal';
  }
}

/** Token bucket: ACTIONS_PER_SECOND sustained, with a burst of the same size. */
class RateLimiter {
  constructor(perSecond = ACTIONS_PER_SECOND, now = Date.now) {
    this.perSecond = perSecond;
    this.tokens = perSecond;
    this.last = now();
    this.now = now;
  }
  take() {
    const t = this.now();
    this.tokens = Math.min(this.perSecond, this.tokens + ((t - this.last) / 1000) * this.perSecond);
    this.last = t;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }
}

module.exports = { MAX_FRAME_BYTES, ACTIONS_PER_SECOND, COMMANDS, sanitizeCommand, validateClientMessage, publicReason, PUBLIC_REASONS, RateLimiter };
