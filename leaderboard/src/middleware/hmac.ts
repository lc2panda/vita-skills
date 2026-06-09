// Input:  Hono Context（请求上下文），从 req.header 读取 X-Signature / X-Timestamp
// Output: 合法请求透传 next()，非法请求返回 401
// Pos:   POST /api/checkin 防作弊 L1 签名验证层，在 authMiddleware 之后、handler 之前
//
// 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。

import type { Context, Next } from 'hono';

// 共享密钥 — 生产环境应从 secrets / env 读取
const SHARED_SECRET = 'vita-health-hmac-secret-2026';

// 时间戳有效期窗口（秒）
const TIMESTAMP_WINDOW = 300; // 5 分钟

/**
 * HMAC-SHA256 请求签名验证中间件（防作弊 L1）
 *
 * 客户端在请求中携带：
 *   X-Signature: hex(HMAC-SHA256(secret, "timestamp:method:path:body"))
 *   X-Timestamp:  unix 秒级时间戳
 *
 * 服务端验证：
 *   1. 时间戳是否在窗口内（防重放）
 *   2. 重构 payload 并计算 HMAC，比对签名
 */
export async function hmacMiddleware(c: Context, next: Next) {
  const signature = c.req.header('X-Signature');
  const timestamp = c.req.header('X-Timestamp');

  if (!signature || !timestamp) {
    return c.json({ error: 'X-Signature and X-Timestamp headers required' }, 401);
  }

  // 时间戳防重放
  const now = Math.floor(Date.now() / 1000);
  const reqTime = parseInt(timestamp, 10);
  if (isNaN(reqTime) || Math.abs(now - reqTime) > TIMESTAMP_WINDOW) {
    return c.json({ error: 'Request expired or invalid timestamp' }, 401);
  }

  // 读取请求体
  const body = await c.req.text();
  const payload = `${timestamp}:${c.req.method}:${c.req.path}:${body}`;

  // Web Crypto API HMAC-SHA256
  const encoder = new TextEncoder();
  const keyData = encoder.encode(SHARED_SECRET);

  const key = await crypto.subtle.importKey(
    'raw',
    keyData,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const sig = await crypto.subtle.sign('HMAC', key, encoder.encode(payload));
  const expectedSig = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  if (signature !== expectedSig) {
    return c.json({ error: 'Invalid signature' }, 401);
  }

  await next();
}
