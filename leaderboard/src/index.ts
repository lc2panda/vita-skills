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
  UserListItem,
  StreakResponse,
  StatsResponse,
  AchievementResponse,
  UserRecord,
  CheckinRecord,
  BadgeRecord,
  ChallengeRecord,
  ChallengeDetailResponse,
} from './types';
import { BADGE_DEFINITIONS, computeLevel, computeCheckinScore, computeLoyaltyTier } from './types';
import { handleScheduled } from './cron/daily-stats';
import { createAuthMiddleware } from './middleware/auth';
import { hmacMiddleware } from './middleware/hmac';
import { sanitizeUserResponse, sanitizeUserListResponse } from './middleware/privacy';

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
    || 'unknown';
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
// Bearer Token 认证中间件（Hono 包装器）
// ============================================================

async function authMiddleware(c: any, next: any) {
  const auth = createAuthMiddleware(c.env.DB);
  const ctx = await auth.authenticate(c.req.raw);
  if (!ctx) {
    return c.json({
      error: 'unauthorized',
      message: 'Valid Bearer token required for this operation.',
    }, 401);
  }
  c.set('userId', ctx.userId);
  await next();
}

// ============================================================
// 1. POST /api/checkin — 打卡上报（需 Bearer Token 认证）
// ============================================================

app.post('/api/checkin', authMiddleware, hmacMiddleware, async (c) => {
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

  // 更新隐私模式（如果请求中包含 privacy_mode）
  if (body.privacy_mode !== undefined) {
    const pm = body.privacy_mode === 1 ? 1 : 0;
    await db.prepare('UPDATE users SET privacy_mode = ? WHERE id = ?')
      .bind(pm, user_id).run();
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

  // 更新忠诚度积分（每次打卡 +10 基础分）
  const loyaltyScore = (user.loyalty_score ?? 0) + 10;
  const loyaltyTier = computeLoyaltyTier(loyaltyScore);
  await db.prepare(
    'UPDATE users SET loyalty_score = ?, loyalty_tier = ? WHERE id = ?'
  ).bind(loyaltyScore, loyaltyTier, user_id).run();

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
    u.id, u.display_name, u.opt_in_leaderboard, u.privacy_mode,
    u.streak, u.level,
    u.loyalty_score, u.loyalty_tier,
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
    id: string; display_name: string; opt_in_leaderboard: number; privacy_mode: number;
    streak: number; level: string; loyalty_score: number; loyalty_tier: string; total_sets: number; perfect_count: number;
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
    const displayName = (row.opt_in_leaderboard && row.privacy_mode !== 1) ? row.display_name : '匿名用户';
    return {
      id: row.id,
      rank: idx + 1,
      name: displayName,
      score,
      streak: row.streak,
      level: row.level,
      loyalty_score: row.loyalty_score,
      loyalty_tier: row.loyalty_tier,
    };
  });

  return c.json(entries);
});

// ============================================================
// 3a. GET /api/users — 批量用户列表（脱敏）
// ============================================================

app.get('/api/users', async (c) => {
  const db = c.env.DB;

  const users = await db.prepare(
    'SELECT id, display_name, score, streak, level, loyalty_score, loyalty_tier, privacy_mode FROM users ORDER BY score DESC'
  ).all<UserRecord & { privacy_mode: number }>();

  const list: UserListItem[] = users.results.map((u) => ({
    id: u.id,
    display_name: u.privacy_mode === 1 ? 'Anonymous' : u.display_name,
    score: u.score,
    streak: u.streak,
    level: u.level,
    loyalty_score: u.loyalty_score ?? 0,
    loyalty_tier: u.loyalty_tier ?? 'F',
  }));

  return c.json(list);
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

  // 隐私脱敏: privacy_mode=1 时隐藏 display_name
  const sanitizedUser = sanitizeUserResponse(user);

  const resp: UserDetailResponse = {
    name: sanitizedUser.display_name as string,
    score: user.score,
    streak: user.streak,
    level: user.level,
    loyalty_score: user.loyalty_score,
    loyalty_tier: user.loyalty_tier,
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
    // 持久化 token
    await c.env.DB.prepare(
      'UPDATE users SET token = ? WHERE id = ?'
    ).bind(token, user!.id).run();
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
    `INSERT INTO users (id, display_name, device_id, token, created_at, score, streak, best_streak, level, loyalty_score, loyalty_tier)
     VALUES (?, ?, ?, ?, ?, 0, 0, 0, 'bronze', 0, 'F')`
  ).bind(userId, display_name.trim(), device_id, token, now).run();

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
// PK 挑战系统
// ============================================================

// POST /api/challenge — 发起 PK 挑战
app.post('/api/challenge', authMiddleware, async (c) => {
  const db = c.env.DB;
  const userId: string = (c as any).get('userId');

  let body: { opponent_id?: string; start_date?: string; end_date?: string };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: 'Invalid JSON' }, 400);
  }

  const { opponent_id, start_date, end_date } = body;

  if (!opponent_id) {
    return c.json({ error: 'opponent_id is required' }, 400);
  }
  if (opponent_id === userId) {
    return c.json({ error: 'Cannot challenge yourself' }, 400);
  }

  // 检查对手是否存在
  const opponent = await db.prepare(
    'SELECT id, display_name FROM users WHERE id = ?'
  ).bind(opponent_id).first<{ id: string; display_name: string }>();
  if (!opponent) {
    return c.json({ error: 'Opponent not found' }, 404);
  }

  const challengeId = crypto.randomUUID();
  const now = new Date().toISOString();
  const start = start_date || now;
  const end = end_date || new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();

  await db.prepare(`
    INSERT INTO challenges (id, challenger_id, opponent_id, status, start_date, end_date, created_at)
    VALUES (?, ?, ?, 'accepted', ?, ?, ?)
  `).bind(challengeId, userId, opponent_id, start, end, now).run();

  return c.json({
    id: challengeId,
    challenger_id: userId,
    opponent_id,
    status: 'accepted',
    start_date: start,
    end_date: end,
    created_at: now,
  }, 201);
});

// GET /api/challenges — 用户挑战列表
app.get('/api/challenges', authMiddleware, async (c) => {
  const db = c.env.DB;
  const userId: string = (c as any).get('userId');
  const status = c.req.query('status');

  let query = `
    SELECT c.*,
           ch.display_name as challenger_name,
           op.display_name as opponent_name
    FROM challenges c
    JOIN users ch ON c.challenger_id = ch.id
    JOIN users op ON c.opponent_id = op.id
    WHERE (c.challenger_id = ? OR c.opponent_id = ?)
  `;
  const params: any[] = [userId, userId];

  if (status) {
    query += ' AND c.status = ?';
    params.push(status);
  }
  query += ' ORDER BY c.created_at DESC LIMIT 50';

  const challenges = await db.prepare(query).bind(...params).all<ChallengeRecord & { challenger_name: string; opponent_name: string }>();
  return c.json(challenges.results);
});

// GET /api/challenge/:id — 挑战详情（含双方当前分数）
app.get('/api/challenge/:id', async (c) => {
  const db = c.env.DB;
  const challengeId = c.req.param('id');

  const challenge = await db.prepare(`
    SELECT c.*,
           ch.display_name as challenger_name,
           op.display_name as opponent_name
    FROM challenges c
    JOIN users ch ON c.challenger_id = ch.id
    JOIN users op ON c.opponent_id = op.id
    WHERE c.id = ?
  `).bind(challengeId).first<ChallengeDetailResponse>();

  if (!challenge) {
    return c.json({ error: 'Challenge not found' }, 404);
  }

  // 计算双方在挑战期内的得分（动态计算，每个 set 计 10 分）
  const challengerScore = await db.prepare(`
    SELECT COALESCE(SUM(sets_completed) * 10, 0) as score
    FROM checkins
    WHERE user_id = ? AND date BETWEEN ? AND ?
  `).bind(challenge.challenger_id, challenge.start_date, challenge.end_date).first<{ score: number }>();

  const opponentScore = await db.prepare(`
    SELECT COALESCE(SUM(sets_completed) * 10, 0) as score
    FROM checkins
    WHERE user_id = ? AND date BETWEEN ? AND ?
  `).bind(challenge.opponent_id, challenge.start_date, challenge.end_date).first<{ score: number }>();

  return c.json({
    ...challenge,
    challenger_score: challengerScore?.score ?? 0,
    opponent_score: opponentScore?.score ?? 0,
  });
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
