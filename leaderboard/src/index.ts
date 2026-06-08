// Input: Cloudflare Workers HTTP 请求
// Output: 7 个 REST API 端点的 JSON 响应
// Pos: Workers 主入口，路由分发 + 防作弊中间件 + 排名算法

import { Hono } from 'hono';
import { cors } from 'hono/cors';
import type { Bindings } from './env';
import type {
  CheckinRequest,
  CheckinResponse,
  RegisterRequest,
  RegisterResponse,
  LeaderboardEntry,
  LeaderboardType,
  UserDetailResponse,
  StreakResponse,
  StatsResponse,
  AchievementResponse,
  UserRecord,
  CheckinRecord,
  BadgeRecord,
} from './types';
import { BADGE_DEFINITIONS, computeLevel, computeCheckinScore } from './types';
import { handleScheduled } from './cron/daily-stats';

// ============================================================
// 应用初始化
// ============================================================

const app = new Hono<{ Bindings: Bindings }>();

// CORS 全开（移动端 + Web 前端均需访问）
app.use('*', cors());

// ============================================================
// 防作弊中间件 — IP 频率限制（每 IP 每分钟最多 10 请求）
// ============================================================

interface RateLimitEntry {
  count: number;
  resetAt: number;
}

const ipRateLimitMap = new Map<string, RateLimitEntry>();
const RATE_LIMIT_MAX = 10;
const RATE_LIMIT_WINDOW_MS = 60_000;

function getClientIP(request: Request): string {
  return request.headers.get('CF-Connecting-IP')
    || request.headers.get('X-Forwarded-For')?.split(',')[0]?.trim()
    || '127.0.0.1';
}

function checkIPRateLimit(ip: string): boolean {
  const now = Date.now();
  const entry = ipRateLimitMap.get(ip);
  if (!entry || now > entry.resetAt) {
    ipRateLimitMap.set(ip, { count: 1, resetAt: now + RATE_LIMIT_WINDOW_MS });
    return true;
  }
  if (entry.count >= RATE_LIMIT_MAX) {
    return false;
  }
  entry.count++;
  return true;
}

// 定期清理过期条目（每 5 分钟清理一次）
let lastCleanup = Date.now();
function maybeCleanupRateLimitMap(): void {
  const now = Date.now();
  if (now - lastCleanup < 300_000) return;
  lastCleanup = now;
  for (const [ip, entry] of ipRateLimitMap) {
    if (now > entry.resetAt) {
      ipRateLimitMap.delete(ip);
    }
  }
}

// 全局 IP 频率限制中间件
app.use('*', async (c, next) => {
  maybeCleanupRateLimitMap();
  const ip = getClientIP(c.req.raw);
  if (!checkIPRateLimit(ip)) {
    return c.json({ error: '请求过于频繁，请稍后再试', retry_after_seconds: 60 }, 429);
  }
  await next();
});

// ============================================================
// 辅助函数
// ============================================================

function todayStr(): string {
  // 使用 Asia/Shanghai 时区（UTC+8）作为业务日边界
  const now = new Date();
  const local = new Date(now.getTime() + 8 * 3600_000);
  return local.toISOString().slice(0, 10);
}

function generateUserId(): string {
  return crypto.randomUUID();
}

function generateToken(): string {
  const buf = new Uint8Array(32);
  crypto.getRandomValues(buf);
  return Array.from(buf, b => b.toString(16).padStart(2, '0')).join('');
}

/** 昵称校验：1-20 字符，允许中日韩/拉丁/数字/下划线/连字符，禁止纯数字/纯符号 */
function validateDisplayName(name: string): { valid: boolean; reason?: string } {
  if (!name || typeof name !== 'string') {
    return { valid: false, reason: '昵称不能为空' };
  }
  const trimmed = name.trim();
  if (trimmed.length === 0 || trimmed.length > 20) {
    return { valid: false, reason: '昵称长度需在 1-20 个字符之间' };
  }
  // 允许：中文、日文、韩文、拉丁字母、数字、下划线、连字符
  const allowed = /^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}A-Za-z0-9_-]+$/u;
  if (!allowed.test(trimmed)) {
    return { valid: false, reason: '昵称包含不允许的字符' };
  }
  // 禁止纯数字或纯符号
  if (/^[0-9]+$/.test(trimmed)) {
    return { valid: false, reason: '昵称不能为纯数字' };
  }
  if (/^[_-]+$/.test(trimmed)) {
    return { valid: false, reason: '昵称不能为纯符号' };
  }
  return { valid: true };
}

/** 检查并授予新成就 */
async function checkAndAwardBadges(
  db: D1Database,
  userId: string,
  currentScore: number,
  currentStreak: number,
  repsPerSet: number,
): Promise<string[]> {
  const newBadges: string[] = [];

  // 查询已有徽章
  const existing = await db.prepare(
    'SELECT badge_type FROM badges WHERE user_id = ?'
  ).bind(userId).all<BadgeRecord>();
  const owned = new Set(existing.results.map(r => r.badge_type));

  // 检查各徽章条件
  const checks: [string, boolean][] = [
    ['first_checkin', !owned.has('first_checkin')],
    ['streak_7', !owned.has('streak_7') && currentStreak >= 7],
    ['streak_30', !owned.has('streak_30') && currentStreak >= 30],
    ['streak_100', !owned.has('streak_100') && currentStreak >= 100],
    ['score_100', !owned.has('score_100') && currentScore >= 100],
    ['score_500', !owned.has('score_500') && currentScore >= 500],
  ];

  // 完美组徽章：需统计累计 reps>=15 的打卡次数
  if (!owned.has('perfect_sets_10') && repsPerSet >= 15) {
    const perfectCount = await db.prepare(
      "SELECT COUNT(*) as cnt FROM checkins WHERE user_id = ? AND reps_per_set >= 15"
    ).bind(userId).first<{ cnt: number }>();
    if (perfectCount && perfectCount.cnt >= 10) {
      checks.push(['perfect_sets_10', true]);
    }
  }

  const now = Math.floor(Date.now() / 1000);
  for (const [badgeType, shouldAward] of checks) {
    if (shouldAward) {
      try {
        await db.prepare(
          'INSERT INTO badges (user_id, badge_type, awarded_at) VALUES (?, ?, ?)'
        ).bind(userId, badgeType, now).run();
        newBadges.push(badgeType);
      } catch {
        // 唯一约束冲突则跳过（并发场景）
      }
    }
  }

  return newBadges;
}

/** 计算用户连续打卡天数（基于 checkins 表） */
async function computeStreakFromDB(
  db: D1Database,
  userId: string,
): Promise<{ streak: number; todayChecked: boolean }> {
  const rows = await db.prepare(
    "SELECT date FROM checkins WHERE user_id = ? GROUP BY date ORDER BY date DESC"
  ).bind(userId).all<{ date: string }>();

  const dates = rows.results.map(r => r.date);
  if (dates.length === 0) {
    return { streak: 0, todayChecked: false };
  }

  const today = todayStr();
  const todayChecked = dates[0] === today;

  let streak = 0;
  // 从昨天（或今天）开始往前推
  const startDate = todayChecked ? new Date(today + 'T00:00:00+08:00') : new Date(today + 'T00:00:00+08:00');
  if (!todayChecked) {
    startDate.setDate(startDate.getDate() - 1);
  }

  for (let i = 0; ; i++) {
    const checkDate = new Date(startDate);
    checkDate.setDate(checkDate.getDate() - i);
    const checkStr = checkDate.toISOString().slice(0, 10);
    if (dates.includes(checkStr)) {
      streak++;
    } else {
      break;
    }
  }

  return { streak, todayChecked };
}

// ============================================================
// 1. POST /api/checkin — 打卡上报
// ============================================================

app.post('/api/checkin', async (c) => {
  const body = await c.req.json<CheckinRequest>();
  const { user_id, sets_completed, reps_per_set, hold_seconds, device_id } = body;

  // 参数校验
  if (!user_id || !device_id) {
    return c.json({ error: '缺少必填参数 user_id 或 device_id' }, 400);
  }
  if (typeof sets_completed !== 'number' || sets_completed < 1 || sets_completed > 3) {
    return c.json({ error: 'sets_completed 需在 1-3 之间' }, 400);
  }
  if (typeof reps_per_set !== 'number' || reps_per_set < 1) {
    return c.json({ error: 'reps_per_set 必须为正整数' }, 400);
  }
  if (typeof hold_seconds !== 'number' || hold_seconds < 0) {
    return c.json({ error: 'hold_seconds 必须为非负数' }, 400);
  }

  const db = c.env.DB;
  const today = todayStr();
  const now = Math.floor(Date.now() / 1000);

  // 查询用户
  const user = await db.prepare(
    'SELECT * FROM users WHERE id = ?'
  ).bind(user_id).first<UserRecord>();

  if (!user) {
    return c.json({ error: '用户不存在，请先注册' }, 404);
  }

  // device_id 一致性校验
  if (user.device_id !== device_id) {
    return c.json({ error: 'device_id 不匹配，请使用注册时的设备' }, 403);
  }

  // 每日打卡次数限制（最多 3 次）
  const todayCheckin = await db.prepare(
    'SELECT id, checkin_count FROM checkins WHERE user_id = ? AND date = ? ORDER BY id DESC LIMIT 1'
  ).bind(user_id, today).first<{ id: number; checkin_count: number }>();

  if (todayCheckin && todayCheckin.checkin_count >= 3) {
    return c.json({ error: '今日打卡次数已达上限（3次）' }, 429);
  }

  // 写入打卡记录
  const checkinCount = todayCheckin ? todayCheckin.checkin_count + 1 : 1;
  await db.prepare(
    `INSERT INTO checkins (user_id, date, sets_completed, reps_per_set, hold_seconds, checkin_count, first_checkin_at, last_checkin_at, device_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(user_id, today, sets_completed, reps_per_set, hold_seconds, checkinCount, now, now, device_id).run();

  // 重新计算连续打卡
  const { streak, todayChecked } = await computeStreakFromDB(db, user_id);
  const bestStreak = Math.max(streak, user.best_streak);

  // 计算本次打卡得分
  const scoreDelta = computeCheckinScore(sets_completed, streak, reps_per_set);
  const newScore = user.score + scoreDelta;
  const newLevel = computeLevel(newScore);

  // 更新用户表
  await db.prepare(
    'UPDATE users SET score = ?, streak = ?, best_streak = ?, level = ? WHERE id = ?'
  ).bind(newScore, streak, bestStreak, newLevel, user_id).run();

  // 检查并授予成就
  const newAchievements = await checkAndAwardBadges(db, user_id, newScore, streak, reps_per_set);

  const resp: CheckinResponse = {
    success: true,
    streak,
    score: newScore,
    new_achievements: newAchievements,
  };

  return c.json(resp);
});

// ============================================================
// 2. GET /api/leaderboard — 排行榜（weekly / monthly / alltime）
// ============================================================
// D1 prepared statements：日期参数绑定，杜绝字符串拼接

app.get('/api/leaderboard', async (c) => {
  const type: LeaderboardType = (c.req.query('type') as LeaderboardType) || 'alltime';
  const limit = Math.min(parseInt(c.req.query('limit') || '20', 10), 100);

  const db = c.env.DB;

  // 计算 N 天前日期（Asia/Shanghai 时区）
  function dateNDaysAgo(n: number): string {
    const d = new Date(Date.now() + 8 * 3600_000 - n * 86400_000);
    return d.toISOString().slice(0, 10);
  }

  // SQL 片段：SELECT 列 / FROM + JOIN / GROUP + ORDER + LIMIT
  const cols = `
    u.id, u.display_name, u.opt_in_leaderboard,
    u.streak, u.level,
    SUM(c.sets_completed) AS total_sets,
    COUNT(CASE WHEN c.reps_per_set >= 15 THEN 1 END) AS perfect_count
  `;
  const fromJoin = 'FROM users u INNER JOIN checkins c ON c.user_id = u.id';
  const groupOrderLimit = `
    GROUP BY u.id
    ORDER BY (SUM(c.sets_completed) * 10 + u.streak * 5 + COUNT(CASE WHEN c.reps_per_set >= 15 THEN 1 END) * 5) DESC
    LIMIT ?
  `;

  let rows: D1Result<{
    id: string; display_name: string; opt_in_leaderboard: number;
    streak: number; level: string; total_sets: number; perfect_count: number;
  }>;

  if (type === 'weekly') {
    rows = await db.prepare(
      `SELECT ${cols} ${fromJoin} WHERE c.date >= ? ${groupOrderLimit}`,
    ).bind(dateNDaysAgo(7), limit).all();
  } else if (type === 'monthly') {
    rows = await db.prepare(
      `SELECT ${cols} ${fromJoin} WHERE c.date >= ? ${groupOrderLimit}`,
    ).bind(dateNDaysAgo(30), limit).all();
  } else {
    rows = await db.prepare(
      `SELECT ${cols} ${fromJoin} ${groupOrderLimit}`,
    ).bind(limit).all();
  }

  const entries: LeaderboardEntry[] = rows.results.map((row, idx) => {
    const score = row.total_sets * 10 + row.streak * 5 + row.perfect_count * 5;
    const displayName = row.opt_in_leaderboard ? row.display_name : '匿名用户';
    return {
      rank: idx + 1,
      name: displayName,
      score,
      streak: row.streak,
      level: row.level,
    };
  });

  return c.json(entries);
});

// ============================================================
// 3. GET /api/user/:id — 用户详情
// ============================================================

app.get('/api/user/:id', async (c) => {
  const userId = c.req.param('id');
  const db = c.env.DB;

  const user = await db.prepare(
    'SELECT * FROM users WHERE id = ?'
  ).bind(userId).first<UserRecord>();

  if (!user) {
    return c.json({ error: '用户不存在' }, 404);
  }

  const badges = await db.prepare(
    'SELECT * FROM badges WHERE user_id = ? ORDER BY awarded_at DESC'
  ).bind(userId).all<BadgeRecord>();

  const history = await db.prepare(
    'SELECT * FROM checkins WHERE user_id = ? ORDER BY date DESC, last_checkin_at DESC LIMIT 30'
  ).bind(userId).all<CheckinRecord>();

  const resp: UserDetailResponse = {
    name: user.display_name,
    score: user.score,
    streak: user.streak,
    level: user.level,
    achievements: badges.results,
    history: history.results,
  };

  return c.json(resp);
});

// ============================================================
// 4. POST /api/user/register — 用户注册
// ============================================================

app.post('/api/user/register', async (c) => {
  const body = await c.req.json<RegisterRequest>();
  const { display_name, device_id } = body;

  // 参数校验
  if (!device_id || typeof device_id !== 'string' || device_id.trim().length === 0) {
    return c.json({ error: 'device_id 不能为空' }, 400);
  }

  const nameResult = validateDisplayName(display_name);
  if (!nameResult.valid) {
    return c.json({ error: nameResult.reason }, 400);
  }

  // device_id 唯一性检查
  const existingUser = await c.env.DB.prepare(
    'SELECT id FROM users WHERE device_id = ?'
  ).bind(device_id).first<{ id: string }>();

  if (existingUser) {
    // 设备已注册：返回已有用户信息而非报错
    const user = await c.env.DB.prepare(
      'SELECT * FROM users WHERE device_id = ?'
    ).bind(device_id).first<UserRecord>();
    const token = generateToken();
    const resp: RegisterResponse = {
      user_id: user!.id,
      token,
    };
    return c.json({ ...resp, message: '该设备已注册，返回已有账号' });
  }

  const userId = generateUserId();
  const token = generateToken();
  const now = Math.floor(Date.now() / 1000);

  await c.env.DB.prepare(
    `INSERT INTO users (id, display_name, device_id, created_at, score, streak, best_streak, level)
     VALUES (?, ?, ?, ?, 0, 0, 0, 'bronze')`
  ).bind(userId, display_name.trim(), device_id, now).run();

  const resp: RegisterResponse = { user_id: userId, token };
  return c.json(resp, 201);
});

// ============================================================
// 5. GET /api/user/:id/streak — 连续打卡状态
// ============================================================

app.get('/api/user/:id/streak', async (c) => {
  const userId = c.req.param('id');
  const db = c.env.DB;

  const user = await db.prepare(
    'SELECT streak, best_streak FROM users WHERE id = ?'
  ).bind(userId).first<{ streak: number; best_streak: number }>();

  if (!user) {
    return c.json({ error: '用户不存在' }, 404);
  }

  const { streak, todayChecked } = await computeStreakFromDB(db, userId);

  // 若 DB 记录的连续天数与实际不一致，更新
  if (streak !== user.streak) {
    await db.prepare(
      'UPDATE users SET streak = ? WHERE id = ?'
    ).bind(streak, userId).run();
  }

  const resp: StreakResponse = {
    current_streak: streak,
    best_streak: Math.max(user.best_streak, streak),
    today_checked: todayChecked,
  };

  return c.json(resp);
});

// ============================================================
// 6. GET /api/stats — 全局统计
// ============================================================

app.get('/api/stats', async (c) => {
  const db = c.env.DB;
  const today = todayStr();

  const [totalUsers, todayCheckins, activeToday] = await Promise.all([
    db.prepare('SELECT COUNT(*) as cnt FROM users').first<{ cnt: number }>(),
    db.prepare('SELECT COUNT(*) as cnt FROM checkins WHERE date = ?').bind(today).first<{ cnt: number }>(),
    db.prepare('SELECT COUNT(DISTINCT user_id) as cnt FROM checkins WHERE date = ?').bind(today).first<{ cnt: number }>(),
  ]);

  const resp: StatsResponse = {
    total_users: totalUsers?.cnt ?? 0,
    today_checkins: todayCheckins?.cnt ?? 0,
    active_today: activeToday?.cnt ?? 0,
  };

  return c.json(resp);
});

// ============================================================
// 7. GET /api/achievements/:user_id — 用户成就列表
// ============================================================

app.get('/api/achievements/:user_id', async (c) => {
  const userId = c.req.param('user_id');
  const db = c.env.DB;

  const user = await db.prepare(
    'SELECT id FROM users WHERE id = ?'
  ).bind(userId).first<{ id: string }>();

  if (!user) {
    return c.json({ error: '用户不存在' }, 404);
  }

  const badges = await db.prepare(
    'SELECT * FROM badges WHERE user_id = ? ORDER BY awarded_at DESC'
  ).bind(userId).all<BadgeRecord>();

  const resp: AchievementResponse = { achievements: badges.results };
  return c.json(resp);
});

// ============================================================
// 健康检查
// ============================================================

app.get('/api/health', (c) => {
  return c.json({ status: 'ok', timestamp: Math.floor(Date.now() / 1000) });
});

// ============================================================
// 404
// ============================================================

app.notFound((c) => {
  return c.json({ error: 'Not Found' }, 404);
});

// ============================================================
// 全局错误处理
// ============================================================

app.onError((err, c) => {
  console.error('[vita-leaderboard] Unhandled error:', err);
  return c.json({ error: '服务器内部错误' }, 500);
});

export default app;

// Cron Worker 入口：每日凌晨聚合统计（wrangler.toml triggers.crons 驱动）
export { handleScheduled as scheduled };
