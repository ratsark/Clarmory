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
  tags TEXT DEFAULT '',             -- space-separated tags for FTS (extracted from metadata)
  install_instructions TEXT,        -- how to install (e.g. "npm install", "pip install", config steps)
  dependencies TEXT,                -- what it requires (e.g. "node 18+, npm" or "python 3.10+, pip")
  metadata TEXT DEFAULT '{}',       -- JSON blob for source-specific extras
  enriched_at TEXT,                 -- when metadata was last enriched from source
  indexed_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_skills_source ON skills(source);
CREATE INDEX IF NOT EXISTS idx_skills_install_type ON skills(install_type);

-- Full-text search over skill name + description + tags
-- Porter stemming enables matching across word forms (e.g. "planning" matches "plan")
CREATE VIRTUAL TABLE IF NOT EXISTS skills_fts USING fts5(
  name,
  description,
  tags,
  content=skills,
  content_rowid=rowid,
  tokenize='porter unicode61'
);

-- Keep FTS in sync with skills table
CREATE TRIGGER IF NOT EXISTS skills_ai AFTER INSERT ON skills BEGIN
  INSERT INTO skills_fts(rowid, name, description, tags)
  VALUES (new.rowid, new.name, new.description, new.tags);
END;

CREATE TRIGGER IF NOT EXISTS skills_ad AFTER DELETE ON skills BEGIN
  INSERT INTO skills_fts(skills_fts, rowid, name, description, tags)
  VALUES ('delete', old.rowid, old.name, old.description, old.tags);
END;

CREATE TRIGGER IF NOT EXISTS skills_au AFTER UPDATE ON skills BEGIN
  INSERT INTO skills_fts(skills_fts, rowid, name, description, tags)
  VALUES ('delete', old.rowid, old.name, old.description, old.tags);
  INSERT INTO skills_fts(rowid, name, description, tags)
  VALUES (new.rowid, new.name, new.description, new.tags);
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
  trust_level TEXT NOT NULL DEFAULT 'anonymous',  -- 'anonymous' | 'pseudonymous' | 'github_verified'
  public_key TEXT,                    -- reviewer's Ed25519 public key (FK to identities), null for anonymous
  model TEXT,                          -- model/agent that wrote the review (e.g. 'claude-opus-4-6')
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (skill_id) REFERENCES skills(id)
);

CREATE INDEX IF NOT EXISTS idx_reviews_skill_id ON reviews(skill_id);
CREATE INDEX IF NOT EXISTS idx_reviews_agent_id ON reviews(agent_id);
CREATE INDEX IF NOT EXISTS idx_reviews_security ON reviews(security_flag) WHERE security_flag = 1;

-- Identities: reviewer identities (keypair-based, optionally GitHub-verified)
CREATE TABLE IF NOT EXISTS identities (
  public_key TEXT PRIMARY KEY,        -- base64-encoded Ed25519 public key
  github_username TEXT,               -- GitHub username (null if anonymous)
  trust_level TEXT NOT NULL DEFAULT 'pseudonymous',  -- 'pseudonymous' | 'github_verified'
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  ip_address TEXT                     -- IP of first review submission
);

CREATE INDEX IF NOT EXISTS idx_identities_github ON identities(github_username)
  WHERE github_username IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_identities_trust ON identities(trust_level);

-- Rate limits: IP-based counters for review submission
CREATE TABLE IF NOT EXISTS rate_limits (
  ip TEXT NOT NULL,
  action TEXT NOT NULL,               -- 'review' or 'github_auth'
  window TEXT NOT NULL,               -- hour or day bucket, e.g. '2026-04-02T14'
  count INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (ip, action, window)
);

-- Review stats: aggregated view per skill+version with dual scoring
CREATE VIEW IF NOT EXISTS review_stats AS
SELECT
  skill_id,
  version_hash,
  COUNT(*) AS review_count,
  COUNT(rating) AS rated_count,
  ROUND(AVG(rating), 2) AS avg_rating,
  -- Verified-only scoring
  SUM(CASE WHEN trust_level = 'github_verified' THEN 1 ELSE 0 END) AS verified_count,
  SUM(CASE WHEN trust_level = 'github_verified' AND rating IS NOT NULL THEN 1 ELSE 0 END) AS verified_rated_count,
  ROUND(AVG(CASE WHEN trust_level = 'github_verified' THEN rating ELSE NULL END), 2) AS verified_avg_rating,
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
