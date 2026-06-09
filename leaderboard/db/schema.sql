--
-- Input:  D1 数据库迁移（wrangler d1 execute）
-- Output: Cloudflare D1 (SQLite) 数据库 schema — 4 张核心表
-- Pos:   leaderboard/db/schema.sql — 打榜系统数据库定义，与迁移文件保持同步
--
-- 香草健康管理 打榜 PK 系统 — D1 (SQLite) Schema 文档
-- 权威来源: db/migrations/001_init.sql + db/migrations/002_indexes.sql
-- 更新时间: 2026-06-08 18:00:00 +08:00 (Asia/Singapore)

-- ============================================================
-- 表 1: users — 用户表
-- 权威定义: 001_init.sql
-- ============================================================
CREATE TABLE IF NOT EXISTS users (
    id                  TEXT PRIMARY KEY,
    display_name        TEXT NOT NULL,
    device_id           TEXT NOT NULL,
    token               TEXT,
    privacy_mode        INTEGER DEFAULT 0,       -- 0=公开 1=匿名
    loyalty_score       INTEGER DEFAULT 0,       -- 忠诚度积分
    loyalty_tier        TEXT DEFAULT 'F',         -- SS/S/A/B/C/D/E/F 八级
    created_at          INTEGER NOT NULL DEFAULT (unixepoch()),
    opt_in_leaderboard  BOOLEAN NOT NULL DEFAULT 1,
    stage               TEXT NOT NULL DEFAULT 'beginner',
    score               INTEGER NOT NULL DEFAULT 0,
    streak              INTEGER NOT NULL DEFAULT 0,
    best_streak         INTEGER NOT NULL DEFAULT 0,
    level               TEXT NOT NULL DEFAULT 'bronze'
);

-- ============================================================
-- 表 2: checkins — 打卡记录表
-- 权威定义: 001_init.sql
-- ============================================================
CREATE TABLE IF NOT EXISTS checkins (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id         TEXT NOT NULL,
    date            TEXT NOT NULL,
    sets_completed  INTEGER NOT NULL DEFAULT 0,
    reps_per_set    INTEGER NOT NULL DEFAULT 10,
    hold_seconds    INTEGER NOT NULL DEFAULT 3,
    checkin_count   INTEGER NOT NULL DEFAULT 1,
    first_checkin_at INTEGER NOT NULL,
    last_checkin_at INTEGER NOT NULL,
    device_id       TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX IF NOT EXISTS idx_checkins_user_date ON checkins(user_id, date);
CREATE INDEX IF NOT EXISTS idx_checkins_date ON checkins(date);

-- ============================================================
-- 表 3: badges — 成就徽章表
-- 权威定义: 001_init.sql
-- ============================================================
CREATE TABLE IF NOT EXISTS badges (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     TEXT NOT NULL,
    badge_type  TEXT NOT NULL,
    awarded_at  INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (user_id) REFERENCES users(id),
    UNIQUE(user_id, badge_type)
);

CREATE INDEX IF NOT EXISTS idx_badges_user ON badges(user_id);

-- PK 挑战表
CREATE TABLE IF NOT EXISTS challenges (
    id TEXT PRIMARY KEY,
    challenger_id TEXT NOT NULL,
    opponent_id TEXT NOT NULL,
    status TEXT DEFAULT 'pending',  -- pending/accepted/completed/cancelled
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

-- ============================================================
-- 表 4: daily_stats — 每日统计表（物化视图替代）
-- 权威定义: 002_indexes.sql
-- ============================================================
CREATE TABLE IF NOT EXISTS daily_stats (
    date            TEXT PRIMARY KEY,
    total_checkins  INTEGER NOT NULL DEFAULT 0,
    active_users    INTEGER NOT NULL DEFAULT 0,
    avg_sets        REAL NOT NULL DEFAULT 0.0,
    top_user_id     TEXT,
    top_score       INTEGER NOT NULL DEFAULT 0,
    generated_at    INTEGER NOT NULL DEFAULT (unixepoch())
);

-- ============================================================
-- 索引: 排行榜查询优化
-- 权威定义: 002_indexes.sql
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_users_score_desc ON users(score DESC);
CREATE INDEX IF NOT EXISTS idx_checkins_date_desc ON checkins(date DESC);
