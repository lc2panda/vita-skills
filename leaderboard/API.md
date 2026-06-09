# 打榜 PK 系统 API 规格

> 基线设计文档: 香草健康管理skills设计.md §4.3
> 最后更新: 2026-06-09 18:05:30 +08:00 (Asia/Singapore)

BASE URL: `https://vita-leaderboard.imladrisel.workers.dev`

---

## 认证方式

系统使用两种认证方式：

| 认证类型 | 用途 | Header |
|---------|------|--------|
| Bearer Token | 用户身份认证（注册时返回 token） | `Authorization: Bearer <token>` |
| HMAC-SHA256 | 打卡防作弊签名 | `X-Signature` + `X-Timestamp` |

Bearer Token 在注册成功后一次性返回，请妥善保管。除健康检查、注册、排行榜、用户列表、用户详情、连胜记录、全局统计外，其余端点均需携带 `Authorization: Bearer <token>` 头。

HMAC-SHA256 签名用于打卡端点防作弊。签名算法：

```
X-Timestamp = 当前 Unix 秒时间戳（字符串）
X-Signature = HMAC-SHA256(token, "{request_body}{X-Timestamp}") → hex 字符串
```

---

## 端点 1: 健康检查

```
GET /api/health
```

无需认证。

**Response 200:**

```json
{
    "status": "ok",
    "timestamp": 1780999547
}
```

---

## 端点 2: 用户注册

```
POST /api/user/register
```

无需认证。

**Request Body:**

```json
{
    "display_name": "string (必填，2-20 字符)",
    "device_id": "string (必填，设备唯一标识)"
}
```

**Response 200:**

```json
{
    "user_id": "0c7d7fb1-4271-4618-bd27-74d47d1a241a",
    "token": "957ec4f522d704e15c6dd64bdfff716e0b5e56a85c982e550407663282fcd28c"
}
```

| 字段 | 说明 |
|------|------|
| `user_id` | 用户 UUID，全局唯一标识 |
| `token` | Bearer Token（64 字符十六进制），用于后续认证 |

**错误响应 400:**

```json
{
    "error": "display_name and device_id are required"
}
```

---

## 端点 3: 每日打卡

```
POST /api/checkin
```

**Headers:**
- `Authorization: Bearer <token>` (required)
- `Content-Type: application/json` (required)
- `X-Signature` (required, HMAC-SHA256 hex 签名)
- `X-Timestamp` (required, Unix 秒时间戳字符串)

**Request Body:**

```json
{
    "sets": 1,
    "reps_per_set": 10,
    "duration": 5
}
```

**防作弊校验（服务端）:**

| 层级 | 检查项 | 拒绝条件 |
|------|--------|---------|
| L1 | HMAC 签名 | 签名不匹配 → 401 |
| L2 | 时间戳偏移 | \|server_time - X-Timestamp\| > 300 秒 → 401 |
| L3 | 频率限制 | 距上次打卡 < 1800 秒 → 429 |
| L4 | 每日上限 | 当日 checkin >= 3 次 → 429 |

**Response 200:**

```json
{
    "success": true,
    "today_total_sets": 3,
    "streak_days": 1,
    "total_score": 10
}
```

**Response 401 (签名验证失败):**

```json
{
    "error": "unauthorized"
}
```

---

## 端点 4: 排行榜

```
GET /api/leaderboard?type=weekly|monthly&limit=N&offset=M
```

无需认证。

**Query Parameters:**

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `type` | string | `weekly` | `weekly`（周榜）或 `monthly`（月榜） |
| `limit` | integer | 20 | 返回条数，1-100 |
| `offset` | integer | 0 | 分页偏移 |

**Response 200:**

```json
[
    {
        "id": "da763a83-2e4f-48ee-bd61-f4ba9ec3ecf5",
        "rank": 1,
        "name": "Comdr_香草",
        "score": 90,
        "streak": 0,
        "level": "青铜",
        "loyalty_score": 0,
        "loyalty_tier": "F"
    },
    {
        "id": "e972d845-9275-4a9c-b156-49922f6905fa",
        "rank": 2,
        "name": "test_user",
        "score": 25,
        "streak": 0,
        "level": "青铜",
        "loyalty_score": 0,
        "loyalty_tier": "F"
    }
]
```

| 字段 | 说明 |
|------|------|
| `id` | 用户 UUID |
| `rank` | 排名（从 1 开始） |
| `name` | 显示名称 |
| `score` | 当前榜单得分 |
| `streak` | 连续打卡天数 |
| `level` | 等级（青铜/白银/黄金/钻石） |
| `loyalty_score` | 忠诚度分数（0-100） |
| `loyalty_tier` | 忠诚度段位（F/E/D/C/B/A/S/SS） |

---

## 端点 5: 用户列表

```
GET /api/users
```

无需认证。

**Response 200:**

```json
[
    {
        "id": "da763a83-2e4f-48ee-bd61-f4ba9ec3ecf5",
        "display_name": "Comdr_香草",
        "score": 90,
        "streak": 0,
        "level": "青铜",
        "loyalty_score": 0,
        "loyalty_tier": "F"
    }
]
```

---

## 端点 6: 用户详情

```
GET /api/user/:id
```

无需认证。

**:id** — 用户 UUID（注册时返回的 `user_id`）。

**Response 200:**

```json
{
    "name": "DocTest",
    "score": 0,
    "streak": 0,
    "level": "bronze",
    "loyalty_score": 0,
    "loyalty_tier": "F",
    "achievements": [],
    "history": []
}
```

| 字段 | 说明 |
|------|------|
| `name` | 显示名称 |
| `score` | 总积分 |
| `streak` | 当前连续打卡天数 |
| `level` | 等级（bronze/silver/gold/diamond） |
| `loyalty_score` | 忠诚度分数 |
| `loyalty_tier` | 忠诚度段位 |
| `achievements` | 已获得成就列表 |
| `history` | 打卡历史记录 |

---

## 端点 7: 连胜记录

```
GET /api/user/:id/streak
```

无需认证。

**Response 200:**

```json
{
    "current_streak": 0,
    "best_streak": 0,
    "today_checked": false
}
```

| 字段 | 说明 |
|------|------|
| `current_streak` | 当前连续打卡天数 |
| `best_streak` | 历史最佳连续打卡天数 |
| `today_checked` | 今日是否已打卡 |

---

## 端点 8: 成就列表

```
GET /api/achievements/:user_id
```

需要认证：`Authorization: Bearer <token>`

**Response 200:**

```json
{
    "achievements": []
}
```

**Response 200（有成就时）:**

```json
{
    "achievements": [
        {
            "type": "streak_7",
            "name": "初出茅庐",
            "description": "连续打卡 7 天",
            "awarded_at": 1780500000
        }
    ]
}
```

---

## 端点 9: 全局统计

```
GET /api/stats
```

无需认证。

**Response 200:**

```json
{
    "total_users": 4,
    "today_checkins": 5,
    "active_today": 3
}
```

| 字段 | 说明 |
|------|------|
| `total_users` | 注册用户总数 |
| `today_checkins` | 今日打卡总次数 |
| `active_today` | 今日活跃用户数 |

---

## 端点 10: 发起 PK 挑战

```
POST /api/challenge
```

需要认证：`Authorization: Bearer <token>`

**Request Body:**

```json
{
    "opponent_id": "e972d845-9275-4a9c-b156-49922f6905fa",
    "duration_days": 7
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `opponent_id` | string | 对手用户 UUID |
| `duration_days` | integer | 挑战持续时间（天） |

**Response 200:**

```json
{
    "id": "8ad979a1-d930-4e15-8b7b-78451e524287",
    "challenger_id": "0c7d7fb1-4271-4618-bd27-74d47d1a241a",
    "opponent_id": "e972d845-9275-4a9c-b156-49922f6905fa",
    "status": "accepted",
    "start_date": "2026-06-09T10:07:51.671Z",
    "end_date": "2026-06-16T10:07:51.671Z",
    "created_at": "2026-06-09T10:07:51.671Z"
}
```

| 字段 | 说明 |
|------|------|
| `id` | 挑战 UUID |
| `challenger_id` | 发起方用户 UUID |
| `opponent_id` | 对手用户 UUID |
| `status` | 挑战状态（accepted/completed/cancelled） |
| `start_date` | 开始时间（ISO 8601） |
| `end_date` | 结束时间（ISO 8601） |
| `created_at` | 创建时间（ISO 8601） |

---

## 端点 11: 用户挑战列表

```
GET /api/challenges
```

需要认证：`Authorization: Bearer <token>`

返回当前用户参与的所有挑战。

**Response 200:**

```json
[
    {
        "id": "8ad979a1-d930-4e15-8b7b-78451e524287",
        "challenger_id": "0c7d7fb1-4271-4618-bd27-74d47d1a241a",
        "opponent_id": "e972d845-9275-4a9c-b156-49922f6905fa",
        "status": "accepted",
        "challenger_score": 0,
        "opponent_score": 0,
        "winner_id": null,
        "start_date": "2026-06-09T10:07:51.671Z",
        "end_date": "2026-06-16T10:07:51.671Z",
        "created_at": "2026-06-09T10:07:51.671Z",
        "challenger_name": "DocTest",
        "opponent_name": "test_user"
    }
]
```

| 字段 | 说明 |
|------|------|
| `challenger_score` | 发起方积分 |
| `opponent_score` | 对手积分 |
| `winner_id` | 胜方 UUID（挑战中为 null） |
| `challenger_name` | 发起方显示名称 |
| `opponent_name` | 对手显示名称 |

---

## 端点 12: 挑战详情

```
GET /api/challenge/:id
```

需要认证：`Authorization: Bearer <token>`

**Response 200:**

```json
{
    "id": "8ad979a1-d930-4e15-8b7b-78451e524287",
    "challenger_id": "0c7d7fb1-4271-4618-bd27-74d47d1a241a",
    "opponent_id": "e972d845-9275-4a9c-b156-49922f6905fa",
    "status": "accepted",
    "challenger_score": 0,
    "opponent_score": 0,
    "winner_id": null,
    "start_date": "2026-06-09T10:07:51.671Z",
    "end_date": "2026-06-16T10:07:51.671Z",
    "created_at": "2026-06-09T10:07:51.671Z",
    "challenger_name": "DocTest",
    "opponent_name": "test_user"
}
```

---

## 通用错误码

| 状态码 | 含义 |
|--------|------|
| 200 | 成功 |
| 400 | 请求参数缺失或格式错误 |
| 401 | 未认证或签名验证失败 |
| 404 | 资源不存在 |
| 429 | 频率限制 |
| 500 | 服务器内部错误 |

---

## 速率限制

| 端点 | 限制 | 窗口 |
|------|------|------|
| POST /api/user/register | 10 次 | 每 IP 每小时 |
| POST /api/checkin | 3 次 | 每用户每天 |
| GET /api/leaderboard | 60 次 | 每 IP 每分钟 |
| GET /api/users | 60 次 | 每 IP 每分钟 |
| POST /api/challenge | 10 次 | 每用户每天 |
| 其他 GET | 120 次 | 每 IP 每分钟 |
