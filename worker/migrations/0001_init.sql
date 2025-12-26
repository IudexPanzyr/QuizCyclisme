PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS categories (
  id TEXT PRIMARY KEY,
  code TEXT NOT NULL UNIQUE,     -- WT / PT / WWT ...
  name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS teams (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  category_id TEXT NOT NULL,
  jersey_url TEXT,              -- future: URL du maillot/logo
  FOREIGN KEY(category_id) REFERENCES categories(id)
);

CREATE INDEX IF NOT EXISTS idx_teams_cat ON teams(category_id);

CREATE TABLE IF NOT EXISTS riders (
  id TEXT PRIMARY KEY,
  full_name TEXT NOT NULL,
  nation TEXT
);

CREATE INDEX IF NOT EXISTS idx_riders_name ON riders(full_name);

-- Affectation "actuelle" (1 ligne par coureur)
CREATE TABLE IF NOT EXISTS rider_team_current (
  rider_id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL,
  FOREIGN KEY(rider_id) REFERENCES riders(id),
  FOREIGN KEY(team_id) REFERENCES teams(id)
);

CREATE INDEX IF NOT EXISTS idx_rtc_team ON rider_team_current(team_id);
