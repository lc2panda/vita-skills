/**
 * Input:  Incoming checkin request body + stored user record + previous checkin record
 * Output: Either passes (with optional suspicious flag) or rejects with reason
 * Pos:   L3-L5 defense layer — data integrity and behavior analysis per design doc §4.4
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface CheckinPayload {
  sets: number;
  reps_per_set: number;
  duration_per_contraction: number;
  device_id: string;
}

export interface StoredUser {
  id: string;
  registered_device_id: string;
  created_at: number;
}

export interface PreviousCheckin {
  last_checkin_at: number;
}

// Rational ranges per design doc §4.4 L5 and §3.4 training parameters
export interface AntiCheatConfig {
  /** Minimum interval between two checkins (seconds). Default: 7200 (2 hours).
   *  Rationale: morning/midday/evening structure — 3 sessions/day with ≥2h gap */
  minCheckinIntervalSeconds?: number;
  /** Valid sets range [min, max]. Default: [1, 5] */
  setsRange?: [number, number];
  /** Valid reps_per_set range [min, max]. Default: [5, 20] */
  repsRange?: [number, number];
  /** Valid duration_per_contraction range [min, max]. Default: [3, 15] */
  holdRange?: [number, number];
}

const DEFAULT_CONFIG: Required<AntiCheatConfig> = {
  minCheckinIntervalSeconds: 7200,
  setsRange: [1, 5],
  repsRange: [5, 20],
  holdRange: [3, 15],
};

export interface AntiCheatResult {
  /** Whether the checkin is allowed */
  allowed: boolean;
  /** Human-readable rejection reason (when allowed=false) */
  reason?: string;
  /** Suspicious flags attached to the checkin (even when allowed=true) */
  flags: string[];
}

// ---------------------------------------------------------------------------
// Detector helpers
// ---------------------------------------------------------------------------

/**
 * device_id consistency check (L1).
 * The device_id in the checkin payload must match the one stored at registration.
 */
function checkDeviceConsistency(
  payloadDeviceId: string,
  storedDeviceId: string,
): string | null {
  if (payloadDeviceId !== storedDeviceId) {
    return 'device_id mismatch: checkin device differs from registered device';
  }
  return null;
}

/**
 * Time reasonability check (L3).
 * Adjacent checkins must be at least minCheckinIntervalSeconds apart.
 */
function checkTimeInterval(
  now: number,
  previousCheckin: PreviousCheckin | null,
  minInterval: number,
): string | null {
  if (!previousCheckin) return null; // First checkin — no interval to check
  const elapsed = now - previousCheckin.last_checkin_at;
  if (elapsed < minInterval) {
    return `checkin too frequent: ${elapsed}s elapsed, minimum ${minInterval}s required`;
  }
  return null;
}

/**
 * Data reasonability check (L5).
 * Validates sets, reps, and hold duration are within physiological ranges.
 */
function checkDataRanges(
  payload: CheckinPayload,
  setsRange: [number, number],
  repsRange: [number, number],
  holdRange: [number, number],
): string[] {
  const flags: string[] = [];
  const { sets, reps_per_set, duration_per_contraction } = payload;

  if (sets < setsRange[0] || sets > setsRange[1]) {
    flags.push(`sets out of range: ${sets} (valid: ${setsRange[0]}-${setsRange[1]})`);
  }
  if (reps_per_set < repsRange[0] || reps_per_set > repsRange[1]) {
    flags.push(`reps_per_set out of range: ${reps_per_set} (valid: ${repsRange[0]}-${repsRange[1]})`);
  }
  if (duration_per_contraction < holdRange[0] || duration_per_contraction > holdRange[1]) {
    flags.push(`duration_per_contraction out of range: ${duration_per_contraction} (valid: ${holdRange[0]}-${holdRange[1]})`);
  }

  return flags;
}

/**
 * Timestamp regularity anomaly detection (L4).
 * Detects robotic patterns — if the fractional-second component is always
 * identical across multiple recent checkins, flag as suspicious.
 *
 * This is a lightweight heuristic; a full implementation would query
 * recent checkin timestamps from D1 and compute standard deviation.
 */
function checkTimestampRegularity(
  now: number,
  previousTimestamps: number[],
): string | null {
  if (previousTimestamps.length < 3) return null;

  // Extract millisecond components
  const msParts = previousTimestamps.map((ts) => ts % 1000);
  // If all ms parts are identical (variance == 0), flag as robotic
  const unique = new Set(msParts);
  if (unique.size === 1) {
    return 'timestamp regularity anomaly: identical millisecond component across checkins (possible bot)';
  }

  // Also check: standard deviation of intervals < 1 second
  if (previousTimestamps.length >= 3) {
    const intervals: number[] = [];
    for (let i = 1; i < previousTimestamps.length; i++) {
      intervals.push(previousTimestamps[i] - previousTimestamps[i - 1]);
    }
    const mean = intervals.reduce((a, b) => a + b, 0) / intervals.length;
    const variance = intervals.reduce((sum, v) => sum + (v - mean) ** 2, 0) / intervals.length;
    const stdDev = Math.sqrt(variance);
    if (stdDev < 1.0) {
      return `timestamp regularity anomaly: interval stddev ${stdDev.toFixed(3)}s < 1s (possible bot)`;
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Creates an anti-cheat validator.
 *
 * Checks performed (per design doc §4.4):
 * - L1: device_id consistency with registration record
 * - L3: minimum 2-hour interval between checkins
 * - L4: timestamp regularity anomaly detection (robotic patterns)
 * - L5: data range validation (sets 1-5, reps 5-20, hold 3-15)
 *
 * Anomaly flags (L4) do NOT reject — they mark the checkin as suspicious for
 * later review. Range violations (L5) are flagged but do not reject either,
 * following the spec: "异常检测标记（不拒绝，标记 suspicious flag）".
 */
export function createAntiCheatValidator(
  config?: AntiCheatConfig,
) {
  const cfg = { ...DEFAULT_CONFIG, ...config };

  function validate(
    payload: CheckinPayload,
    storedUser: StoredUser,
    previousCheckin: PreviousCheckin | null,
    recentTimestamps: number[] = [],
  ): AntiCheatResult {
    const now = Math.floor(Date.now() / 1000);
    const flags: string[] = [];
    const errors: string[] = [];

    // L1: device_id consistency — hard reject
    const deviceError = checkDeviceConsistency(payload.device_id, storedUser.registered_device_id);
    if (deviceError) {
      errors.push(deviceError);
    }

    // L3: time window — hard reject
    const timeError = checkTimeInterval(now, previousCheckin, cfg.minCheckinIntervalSeconds);
    if (timeError) {
      errors.push(timeError);
    }

    // L4: timestamp regularity — soft flag only
    const regularityFlag = checkTimestampRegularity(now * 1000, recentTimestamps);
    if (regularityFlag) {
      flags.push(regularityFlag);
    }

    // L5: data range — soft flag only (per spec)
    const rangeFlags = checkDataRanges(payload, cfg.setsRange, cfg.repsRange, cfg.holdRange);
    flags.push(...rangeFlags);

    if (errors.length > 0) {
      return {
        allowed: false,
        reason: errors.join('; '),
        flags,
      };
    }

    return {
      allowed: true,
      flags,
    };
  }

  return { validate };
}
