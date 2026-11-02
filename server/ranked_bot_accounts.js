'use strict';
const crypto = require('node:crypto');
const { profiles } = require('./bot_matches');

function reservedBotName(name) {
  return typeof name === 'string' && profiles.some(p => p.name.toLowerCase() === name.toLowerCase());
}

// Administrative worker entry only. Never adopt a pre-existing human account.
async function provisionRankedBots(pool) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const accounts = [];
    for (const profile of profiles) {
      const found = await client.query(`SELECT p.id,b.bot_id FROM players p
        LEFT JOIN ranked_bot_accounts b ON b.player_id=p.id
        WHERE lower(p.username)=lower($1) FOR UPDATE OF p`, [profile.name]);
      if (found.rows.length > 1 || found.rows[0] && found.rows[0].bot_id !== profile.id) throw new Error(`Bot name is already owned: ${profile.name}`);
      let id = found.rows[0]?.id;
      if (!id) {
        const added = await client.query(`INSERT INTO players (username,password_hash,salt) VALUES ($1,$2,$3) RETURNING id`,
          [profile.name, crypto.randomBytes(64).toString('hex'), crypto.randomBytes(16).toString('hex')]);
        id = added.rows[0].id;
      }
      const linked = await client.query(`INSERT INTO ranked_bot_accounts (bot_id,player_id,profile) VALUES ($1,$2,$3)
        ON CONFLICT (bot_id) DO UPDATE SET profile=EXCLUDED.profile
        WHERE ranked_bot_accounts.player_id=EXCLUDED.player_id`, [profile.id, id, profile]);
      if (linked.rowCount !== 1) throw new Error(`Bot identity is already linked: ${profile.id}`);
      const token = crypto.randomBytes(32).toString('hex');
      await client.query('INSERT INTO sessions (token,player_id) VALUES ($1,$2)', [token, id]);
      accounts.push({ id: profile.id, token });
    }
    await client.query('COMMIT');
    return accounts;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally { client.release(); }
}
module.exports = { reservedBotName, provisionRankedBots };
