-- 0007_duel_round_timer.sql
ALTER TABLE duels ADD COLUMN round_started_at INTEGER;
ALTER TABLE duels ADD COLUMN round_ends_at INTEGER;
ALTER TABLE duels ADD COLUMN round_duration_ms INTEGER DEFAULT 15000;
