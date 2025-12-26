PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS duels (
  id TEXT PRIMARY KEY,
  code TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL,          -- lobby | active | finished
  total INTEGER NOT NULL,
  current_round INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  started_at INTEGER,
  finished_at INTEGER
);

CREATE TABLE IF NOT EXISTS duel_players (
  duel_id TEXT NOT NULL,
  player_id TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  side INTEGER NOT NULL,         -- 1 or 2
  PRIMARY KEY (duel_id, player_id),
  FOREIGN KEY(duel_id) REFERENCES duels(id),
  FOREIGN KEY(player_id) REFERENCES players(id)
);

CREATE TABLE IF NOT EXISTS duel_rounds (
  duel_id TEXT NOT NULL,
  round_no INTEGER NOT NULL,
  rider_id TEXT NOT NULL,
  correct_team_id TEXT NOT NULL,
  PRIMARY KEY (duel_id, round_no),
  FOREIGN KEY(duel_id) REFERENCES duels(id),
  FOREIGN KEY(rider_id) REFERENCES riders(id),
  FOREIGN KEY(correct_team_id) REFERENCES teams(id)
);

CREATE TABLE IF NOT EXISTS duel_answers (
  duel_id TEXT NOT NULL,
  round_no INTEGER NOT NULL,
  player_id TEXT NOT NULL,
  team_id TEXT NOT NULL,
  is_correct INTEGER NOT NULL,
  answered_at INTEGER NOT NULL,
  PRIMARY KEY (duel_id, round_no, player_id),
  FOREIGN KEY(duel_id) REFERENCES duels(id),
  FOREIGN KEY(player_id) REFERENCES players(id),
  FOREIGN KEY(team_id) REFERENCES teams(id)
);

CREATE INDEX IF NOT EXISTS idx_duels_code ON duels(code);
CREATE INDEX IF NOT EXISTS idx_dp_duel ON duel_players(duel_id);
CREATE INDEX IF NOT EXISTS idx_da_duel_player ON duel_answers(duel_id, player_id);
