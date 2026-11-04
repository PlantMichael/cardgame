'use strict';
const { profiles } = require('./bot_matches');
const HISTORY = ['ranked_match_actions', 'ranked_match_audit', 'ranked_matches', 'ranked_settlements', 'bot_matches'];
const RESET_FIELDS = ['rating', 'rank_bracket', 'rank_in_legend', 'rank_legend_rating', 'rank_lp', 'ranked_win_streak', 'ranked_wins', 'ranked_losses'];
async function counts(client) {
  const result = {};
  for (const table of HISTORY) result[table] = Number((await client.query(`SELECT count(*) AS n FROM ${table}`)).rows[0].n);
  return result;
}
// Digests stay inside this operation; no player, deck, credential or session data
// is returned. Compare every preserved field, including all human account fields.
async function preserved(client) {
  const values = [];
  for (const table of ['players', 'decks', 'owned_cards', 'sessions', 'ranked_bot_accounts']) {
    const expression = table === 'players'
      ? `to_jsonb(t) - CASE WHEN EXISTS (SELECT 1 FROM ranked_bot_accounts b WHERE b.player_id=t.id)
         THEN $1::text[] ELSE '{}'::text[] END` : 'to_jsonb(t)';
    const result = await client.query(`SELECT md5(COALESCE(string_agg(row::text, '' ORDER BY row::text), '')) AS hash
      FROM (SELECT ${expression} AS row FROM ${table} t) protected`, table === 'players' ? [RESET_FIELDS] : []);
    values.push(result.rows[0].hash);
  }
  return JSON.stringify(values);
}
async function resetMatchData(pool, { apply = false } = {}) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    if (apply) {
      const locks = await client.query(`SELECT pg_try_advisory_xact_lock(731204,1) AS simulation,
        pg_try_advisory_xact_lock(731204,2) AS ranked`);
      if (!locks.rows[0].simulation || !locks.rows[0].ranked) throw new Error('Stop all bot workers before resetting history');
      await client.query(`LOCK TABLE ${[...HISTORY, 'players', 'decks', 'owned_cards', 'sessions', 'ranked_bot_accounts', 'ranked_result_tombstones'].join(',')} IN ACCESS EXCLUSIVE MODE`);
    }
    const before = await counts(client);
    if (!apply) { await client.query('ROLLBACK'); return { applied: false, before }; }
    const bots = (await client.query(`SELECT b.bot_id,p.username FROM ranked_bot_accounts b JOIN players p ON p.id=b.player_id`)).rows;
    if (bots.length !== profiles.length || !profiles.every(p => bots.some(b => b.bot_id === p.id && b.username === p.name))) throw new Error('Expected the exact trusted bot roster');
    const unchanged = await preserved(client);
    const tombstones = await client.query(`INSERT INTO ranked_result_tombstones (match_id,player_id)
      SELECT match_id,player_id FROM ranked_settlements ON CONFLICT DO NOTHING`);
    // Delete only named history tables. Do not use CASCADE to discover new scope.
    for (const table of HISTORY) await client.query(`DELETE FROM ${table}`);
    const reset = await client.query(`UPDATE players SET rating=1000,rank_bracket=0,rank_in_legend=false,
      rank_legend_rating=0,rank_lp=0,ranked_win_streak=0,ranked_wins=0,ranked_losses=0
      WHERE id IN (SELECT player_id FROM ranked_bot_accounts)`);
    const after = await counts(client);
    if (reset.rowCount !== profiles.length || Object.values(after).some(n => n !== 0) || unchanged !== await preserved(client)) throw new Error('Reset preservation check failed');
    await client.query('COMMIT');
    return { applied: true, before, after, botsReset: reset.rowCount, replayKeysRetained: tombstones.rowCount, preserved: true };
  } catch (error) { await client.query('ROLLBACK'); throw error; }
  finally { client.release(); }
}

if (require.main === module) {
  const { Pool } = require('pg');
  const args = process.argv.slice(2);
  if (!process.env.DATABASE_URL || args.some(a => !['--apply', '--services-stopped'].includes(a)) ||
      args.includes('--apply') && !args.includes('--services-stopped')) {
    console.error('Usage: node reset_match_data.js [--apply --services-stopped]; DATABASE_URL required. Stop relay and every history writer before applying.');
    process.exitCode = 1;
  } else {
    let url;
    try { url = new URL(process.env.DATABASE_URL); }
    catch { console.error('Invalid URL'); process.exitCode = 1; }
    if (url) {
      const pool = new Pool({ connectionString: url.href, connectionTimeoutMillis: 10000, query_timeout: 30000,
        ssl: ['localhost','127.0.0.1','[::1]'].includes(url.hostname) || url.hostname.endsWith('.railway.internal') ? false : { rejectUnauthorized: false } });
      resetMatchData(pool, { apply: args.includes('--apply') }).then(result => console.log(JSON.stringify(result)))
        .catch(error => { console.error(error.message); process.exitCode = 1; }).finally(() => pool.end());
    }
  }
}
module.exports = { resetMatchData };
