--
-- Input:  D1 数据库种子数据（wrangler d1 execute）
-- Output: Cloudflare D1 (SQLite) 预置数据 — 成就定义与统计基线
-- Pos:   leaderboard/db/seed.sql — 种子数据，Phase 3 打榜系统初始化
--
-- 香草健康管理 打榜 PK 系统 — D1 种子数据
-- 更新时间: 2026-06-08 18:00:00 +08:00 (Asia/Singapore)

-- ============================================
-- 系统占位用户（成就徽章定义需要外键引用）
-- ============================================
INSERT OR IGNORE INTO users (id, display_name, device_id)
VALUES ('system', 'System', 'system');

-- ============================================
-- 预置成就徽章定义
-- ============================================
-- 徽章类型与 src/types.ts BADGE_DEFINITIONS 完全对齐
-- 后续由 Worker 根据用户行为动态授予
-- system 用户的 badges 已移除（避免污染成就查询 /api/achievements/:user_id）
-- 徽章应由 Worker 在真实用户达成条件时动态授予
-- ============================================

-- ============================================
-- 每日统计基线记录
-- ============================================
INSERT OR IGNORE INTO daily_stats (date, total_checkins, active_users, avg_sets, top_user_id, top_score)
VALUES ('1970-01-01', 0, 0, 0.0, 'system', 0);
