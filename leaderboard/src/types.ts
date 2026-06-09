// Input: 无（纯类型定义）
// Output: 所有 API 端点的请求/响应类型、数据库记录类型、徽章常量
// Pos: 类型系统的单一真相源，被 index.ts 和所有 handler 引用

// ============================================================
// 数据库记录类型
// ============================================================

export interface UserRecord {
  id: string;
  display_name: string;
  device_id: string;
  token?: string;
  privacy_mode?: number;
  loyalty_score?: number;
  loyalty_tier?: string;
  created_at: number;
  opt_in_leaderboard: boolean;
  stage: string;
  score: number;
  streak: number;
  best_streak: number;
  level: string;
}

export interface CheckinRecord {
  id: number;
  user_id: string;
  date: string;
  sets_completed: number;
  reps_per_set: number;
  hold_seconds: number;
  checkin_count: number;
  first_checkin_at: number;
  last_checkin_at: number;
  device_id: string;
}

export interface BadgeRecord {
  id: number;
  user_id: string;
  badge_type: string;
  awarded_at: number;
}

export interface ChallengeRecord {
  id: string;
  challenger_id: string;
  opponent_id: string;
  status: 'pending' | 'accepted' | 'completed' | 'cancelled';
  challenger_score: number;
  opponent_score: number;
  winner_id: string | null;
  start_date: string;
  end_date: string;
  created_at: string;
}

export interface ChallengeDetailResponse extends ChallengeRecord {
  challenger_name: string;
  opponent_name: string;
}

// ============================================================
// 请求类型
// ============================================================

export interface CheckinRequest {
  user_id: string;
  sets_completed: number;
  reps_per_set: number;
  hold_seconds: number;
  device_id: string;
  privacy_mode?: number;  // 0=公开, 1=匿名 (客户端可选的隐私偏好更新)
}

export interface RegisterRequest {
  display_name: string;
  device_id: string;
}

// ============================================================
// 响应类型
// ============================================================

export interface CheckinResponse {
  success: boolean;
  streak: number;
  score: number;
  new_achievements: string[];
}

export interface LeaderboardEntry {
  rank: number;
  name: string;
  score: number;
  streak: number;
  level: string;
  loyalty_score?: number;
  loyalty_tier?: string;
}

export interface UserDetailResponse {
  name: string;
  score: number;
  streak: number;
  level: string;
  loyalty_score?: number;
  loyalty_tier?: string;
  achievements: BadgeRecord[];
  history: CheckinRecord[];
}

export interface RegisterResponse {
  user_id: string;
  token: string;
}

export interface StreakResponse {
  current_streak: number;
  best_streak: number;
  today_checked: boolean;
}

export interface StatsResponse {
  total_users: number;
  today_checkins: number;
  active_today: number;
}

export interface AchievementResponse {
  achievements: BadgeRecord[];
}

// ============================================================
// 排行榜查询参数
// ============================================================

export type LeaderboardType = 'weekly' | 'monthly' | 'alltime';

// ============================================================
// 徽章定义
// ============================================================

export const BADGE_DEFINITIONS: Record<string, { name: string; description: string }> = {
  first_checkin:    { name: '初次打卡', description: '完成首次打卡' },
  streak_7:         { name: '连续7天', description: '连续打卡7天' },
  streak_30:        { name: '连续30天', description: '连续打卡30天' },
  streak_100:       { name: '连续100天', description: '连续打卡100天' },
  perfect_sets_10:  { name: '完美十组', description: '累计10次完美组打卡（reps ≥ 15）' },
  score_100:        { name: '积分100', description: '累计积分达到100' },
  score_500:        { name: '积分500', description: '累计积分达到500' },
};

// ============================================================
// 等级与积分阈值
// ============================================================

export const LEVEL_THRESHOLDS: { level: string; min_score: number }[] = [
  { level: '王者', min_score: 2000 },
  { level: '钻石', min_score: 1000 },
  { level: '铂金', min_score: 600 },
  { level: '黄金', min_score: 300 },
  { level: '白银', min_score: 100 },
  { level: '青铜', min_score: 0 },
];

export function computeLevel(score: number): string {
  for (const tier of LEVEL_THRESHOLDS) {
    if (score >= tier.min_score) return tier.level;
  }
  return '青铜';
}

// ============================================================
// 排名算法（单次打卡分值）
// ============================================================
//   base_score      = sets_completed × 10
//   streak_bonus    = streak × 5
//   perfect_bonus   = (reps_per_set >= 15 ? 5 : 0)
//   total           = base_score + streak_bonus + perfect_bonus

export function computeCheckinScore(sets: number, streak: number, reps: number): number {
  const base = sets * 10;
  const streakBonus = streak * 5;
  const perfectBonus = reps >= 15 ? 5 : 0;
  return base + streakBonus + perfectBonus;
}

// ============================================================
// 忠诚度等级
// ============================================================

export const LOYALTY_TIERS = ['F', 'E', 'D', 'C', 'B', 'A', 'S', 'SS'] as const;
export type LoyaltyTier = typeof LOYALTY_TIERS[number];

export const LOYALTY_THRESHOLDS: Record<LoyaltyTier, number> = {
    'SS': 5000,
    'S': 3000,
    'A': 2000,
    'B': 1000,
    'C': 500,
    'D': 200,
    'E': 50,
    'F': 0
};

// 根据积分计算忠诚度等级
export function computeLoyaltyTier(score: number): string {
    const tiers = Object.entries(LOYALTY_THRESHOLDS) as [LoyaltyTier, number][];
    let tier: LoyaltyTier = 'F';
    for (const [t, threshold] of tiers) {
        if (score >= threshold && LOYALTY_THRESHOLDS[t] >= LOYALTY_THRESHOLDS[tier]) {
            tier = t;
        }
    }
    return tier;
}
