# Vita Leaderboard

Cloudflare Workers + D1 + KV 排行榜服务。

## 前置条件

- **Node.js** >= 18.0.0
- **Wrangler CLI** >= 3.0.0（`npm install -g wrangler`）
- **Cloudflare 账号**（注册于 https://dash.cloudflare.com/sign-up）

## 安装

```bash
cd leaderboard
npm install
```

## 数据库初始化

```bash
# 1. 创建 D1 数据库（首次）
npm run db:create

# 2. 运行 schema 迁移
npm run db:migrate

# 3. （可选）填充种子数据
npm run db:seed
```

## 本地开发（仅调试，生产环境使用 Cloudflare Worker 全球排行榜）

```bash
npm run dev
# 默认监听 http://localhost:8787
```

Wrangler 会自动绑定本地 D1 和 KV 模拟环境。

## 部署到生产

```bash
npm run deploy
```

首次部署前需在 `wrangler.toml` 中将 `database_id` 和 KV `id` 替换为 `wrangler d1 create` 和 `wrangler kv:namespace create` 输出的实际 ID。

## 成本估算

| 资源 | 免费 Tier | 月预估用量 | 费用 |
|------|----------|-----------|------|
| Workers 请求 | 10M/月 | < 1M | $0 |
| D1 存储 | 5 GB | < 10 MB | $0 |
| D1 读行 | 5B/月 | < 100K | $0 |
| KV 读 | 10M/月 | < 500K | $0 |
| KV 存储 | 1 GB | < 1 MB | $0 |

**结论**：免费 Tier 完全覆盖预期用量。
