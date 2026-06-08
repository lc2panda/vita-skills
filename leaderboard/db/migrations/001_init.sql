-- Input: D1 数据库空实例
-- Output: users / checkins / badges 三表 + 索引
-- Pos: 数据库 schema 定义，所有 API 的数据持久层基础

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    device_id TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    opt_in_leaderboard BOOLEAN NOT NULL DEFAULT 1,
    stage TEXT NOT NULL DEFAULT 'beginner',
    score INTEGER NOT NULL DEFAULT 0,
    streak INTEGER NOT NULL DEFAULT 0,
    best_streak INTEGER NOT NULL DEFAULT 0,
    level TEXT NOT NULL DEFAULT 'bronze'
);

CREATE TABLE IF NOT EXISTS checkins (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    date TEXT NOT NULL,
    sets_completed INTEGER NOT NULL DEFAULT 0,
    reps_per_set INTEGER NOT NULL DEFAULT 10,
    hold_seconds INTEGER NOT NULL DEFAULT 3,
    checkin_count INTEGER NOT NULL DEFAULT 1,
    first_checkin_at INTEGER NOT NULL,
    last_checkin_at INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS badges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    badge_type TEXT NOT NULL,
    awarded_at INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (user_id) REFERENCES users(id),
    UNIQUE(user_id, badge_type)
);

CREATE INDEX IF NOT EXISTS idx_checkins_user_date ON checkins(user_id, date);
CREATE INDEX IF NOT EXISTS idx_checkins_date ON checkins(date);
CREATE INDEX IF NOT EXISTS idx_badges_user ON badges(user_id);
