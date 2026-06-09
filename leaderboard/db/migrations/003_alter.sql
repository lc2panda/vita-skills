-- Input: D1 远程数据库 (001_init.sql 初始 schema)
-- Output: users 表补列 + challenges 表创建
-- Pos:  db/migrations/003_alter.sql — 补齐 HMAC/privacy/loyalty 所需字段

-- 补 users 缺失列（tolumn if not exists behavior via error ignore）
ALTER TABLE users ADD COLUMN token TEXT;
ALTER TABLE users ADD COLUMN privacy_mode INTEGER DEFAULT 0;
ALTER TABLE users ADD COLUMN loyalty_score INTEGER DEFAULT 0;
ALTER TABLE users ADD COLUMN loyalty_tier TEXT DEFAULT 'F';

-- challenges 表（PK 挑战）
CREATE TABLE IF NOT EXISTS challenges (
    id TEXT PRIMARY KEY,
    challenger_id TEXT NOT NULL,
    opponent_id TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    challenger_score INTEGER DEFAULT 0,
    opponent_score INTEGER DEFAULT 0,
    winner_id TEXT,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (challenger_id) REFERENCES users(id),
    FOREIGN KEY (opponent_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_challenges_challenger ON challenges(challenger_id);
CREATE INDEX IF NOT EXISTS idx_challenges_opponent ON challenges(opponent_id);
CREATE INDEX IF NOT EXISTS idx_challenges_status ON challenges(status);
