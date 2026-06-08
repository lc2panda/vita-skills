--
-- Input:  D1 数据库迁移（wrangler d1 execute）
-- Output: Cloudflare D1 (SQLite) 数据库 schema — 4 张核心表
-- Pos:   leaderboard/db/schema.sql — 打榜系统数据库定义，Phase 3 实施入口
--
-- 香草健康管理 打榜 PK 系统 — D1 (SQLite) 初始化 Schema
-- 基线设计文档: 香草健康管理skills设计.md §4.2
-- 创建时间: 2026-06-08 15:30:00 +08:00 (Asia/Singapore)

-- ============================================================
-- 表 1: users — 用户表
-- ============================================================
-- 用户 ID 基于设备指纹哈希生成（伪匿名），不关联真实身份
-- display_name 经 §4.9 多层校验流程后方可写入
CREATE TABLE users (
    id              TEXT PRIMARY KEY,              -- device_fingerprint SHA-256 哈希（伪匿名 ID）
    display_name    TEXT NOT NULL,                 -- 显示名称，2-20 字符，通过合规校验（§4.9）
    created_at      INTEGER NOT NULL DEFAULT (unixepoch()),
    total_score     INTEGER NOT NULL DEFAULT 0,    -- 综合得分（§4.5 排名算法）
    current_streak  INTEGER NOT NULL DEFAULT 0,    -- 当前连续打卡天数
    best_streak     INTEGER NOT NULL DEFAULT 0,    -- 历史最佳连续打卡天数
    level           TEXT NOT NULL DEFAULT 'beginner',  -- beginner / intermediate / advanced
    privacy_mode    TEXT NOT NULL DEFAULT 'public',     -- public / anonymous（§4.7 隐私保护）
    opt_in_leaderboard BOOLEAN NOT NULL DEFAULT 1,     -- 是否出现在公开排行榜（§4.7）
    loyalty_score   REAL NOT NULL DEFAULT 50.0,        -- 忠诚度评分 0-100（§5.7.2）
    loyalty_tier    TEXT NOT NULL DEFAULT 'S',          -- 忠诚度等级：SSS/SS/S/--
    updated_at      INTEGER NOT NULL DEFAULT (unixepoch())
);

-- ============================================================
-- 表 2: checkins — 打卡记录表
-- ============================================================
-- 每日最多 3 次打卡（§4.4 L2 频率限制）
-- 每次打卡间隔 >= 30 分钟（§4.4 L3 时间窗口）
-- signature 字段用于 HMAC 防伪造（§4.4 L1）
CREATE TABLE checkins (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id             TEXT NOT NULL,
    checkin_date        TEXT NOT NULL,              -- 'YYYY-MM-DD'
    sets_completed      INTEGER NOT NULL DEFAULT 0, -- 完成组数
    reps_per_set        INTEGER NOT NULL DEFAULT 10,-- 每组次数
    hold_seconds        INTEGER NOT NULL DEFAULT 3, -- 每次保持秒数
    completed_at        INTEGER NOT NULL,           -- Unix 时间戳（打卡完成时刻）
    device_id           TEXT NOT NULL DEFAULT '',   -- 设备指纹校验
    client_ip_hash      TEXT NOT NULL DEFAULT '',   -- IP 哈希用于防作弊（§4.4）
    signature           TEXT NOT NULL DEFAULT '',   -- HMAC 签名防伪造（§4.4 L1）
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- 查询优化索引
CREATE INDEX idx_checkins_user_date ON checkins(user_id, checkin_date);
CREATE INDEX idx_checkins_date ON checkins(checkin_date);
CREATE INDEX idx_checkins_completed ON checkins(completed_at);

-- ============================================================
-- 表 3: achievements — 成就徽章表
-- ============================================================
-- 徽章类型见 seed.sql 中的预定义列表（§4.6）
CREATE TABLE achievements (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     TEXT NOT NULL,
    badge_type  TEXT NOT NULL,                      -- 徽章类型标识（如 streak_7, early_bird）
    awarded_at  INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    UNIQUE(user_id, badge_type)                     -- 同一徽章每人仅获得一次
);

CREATE INDEX idx_achievements_user ON achievements(user_id);

-- ============================================================
-- 表 4: daily_stats — 每日统计表（物化视图替代）
-- ============================================================
-- 由定时 Worker 每日聚合生成，用于快速查询排行榜概要
-- date 为主键，每天一条记录
CREATE TABLE daily_stats (
    date            TEXT PRIMARY KEY,               -- 'YYYY-MM-DD'
    total_checkins  INTEGER NOT NULL DEFAULT 0,     -- 当日总打卡次数
    active_users    INTEGER NOT NULL DEFAULT 0,     -- 当日活跃用户数
    avg_sets        REAL NOT NULL DEFAULT 0.0,      -- 人均完成组数
    top_user_id     TEXT,                           -- 当日最高分用户 ID
    top_score       INTEGER NOT NULL DEFAULT 0,     -- 当日最高分
    generated_at    INTEGER NOT NULL DEFAULT (unixepoch())
);

-- ============================================================
-- 表 5: challenges — 挑战赛表（PK 对战）
-- ============================================================
-- 好友间 7 天挑战（§4.6 社交激励）
CREATE TABLE challenges (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    challenger_id       TEXT NOT NULL,
    opponent_id         TEXT NOT NULL,
    start_date          TEXT NOT NULL,              -- 'YYYY-MM-DD'
    end_date            TEXT NOT NULL,              -- 'YYYY-MM-DD'
    challenger_score    INTEGER NOT NULL DEFAULT 0,
    opponent_score      INTEGER NOT NULL DEFAULT 0,
    status              TEXT NOT NULL DEFAULT 'active',  -- active / completed / cancelled
    winner_id           TEXT,
    created_at          INTEGER NOT NULL DEFAULT (unixepoch()),
    FOREIGN KEY (challenger_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (opponent_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE INDEX idx_challenges_status ON challenges(status);
CREATE INDEX idx_challenges_users ON challenges(challenger_id, opponent_id);
