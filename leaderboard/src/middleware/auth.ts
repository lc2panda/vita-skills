/**
 * Input:  Incoming HTTP Request, D1 database binding
 * Output: Authenticated user context or 401 rejection
 * Pos:   L1 gate — protects all write endpoints (POST), allows read endpoints (GET)
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface AuthConfig {
  /** Length of generated token in hex characters. Default: 32 (128 bits). */
  tokenLength?: number;
  /** Token expiration in seconds. 0 = never expires. Default: 0. */
  tokenExpirySeconds?: number;
}

const DEFAULT_CONFIG: Required<AuthConfig> = {
  tokenLength: 32,
  tokenExpirySeconds: 0,
};

export interface AuthUser {
  id: string;
  display_name: string;
  token: string;
  created_at: number;
  [key: string]: unknown;
}

export interface AuthContext {
  userId: string;
  token: string;
}

// Minimal D1 interface for what we need
interface D1Result<T> {
  results: T[];
}

interface D1Database {
  prepare(query: string): {
    bind(...values: unknown[]): {
      first<T = Record<string, unknown>>(): Promise<T | null>;
      run(): Promise<D1Result<unknown>>;
      all<T = Record<string, unknown>>(): Promise<D1Result<T>>;
    };
  };
}

// ---------------------------------------------------------------------------
// Token generation (CSPRNG-backed)
// ---------------------------------------------------------------------------

/**
 * Generate a cryptographically secure random hex token.
 * Uses Web Crypto API available in Cloudflare Workers runtime.
 *
 * tokenLength=32 hex chars → 128 bits of entropy.
 */
function generateToken(length: number = 32): string {
  const byteLength = Math.ceil(length / 2);
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  return hex.slice(0, length);
}

// ---------------------------------------------------------------------------
// Bearer token extraction
// ---------------------------------------------------------------------------

/**
 * Extract Bearer token from the Authorization header.
 * Returns null if header is missing or malformed.
 */
function extractBearerToken(request: Request): string | null {
  const auth = request.headers.get('Authorization');
  if (!auth) return null;

  const parts = auth.split(/\s+/);
  if (parts.length !== 2 || parts[0].toLowerCase() !== 'bearer') {
    return null;
  }

  const token = parts[1].trim();
  return token.length > 0 ? token : null;
}

// ---------------------------------------------------------------------------
// Auth middleware factory
// ---------------------------------------------------------------------------

/**
 * Creates the auth middleware.
 *
 * Rules per design doc §4.7:
 * - GET requests: public, no authentication required
 * - POST requests: require valid Bearer token
 * - Token lookup: queried from D1 users table
 *
 * Usage in a Worker:
 *
 * ```ts
 * const auth = createAuthMiddleware(env.DB);
 *
 * export default {
 *   async fetch(request, env) {
 *     if (request.method === 'POST') {
 *       const ctx = await auth.authenticate(request);
 *       if (!ctx) return auth.unauthorizedResponse();
 *       // ... handle authorized write
 *     }
 *     // GET — proceed without auth
 *   }
 * };
 * ```
 */
export function createAuthMiddleware(
  db: D1Database,
  config?: AuthConfig,
) {
  const cfg = { ...DEFAULT_CONFIG, ...config };

  /**
   * Authenticate a request.
   *
   * @returns AuthContext if valid token found, null otherwise.
   */
  async function authenticate(request: Request): Promise<AuthContext | null> {
    const token = extractBearerToken(request);
    if (!token) return null;

    // Look up token in users table. Using parameterized query to prevent injection.
    let query = 'SELECT id, token, created_at FROM users WHERE token = ?';
    if (cfg.tokenExpirySeconds > 0) {
      // Only consider tokens that haven't expired
      query += ` AND created_at > ${Math.floor(Date.now() / 1000) - cfg.tokenExpirySeconds}`;
    }
    query += ' LIMIT 1';

    const user = await db.prepare(query).bind(token).first<{ id: string; token: string; created_at: number }>();

    if (!user) return null;

    return {
      userId: user.id,
      token: user.token,
    };
  }

  /**
   * Require authentication — returns context or null (caller should return 401).
   * Convenience method that wraps authenticate() with a boolean guard.
   */
  async function requireAuth(request: Request): Promise<AuthContext | null> {
    return authenticate(request);
  }

  /**
   * Returns a standard 401 Unauthorized response.
   */
  function unauthorizedResponse(): Response {
    return new Response(
      JSON.stringify({
        error: 'unauthorized',
        message: 'Valid Bearer token required for this operation.',
      }),
      {
        status: 401,
        headers: {
          'Content-Type': 'application/json',
          'WWW-Authenticate': 'Bearer realm="vanilla-health"',
        },
      },
    );
  }

  /**
   * Generate a new auth token. Called at registration time.
   *
   * @returns A hex token string (e.g., 32 hex chars).
   */
  function createToken(): string {
    return generateToken(cfg.tokenLength);
  }

  /**
   * Store a newly generated token in the users table.
   * Called after registration to persist the token.
   */
  async function storeToken(userId: string, token: string): Promise<void> {
    await db
      .prepare('UPDATE users SET token = ? WHERE id = ?')
      .bind(token, userId)
      .run();
  }

  return {
    authenticate,
    requireAuth,
    unauthorizedResponse,
    createToken,
    storeToken,
  };
}
