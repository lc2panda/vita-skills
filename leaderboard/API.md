# 打榜 PK 系统 API 规格

> 基线设计文档: 香草健康管理skills设计.md §4.3  
> 最后更新: 2026-06-08 15:30:00 +08:00 (Asia/Singapore)

BASE URL: `https://api.vanilla-health.dev`

所有请求 (除 `POST /api/register`) 必须在 Header 中携带认证信息.

---

## 认证方式

| Header | 说明 |
|--------|------|
| `X-User-Id` | 注册时返回的 user_id（伪匿名 SHA-256 哈希） |
| `X-Signature` | 请求体的 HMAC-SHA256 签名，密钥为注册时返回的 api_key |

签名算法: `HMAC-SHA256(api_key, request_body)` → hex 字符串

---

## 端点 1: 用户注册

```
POST /api/register
```

**Request Body:**

```json
{
  "display_name": "string (2-20 字符，通过合规校验 §4.9)",
  "device_fingerprint": "string (设备指纹 SHA-256 哈希 §4.9.3)",
  "stage": "string (可选，默认 'beginner')",
  "privacy_mode": "string (可选，默认 'public'，可选 'anonymous')"
}
```

**Response 201:**

```json
{
  "user_id": "a1b2c3d4e5f6... (SHA-256 哈希)",
  "api_key": "sk_v1_xxxx... (API Key 妥善保管)",
  "display_name": "用户昵称",
  "masked_id": "a1b2****e5f6 (排行榜显示用 §4.7)"
}
```

**校验流程 (服务端，§4.9.1):**

1. 长度校验: 2-20 字符
2. 字符校验: 允许 CJK/拉丁/数字/下划线/短横线，禁止纯数字/纯符号/空白开头结尾
3. 敏感词匹配: 政治人物人名库 + 通用敏感词库
4. AI 合规审查: LLM 判定（通过/拒绝 + 理由）
5. 唯一性校验: display_name + device_fingerprint 组合绑定

**错误响应 422:**

```json
{
  "error": "invalid_display_name",
  "reason": "昵称包含违规内容",
  "suggestions": ["建议昵称1", "建议昵称2"]
}
```

---

## 端点 2: 每日打卡

```
POST /api/checkin
```

**Headers:**
- `X-User-Id` (required)
- `X-Signature` (required, HMAC of body)

**Request Body:**

```json
{
  "sets": 3,
  "reps_per_set": 10,
  "duration": 5,
  "device_id": "device_hash",
  "client_ip_hash": "ip_hash"
}
```

**防作弊校验 (服务端，§4.4):**

| 层级 | 检查项 | 拒绝条件 |
|------|--------|---------|
| L1 | HMAC 签名 | 签名不匹配 → 403 |
| L2 | 频率限制 | 当日 checkin_count >= 3 → 429 |
| L3 | 时间窗口 | 距上次打卡 < 1800 秒 → 429 |
| L4 | 异常检测 | 时间戳标准差 < 1 秒 → 403 |
| L5 | 组数上限 | 单次 sets > 3 或当日累计 > 9 → 422 |

**Response 200:**

```json
{
  "success": true,
  "today_total_sets": 9,
  "streak_days": 7,
  "total_score": 156,
  "new_badges": ["streak_7"],
  "level": "intermediate",
  "loyalty_tier": "SS"
}
```

**Response 429 (频率限制):**

```json
{
  "error": "rate_limited",
  "reason": "每日最多打卡 3 次，您今日已完成 3 次",
  "retry_after": "2026-06-09T00:00:00+08:00"
}
```

---

## 端点 3: 排行榜查询

```
GET /api/leaderboard?type=total&period=week&limit=20&offset=0
```

**Query Parameters:**

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `type` | string | `total` | total / streak / burst（爆发） |
| `period` | string | `week` | day / week / month / all |
| `limit` | integer | 20 | 1-100 |
| `offset` | integer | 0 | 分页偏移 |

**Response 200:**

```json
{
  "period": "week",
  "type": "total",
  "generated_at": 1780903850,
  "rankings": [
    {
      "rank": 1,
      "masked_id": "a1b2****c3d4",
      "display_name": "匿名战士",
      "total_score": 520,
      "streak_days": 30,
      "level": "advanced",
      "badge_count": 5
    }
  ],
  "user_rank": 42
}
```

**隐私说明 (§4.7):**
- `privacy_mode=anonymous` 的用户仅显示 `masked_id`，不显示 `display_name`
- `opt_in_leaderboard=false` 的用户不出现在排行榜中，但 `user_rank` 仍返回相对排名
- 所有 ID 均使用部分掩码格式: 前 4 字符 + `****` + 后 4 字符

---

## 端点 4: 个人统计

```
GET /api/stats/{userId}
```

**Response 200:**

```json
{
  "user_id": "a1b2c3d4e5f6...",
  "display_name": "匿名战士",
  "joined_at": 1780000000,
  "stats": {
    "total_sets": 450,
    "total_days": 60,
    "streak_days": 7,
    "best_streak": 21,
    "total_score": 520,
    "level": "advanced",
    "loyalty_score": 78.5,
    "loyalty_tier": "SS"
  },
  "badges": [
    {
      "type": "streak_7",
      "name": "初出茅庐",
      "awarded_at": 1780500000
    },
    {
      "type": "perfect_week",
      "name": "完美一周",
      "awarded_at": 1780800000
    }
  ],
  "percentile": 73,
  "level_progress": {
    "current": 520,
    "next_level": "elite",
    "points_needed": 1480
  }
}
```

---

## 端点 5: 发起 PK 挑战

```
POST /api/challenge
```

**Headers:**
- `X-User-Id` (required)
- `X-Signature` (required)

**Request Body:**

```json
{
  "opponent_id": "b2c3d4e5f6a7...",
  "duration_days": 7
}
```

**Response 201:**

```json
{
  "challenge_id": 42,
  "challenger_id": "a1b2c3d4e5f6...",
  "opponent_id": "b2c3d4e5f6a7...",
  "start_date": "2026-06-08",
  "end_date": "2026-06-15",
  "status": "active"
}
```

**错误响应:**

```json
{
  "error": "challenge_exists",
  "reason": "已存在与同一对手的进行中挑战"
}
```

---

## 端点 6: 挑战详情

```
GET /api/challenge/{challengeId}
```

**Response 200:**

```json
{
  "challenge_id": 42,
  "status": "completed",
  "challenger": {
    "user_id": "a1b2****e5f6",
    "display_name": "战士A",
    "score": 35
  },
  "opponent": {
    "user_id": "b2c3****f6a7",
    "display_name": "战士B",
    "score": 42
  },
  "start_date": "2026-06-01",
  "end_date": "2026-06-08",
  "winner_id": "b2c3d4e5f6a7..."
}
```

---

## 端点 7: 用户徽章列表

```
GET /api/badges/{userId}
```

**Response 200:**

```json
{
  "user_id": "a1b2c3d4e5f6...",
  "badges": [
    {
      "type": "streak_7",
      "name": "初出茅庐",
      "description": "连续打卡 7 天",
      "awarded_at": 1780500000
    },
    {
      "type": "streak_30",
      "name": "月度冠军",
      "description": "连续打卡 30 天",
      "awarded_at": null,
      "locked": true
    }
  ],
  "total_earned": 1,
  "total_available": 10
}
```

---

## 通用错误码

| 状态码 | 含义 |
|--------|------|
| 200 | 成功 |
| 201 | 创建成功 |
| 400 | 请求参数错误 |
| 401 | 未认证 (缺少 X-User-Id) |
| 403 | 签名验证失败 / 疑似作弊 |
| 404 | 资源不存在 |
| 422 | 参数校验失败 (含拒绝理由和建议) |
| 429 | 频率限制 (含 retry_after) |
| 500 | 服务器内部错误 |

---

## 速率限制

| 端点 | 限制 | 窗口 |
|------|------|------|
| POST /api/register | 5 次 | 每 IP 每小时 |
| POST /api/checkin | 3 次 | 每用户每天 |
| GET /api/leaderboard | 60 次 | 每 IP 每分钟 |
| GET /api/stats | 30 次 | 每用户每分钟 |
| POST /api/challenge | 5 次 | 每用户每天 |
| 其他 GET | 120 次 | 每 IP 每分钟 |
