-- Paste into Railway: Postgres -> Database -> Data -> Query.
-- Both starting decks count; duplicate copies count once per seat per game.
-- Requires ranked_matches (the authoritative schema). The API also works without it.
-- This raw DB view includes all recorded IDs; the API filters published collectibles.
WITH player_games AS (
  SELECT s.match_id, s.player_id, seat.side, seat.won, seat.deck
  FROM ranked_settlements s
  CROSS JOIN LATERAL (VALUES
    ('player', s.won, s.ai_match->'player_deck'),
    ('opponent', NOT s.won, s.ai_match->'opponent_deck')
  ) AS seat(side, won, deck)
  WHERE s.ai_match->>'mode' = 'ranked_ai'
    AND s.ai_match->>'source' = 'client_reported'

  UNION ALL

  SELECT s.match_id, s.player_id, 'player' AS side, s.won,
    CASE WHEN s.player_id = m.seat_a_player_id THEN m.deck_a
         WHEN s.player_id = m.seat_b_player_id THEN m.deck_b END AS deck
  FROM ranked_settlements s
  JOIN ranked_matches m USING (match_id)
  WHERE s.ai_match IS NULL
    AND m.mode = 'authoritative' AND m.status = 'finished'
    AND m.winner_seat IN ('a', 'b')
    AND m.end_reason IN ('completed', 'conceded', 'forfeit_disconnect', 'forfeit_timeout')
), card_games AS (
  SELECT DISTINCT match_id, player_id, side, won, card_id
  FROM player_games
  CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(deck) = 'array' THEN deck ELSE '[]'::jsonb END
  ) AS cards(card_id)
)
SELECT card_id, COUNT(*) AS games,
  COUNT(*) FILTER (WHERE won) AS wins,
  COUNT(*) FILTER (WHERE NOT won) AS losses,
  ROUND(100.0 * SUM(won::int) / COUNT(*), 2) AS win_rate_percent
FROM card_games
GROUP BY card_id
ORDER BY games DESC, card_id;
