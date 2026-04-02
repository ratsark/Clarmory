-- Clarmory D1 Schema

-- Skills: indexed metadata from upstream sources
CREATE TABLE IF NOT EXISTS skills (
  id TEXT PRIMARY KEY,              -- unique skill identifier (source:name)
  source TEXT NOT NULL,             -- upstream registry (github, awesome-claude-code, mcp-registry, etc.)
  name TEXT NOT NULL,               -- human-readable name
  description TEXT NOT NULL,        -- what the skill does
  version_hash TEXT,                -- content hash for version identity
  source_url TEXT NOT NULL,         -- where to fetch the skill from
  install_type TEXT NOT NULL DEFAULT 'skill',  -- skill | mcp-local | mcp-hosted
  content TEXT,                      -- optional inline skill content (for self-contained skills without upstream)
  metadata TEXT DEFAULT '{}',       -- JSON blob for source-specific extras
  indexed_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_skills_source ON skills(source);
CREATE INDEX IF NOT EXISTS idx_skills_install_type ON skills(install_type);

-- Full-text search over skill name + description
CREATE VIRTUAL TABLE IF NOT EXISTS skills_fts USING fts5(
  name,
  description,
  content=skills,
  content_rowid=rowid
);

-- Keep FTS in sync with skills table
CREATE TRIGGER IF NOT EXISTS skills_ai AFTER INSERT ON skills BEGIN
  INSERT INTO skills_fts(rowid, name, description)
  VALUES (new.rowid, new.name, new.description);
END;

CREATE TRIGGER IF NOT EXISTS skills_ad AFTER DELETE ON skills BEGIN
  INSERT INTO skills_fts(skills_fts, rowid, name, description)
  VALUES ('delete', old.rowid, old.name, old.description);
END;

CREATE TRIGGER IF NOT EXISTS skills_au AFTER UPDATE ON skills BEGIN
  INSERT INTO skills_fts(skills_fts, rowid, name, description)
  VALUES ('delete', old.rowid, old.name, old.description);
  INSERT INTO skills_fts(rowid, name, description)
  VALUES (new.rowid, new.name, new.description);
END;

-- Reviews: multi-stage evaluations from agents
CREATE TABLE IF NOT EXISTS reviews (
  review_key TEXT PRIMARY KEY,       -- unique key returned to agent on creation
  agent_id TEXT NOT NULL,            -- identifier for the reviewing agent
  skill_id TEXT NOT NULL,            -- FK to skills.id
  version_hash TEXT,                 -- skill version at time of review
  stages TEXT NOT NULL DEFAULT '[]', -- JSON array of stage objects
  rating INTEGER,                    -- overall rating (1-5), may be null until post-use
  security_flag INTEGER NOT NULL DEFAULT 0,  -- 1 if security issue flagged
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (skill_id) REFERENCES skills(id)
);

CREATE INDEX IF NOT EXISTS idx_reviews_skill_id ON reviews(skill_id);
CREATE INDEX IF NOT EXISTS idx_reviews_agent_id ON reviews(agent_id);
CREATE INDEX IF NOT EXISTS idx_reviews_security ON reviews(security_flag) WHERE security_flag = 1;

-- Review stats: aggregated view per skill+version
CREATE VIEW IF NOT EXISTS review_stats AS
SELECT
  skill_id,
  version_hash,
  COUNT(*) AS review_count,
  COUNT(rating) AS rated_count,
  ROUND(AVG(rating), 2) AS avg_rating,
  SUM(CASE WHEN security_flag = 1 THEN 1 ELSE 0 END) AS security_flags,
  SUM(CASE WHEN json_array_length(stages) > 0
    AND json_extract(stages, '$[0].type') = 'code_review' THEN 1 ELSE 0 END) AS code_reviews,
  SUM(CASE WHEN EXISTS (
    SELECT 1 FROM json_each(stages) AS s
    WHERE json_extract(s.value, '$.type') = 'user_decision'
      AND (json_extract(s.value, '$.decision') = 'declined'
           OR json_extract(s.value, '$.installed') = 0)
  ) THEN 1 ELSE 0 END) AS decline_count,
  SUM(CASE WHEN EXISTS (
    SELECT 1 FROM json_each(stages) AS s
    WHERE json_extract(s.value, '$.type') = 'post_use'
  ) THEN 1 ELSE 0 END) AS post_use_reviews
FROM reviews
GROUP BY skill_id, version_hash;
