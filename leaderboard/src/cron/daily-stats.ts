// Input: Cron trigger (scheduled event) — 每天凌晨 1:00 UTC
// Output: daily_stats 表物化前一天数据 + 清理 30 天前过期统计
// Pos: Cron Worker 聚合统计入口，由 wrangler.toml triggers.crons 驱动

import type { Bindings } from '../env';

/**
 * 计算 N 天前的日期字符串（Asia/Shanghai 时区）
 */
function daysAgoStr(n: number): string {
  // +8 小时偏移对齐 Asia/Shanghai 时区
  const d = new Date(Date.now() + 8 * 3600_000 - n * 86400_000);
  return d.toISOString().slice(0, 10);
}

/**
 * Cron 触发入口：聚合前一天数据 → daily_stats，清理过期统计
 */
export async function handleScheduled(
  _controller: ScheduledController,
  env: Bindings,
  _ctx: ExecutionContext,
): Promise<void> {
  const db = env.DB;
  const yesterday = daysAgoStr(1);

  // 1. 聚合前一天打卡统计数据
  const stats = await db.prepare(`
    SELECT
      COUNT(*) AS total_checkins,
      COUNT(DISTINCT user_id) AS active_users,
      AVG(CAST(sets_completed AS REAL)) AS avg_sets
    FROM checkins
    WHERE date = ?
  `).bind(yesterday).first<{ total_checkins: number; active_users: number; avg_sets: number }>();

  // 2. 前一天得分最高用户（按总组数排名）
  const topUser = await db.prepare(`
    SELECT user_id, SUM(sets_completed) AS total
    FROM checkins
    WHERE date = ?
    GROUP BY user_id
    ORDER BY total DESC
    LIMIT 1
  `).bind(yesterday).first<{ user_id: string; total: number }>();

  // 3. 写入 daily_stats（使用 INSERT OR REPLACE 幂等处理重复触发）
  await db.prepare(`
    INSERT OR REPLACE INTO daily_stats
      (date, total_checkins, active_users, avg_sets, top_user_id, top_score, generated_at)
    VALUES (?, ?, ?, ?, ?, ?, unixepoch())
  `).bind(
    yesterday,
    stats?.total_checkins ?? 0,
    stats?.active_users ?? 0,
    stats?.avg_sets ?? 0,
    topUser?.user_id ?? null,
    topUser?.total ?? 0,
  ).run();

  // 4. 清理 30 天前的 daily_stats 记录（控制表大小）
  const thirtyDaysAgo = daysAgoStr(30);
  await db.prepare(
    'DELETE FROM daily_stats WHERE date < ?',
  ).bind(thirtyDaysAgo).run();

  // 注：当前 checkins 表未持久化 IP 数据（IP 频率限制仅在内存中运行）。
  // 若未来 schema 新增 client_ip_hash 字段，此处追加 IP 日志清理：
  //   await db.prepare("UPDATE checkins SET client_ip_hash = '' WHERE date < ? AND client_ip_hash != ''")
  //     .bind(thirtyDaysAgo).run();
}
