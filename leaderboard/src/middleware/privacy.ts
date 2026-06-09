/**
 * Input:  API response objects, log entries, incoming request origin
 * Output: Sanitized response objects, hashed log entries, CORS headers
 * Pos:   Privacy enforcement layer — wraps all outbound data and inbound CORS
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface PrivacyConfig {
  /** Allowed CORS origins. Default: empty (deny all cross-origin). */
  allowedOrigins?: string[];
  /** Replacement string for anonymized usernames. Default: '用户****' */
  anonymousDisplayName?: string;
}

const DEFAULT_CONFIG: Required<PrivacyConfig> = {
  allowedOrigins: [],
  anonymousDisplayName: '用户****',
};

export interface UserRecord {
  id: string;
  display_name: string;
  privacy_mode?: number;  // 0=public, 1=anonymous (INTEGER in D1)
  device_id?: string;
  ip?: string;
  [key: string]: unknown;
}

export interface LogEntry {
  message: string;
  ip?: string;
  user_id?: string;
  device_id?: string;
  timestamp?: number;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// SHA-256 hashing via Web Crypto API (available in Cloudflare Workers runtime)
// ---------------------------------------------------------------------------

async function sha256Hex(input: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(input);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Hash an IP address using SHA-256, returning only the first 8 hex characters.
 * This provides 32 bits of entropy — sufficient for log correlation without
 * exposing the original IP.
 */
async function hashIP(ip: string): Promise<string> {
  const full = await sha256Hex(ip);
  return full.slice(0, 8);
}

// ---------------------------------------------------------------------------
// Response sanitization
// ---------------------------------------------------------------------------

/**
 * Sanitize a user record for API response.
 *
 * Transformations:
 * - privacy_mode=1 (anonymous): display_name → '用户****'
 * - device_id: removed from response
 * - ip: removed from response
 */
export function sanitizeUserResponse(
  user: UserRecord,
  anonymousLabel?: string,
): Record<string, unknown> {
  const label = anonymousLabel ?? DEFAULT_CONFIG.anonymousDisplayName;
  const sanitized: Record<string, unknown> = {};

  for (const [key, value] of Object.entries(user)) {
    switch (key) {
      case 'display_name':
        // Anonymize if privacy_mode is set to anonymous (value 1)
        sanitized[key] = user.privacy_mode === 1 ? label : value;
        break;
      case 'device_id':
      case 'ip':
        // Strip sensitive fields entirely — never expose in API responses
        break;
      default:
        sanitized[key] = value;
    }
  }

  return sanitized;
}

/**
 * Sanitize an array of user records for list endpoints (e.g., leaderboard).
 */
export function sanitizeUserListResponse(
  users: UserRecord[],
  anonymousLabel?: string,
): Record<string, unknown>[] {
  return users.map((u) => sanitizeUserResponse(u, anonymousLabel));
}

// ---------------------------------------------------------------------------
// Log sanitization
// ---------------------------------------------------------------------------

/**
 * Sanitize a log entry by hashing IP addresses.
 *
 * Log entries that contain raw IPs are transformed:
 * - ip → hashed (SHA-256 first 8 hex chars)
 * - Original IP is NOT preserved — only the hash for correlation
 *
 * This enables debugging/troubleshooting without storing raw PII in logs.
 */
export async function sanitizeLogEntry(entry: LogEntry): Promise<LogEntry> {
  const sanitized: LogEntry = { ...entry };

  if (sanitized.ip) {
    sanitized.ip = await hashIP(sanitized.ip);
  }

  // Also hash device_id in logs for consistency
  if (sanitized.device_id) {
    sanitized.device_id = await hashIP(sanitized.device_id);
  }

  return sanitized;
}

// ---------------------------------------------------------------------------
// Data retention: D1 cron trigger SQL
// ---------------------------------------------------------------------------

/**
 * Returns the SQL statement for cleaning raw IP logs older than 30 days.
 *
 * Intended to be registered as a D1 Cron Trigger in wrangler.toml:
 *
 * ```toml
 * [[d1_databases]]
 * binding = "DB"
 * database_name = "vanilla-health"
 * database_id = "xxx"
 *
 * [triggers]
 * crons = ["0 3 * * *"]  # Run at 03:00 UTC daily
 * ```
 *
 * The Worker's scheduled handler should execute this SQL.
 *
 * Assumes a table structure:
 * ```sql
 * CREATE TABLE IF NOT EXISTS access_logs (
 *   id INTEGER PRIMARY KEY AUTOINCREMENT,
 *   ip_hash TEXT NOT NULL,
 *   raw_ip TEXT,
 *   user_id TEXT,
 *   endpoint TEXT,
 *   created_at INTEGER NOT NULL DEFAULT (unixepoch())
 * );
 * ```
 */
export const DATA_RETENTION_SQL = `
DELETE FROM access_logs
WHERE created_at < unixepoch() - 2592000
  AND raw_ip IS NOT NULL;
`;

/**
 * SQL to fully purge entries after raw IP data has been cleaned.
 * Run this after the above cleanup to reclaim disk space.
 */
export const DATA_RETENTION_VACUUM_SQL = `PRAGMA wal_checkpoint(TRUNCATE);`;

// ---------------------------------------------------------------------------
// CORS middleware
// ---------------------------------------------------------------------------

/**
 * Generate CORS headers based on the request's Origin against the configured allowlist.
 *
 * Returns:
 * - For preflight (OPTIONS): a full Response with appropriate CORS headers
 * - For simple requests: an object of headers to merge into the final response
 *
 * Behavior:
 * - If origin is not in allowlist → no CORS headers (browser will block)
 * - If origin is in allowlist → reflect the origin, allow standard methods/headers
 */
export function handleCORS(
  request: Request,
  allowedOrigins: string[] = [],
): Response | Record<string, string> {
  const origin = request.headers.get('Origin');

  // No Origin header — not a cross-origin request, no CORS needed
  if (!origin) {
    return {};
  }

  const isAllowed = allowedOrigins.length === 0 || allowedOrigins.includes(origin);

  if (!isAllowed) {
    // Return no CORS headers — browser will enforce same-origin policy
    return {};
  }

  const corsHeaders: Record<string, string> = {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-User-Id, X-Signature',
    'Access-Control-Max-Age': '86400',
  };

  // Handle preflight
  if (request.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: corsHeaders,
    });
  }

  return corsHeaders;
}

// ---------------------------------------------------------------------------
// Privacy middleware factory
// ---------------------------------------------------------------------------

/**
 * Creates the privacy middleware bundle.
 */
export function createPrivacyMiddleware(config?: PrivacyConfig) {
  const cfg = { ...DEFAULT_CONFIG, ...config };

  return {
    sanitizeUserResponse: (user: UserRecord) =>
      sanitizeUserResponse(user, cfg.anonymousDisplayName),
    sanitizeUserListResponse: (users: UserRecord[]) =>
      sanitizeUserListResponse(users, cfg.anonymousDisplayName),
    sanitizeLogEntry,
    handleCORS: (request: Request) =>
      handleCORS(request, cfg.allowedOrigins),
    DATA_RETENTION_SQL,
    DATA_RETENTION_VACUUM_SQL,
  };
}
