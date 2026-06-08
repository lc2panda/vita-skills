-- Input: D1 数据库实例（已执行 001_init.sql）
-- Output: daily_stats 物化统计表 + 排行榜/查询性能索引
-- Pos: 第二阶段数据库迁移，支持物化统计与排序优化

-- ============================================================
-- 表: daily_stats — 每日统计物化表
-- ============================================================
-- 由 Cron Worker (src/cron/daily-stats.ts) 每日凌晨聚合写入
-- 用于排行榜概要快速查询，避免每次实时全表聚合
CREATE TABLE IF NOT EXISTS daily_stats (
    date            TEXT PRIMARY KEY,               -- 'YYYY-MM-DD'
    total_checkins  INTEGER NOT NULL DEFAULT 0,     -- 当日总打卡次数
    active_users    INTEGER NOT NULL DEFAULT 0,     -- 当日活跃用户数
    avg_sets        REAL NOT NULL DEFAULT 0.0,      -- 人均完成组数
    top_user_id     TEXT,                           -- 当日最高分用户 ID
    top_score       INTEGER NOT NULL DEFAULT 0,     -- 当日最高分
    generated_at    INTEGER NOT NULL DEFAULT (unixepoch())
);

-- ============================================================
-- 索引: 排行榜查询优化
-- ============================================================

-- 用户表按积分降序索引（排行榜 alltime 排序核心）
CREATE INDEX IF NOT EXISTS idx_users_score_desc ON users(score DESC);

-- 打卡表日期降序索引（weekly/monthly 日期过滤 + 排序优化）
CREATE INDEX IF NOT EXISTS idx_checkins_date_desc ON checkins(date DESC);
