-- 0008_fix_duel_answers_timeout_fk.sql
PRAGMA foreign_keys=OFF;

-- Recrée duel_answers sans FK sur team_id + team_id nullable
CREATE TABLE duel_answers_new (
  duel_id     TEXT    NOT NULL,
  round_no    INTEGER NOT NULL,
  player_id   TEXT    NOT NULL,
  team_id     TEXT    NULL,
  is_correct  INTEGER NOT NULL,
  answered_at INTEGER NOT NULL,
  PRIMARY KEY (duel_id, round_no, player_id),
  FOREIGN KEY (duel_id)   REFERENCES duels(id)   ON DELETE CASCADE,
  FOREIGN KEY (player_id) REFERENCES players(id) ON DELETE CASCADE
);

INSERT INTO duel_answers_new (duel_id, round_no, player_id, team_id, is_correct, answered_at)
SELECT duel_id, round_no, player_id, team_id, is_correct, answered_at
FROM duel_answers;

DROP TABLE duel_answers;
ALTER TABLE duel_answers_new RENAME TO duel_answers;

-- (Optionnel mais souvent utile)
CREATE INDEX IF NOT EXISTS idx_duel_answers_duel_round ON duel_answers(duel_id, round_no);

PRAGMA foreign_keys=ON;
