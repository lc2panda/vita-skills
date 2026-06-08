--
-- Input:  D1 数据库种子数据（wrangler d1 execute）
-- Output: Cloudflare D1 (SQLite) 预置数据 — 成就定义与统计基线
-- Pos:   leaderboard/db/seed.sql — 种子数据，Phase 3 打榜系统初始化
--
-- 香草健康管理 打榜 PK 系统 — D1 种子数据
-- 创建时间: 2026-06-08 16:00:00 +08:00 (Asia/Singapore)

-- ============================================
-- 预置成就徽章定义
-- ============================================
-- 系统级成就占位，后续由 Worker 根据用户行为动态授予
-- badge_type 枚举: streak_3, streak_7, streak_30, early_bird, night_owl,
--                  power_user, pk_winner, first_checkin, record_breaker
INSERT OR IGNORE INTO achievements (user_id, badge_type, awarded_at)
VALUES ('system', 'first_checkin', unixepoch());

INSERT OR IGNORE INTO achievements (user_id, badge_type, awarded_at)
VALUES ('system', 'streak_3', unixepoch());

INSERT OR IGNORE INTO achievements (user_id, badge_type, awarded_at)
VALUES ('system', 'streak_7', unixepoch());

INSERT OR IGNORE INTO achievements (user_id, badge_type, awarded_at)
VALUES ('system', 'streak_30', unixepoch());

INSERT OR IGNORE INTO achievements (user_id, badge_type, awarded_at)
VALUES ('system', 'early_bird', unixepoch());

INSERT OR IGNORE INTO achievements (user_id, badge_type, awarded_at)
VALUES ('system', 'night_owl', unixepoch());

INSERT OR IGNORE INTO achievements (user_id, badge_type, awarded_at)
VALUES ('system', 'power_user', unixepoch());

INSERT OR IGNORE INTO achievements (user_id, badge_type, awarded_at)
VALUES ('system', 'pk_winner', unixepoch());

INSERT OR IGNORE INTO achievements (user_id, badge_type, awarded_at)
VALUES ('system', 'record_breaker', unixepoch());

-- ============================================
-- 每日统计基线记录
-- ============================================
-- 哨兵记录，确保 daily_stats 不为空，供定时 Worker 聚合时作为基线
INSERT OR IGNORE INTO daily_stats (date, total_checkins, active_users, avg_sets, top_user_id, top_score)
VALUES ('1970-01-01', 0, 0, 0.0, 'system', 0);
