CREATE TABLE IF NOT EXISTS duel_results (
  duel_id TEXT PRIMARY KEY,
  winner_player_id TEXT NULL,
  p1_score INTEGER NOT NULL,
  p2_score INTEGER NOT NULL,
  total INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
