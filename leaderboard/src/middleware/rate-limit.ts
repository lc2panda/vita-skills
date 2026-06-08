/**
 * Input: Cloudflare Workers Request, Env (with KV namespace), optional whitelist config
 * Output: Either passes through or returns 429 with Retry-After headers
 * Pos:  L2 defense layer — sits before all API route handlers
 */

export interface RateLimitConfig {
  /** Max requests per IP per minute. Default: 10 */
  ipPerMinute?: number;
  /** Max checkins per user per day. Default: 3 (corresponds to 3 training sessions) */
  userCheckinsPerDay?: number;
  /** IPs to exempt from rate limiting */
  whitelistIPs?: string[];
  /** User IDs to exempt from rate limiting */
  whitelistUsers?: string[];
}

const DEFAULT_CONFIG: Required<RateLimitConfig> = {
  ipPerMinute: 10,
  userCheckinsPerDay: 3,
  whitelistIPs: [],
  whitelistUsers: [],
};

interface KVNamespace {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
}

/**
 * Creates a rate-limit middleware for Cloudflare Workers.
 *
 * Uses KV to persist counters. Two tiers of limiting:
 * 1. Per-IP: max N requests per minute (global API throttle)
 * 2. Per-user: max M checkins per day (training cap per design doc §4.4 L2)
 */
export function createRateLimiter(
  env: { RATE_LIMIT_KV: KVNamespace },
  config?: RateLimitConfig,
) {
  const cfg = { ...DEFAULT_CONFIG, ...config };

  // Precompute epoch boundaries for fast key construction
  function getMinuteBucket(): number {
    return Math.floor(Date.now() / 60000);
  }

  function getDayBucket(): string {
    // ISO date string truncated to YYYY-MM-DD, used directly as part of KV key
    const d = new Date();
    return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
  }

  /**
   * The middleware handler. Call this for every incoming request.
   *
   * @param request  The incoming Fetch API Request
   * @param userId   The authenticated user ID (null for unauthenticated requests)
   * @param endpointType 'checkin' for POST /api/checkin, 'general' for everything else
   */
  async function handle(
    request: Request,
    userId: string | null,
    endpointType: 'checkin' | 'general',
  ): Promise<Response | null> {
    // Resolve client IP — prefer CF-Connecting-IP header set by Cloudflare edge
    const ip = request.headers.get('CF-Connecting-IP') ?? '0.0.0.0';

    // --- Whitelist check ---
    if (cfg.whitelistIPs.includes(ip)) return null;
    if (userId && cfg.whitelistUsers.includes(userId)) return null;

    // --- Tier 1: Per-IP per-minute rate limit ---
    const minuteBucket = getMinuteBucket();
    const ipKey = `rl:ip:${ip}:${minuteBucket}`;

    const ipCountStr = await env.RATE_LIMIT_KV.get(ipKey);
    const ipCount = ipCountStr ? parseInt(ipCountStr, 10) : 0;

    if (ipCount >= cfg.ipPerMinute) {
      const retryAfter = 60 - (Date.now() % 60000) / 1000;
      return new Response(
        JSON.stringify({
          error: 'rate_limit_exceeded',
          message: `Too many requests. Limit: ${cfg.ipPerMinute}/minute per IP.`,
        }),
        {
          status: 429,
          headers: {
            'Content-Type': 'application/json',
            'Retry-After': String(Math.ceil(retryAfter)),
            'X-RateLimit-Limit': String(cfg.ipPerMinute),
            'X-RateLimit-Remaining': '0',
            'X-RateLimit-Reset': String(minuteBucket * 60 + 60),
          },
        },
      );
    }

    // Increment IP counter. TTL = 120s covers the current + next bucket to avoid races.
    // The counter will naturally expire after this window.
    await env.RATE_LIMIT_KV.put(ipKey, String(ipCount + 1), { expirationTtl: 120 });

    // --- Tier 2: Per-user daily checkin limit ---
    if (endpointType === 'checkin' && userId) {
      const dayBucket = getDayBucket();
      const userKey = `rl:user:${userId}:checkin:${dayBucket}`;

      const userCountStr = await env.RATE_LIMIT_KV.get(userKey);
      const userCount = userCountStr ? parseInt(userCountStr, 10) : 0;

      if (userCount >= cfg.userCheckinsPerDay) {
        return new Response(
          JSON.stringify({
            error: 'daily_checkin_limit',
            message: `Daily checkin limit reached. Limit: ${cfg.userCheckinsPerDay}/day.`,
          }),
          {
            status: 429,
            headers: {
              'Content-Type': 'application/json',
              'Retry-After': '86400',
              'X-RateLimit-Limit': String(cfg.userCheckinsPerDay),
              'X-RateLimit-Remaining': '0',
            },
          },
        );
      }

      // Increment user daily checkin counter. TTL = 86400s (24h).
      await env.RATE_LIMIT_KV.put(userKey, String(userCount + 1), { expirationTtl: 86400 });
    }

    // If we get here, the request passes all rate limits
    return null;
  }

  return { handle };
}
