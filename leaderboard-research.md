# 提肛锻炼打榜 PK 系统 — 技术方案调研报告

> 调研时间：2026-06-08 13:30 ~ 13:45 +08:00 (Asia/Singapore)
> 调研人：Comdr 香草少校
> 状态：完成

---

## 一、时间真实性校验记录

| 项目 | 详情 |
|------|------|
| 校验时间 | 2026-06-08 13:30:54 +08:00 ~ 2026-06-08 13:31:01 +08:00 |
| 本机系统时间 | 2026-06-08 13:30:54 +08:00 (Asia/Singapore) |
| 时间源 1 | https://www.google.com — HTTP Date: `Mon, 08 Jun 2026 05:30:58 GMT` → 2026-06-08 13:30:58 +08:00 |
| 时间源 2 | https://www.cloudflare.com — HTTP Date: `Mon, 08 Jun 2026 05:31:01 GMT` → 2026-06-08 13:31:01 +08:00 |
| 最大偏差 | ~7 秒（阈值 100 秒） |
| 判定 | **通过** |

---

## 二、GitHub 方案详细分析

### 2.1 架构概述

使用 GitHub 生态作为打榜系统的全部基础设施：

- **数据存储**：GitHub Issues 作为打卡数据记录（每条打卡 = 一个 Issue）
- **排名计算**：GitHub Actions 定时任务（Cron）抓取并计算排名
- **榜单展示**：GitHub Pages 托管静态排行榜站点
- **身份认证**：GitHub OAuth / GitHub 用户名

### 2.2 技术实现路径

#### 数据层：GitHub Issues as Database

已有成熟的社区实践，将 GitHub Issues 用作结构化数据存储：

| 方案 | 工具 | 描述 |
|------|------|------|
| Issues CMS | `@ga-ut/gh-db` | 将 Issues 封装为 CRUD 操作的数据存储库 |
| Issues CMS | `gatsby-theme-blog-with-github` | Gatsby 插件，用 Issue 作为内容源 |
| Issues CMS | Next.js + `@octokit/graphql` | 使用 GraphQL API 查询 Issues |
| Issues CMS | `svelte-git-cms` | SvelteKit + Webhook 实现实时同步 |

**打卡记录模型示例**：
```json
{
  "user": "github-username",
  "date": "2026-06-08",
  "sets": 3,
  "reps_per_set": 20,
  "duration_seconds": 180,
  "timestamp": "2026-06-08T13:30:00+08:00",
  "hash": "abc123..."
}
```
Issue 标签系统: `check-in`, `verified`, `streak-15`

#### 计算层：GitHub Actions Cron

参考实现：**CS2 Leaderboard with Antigravity & GitHub Actions**（dev.to, 2024）

```
Cron Schedule (GitHub Actions)
  → Python/Node.js 脚本通过 GitHub API 拉取所有 Issues
  → 计算排名（累计天数/连续天数/总分）
  → 更新 data.json / leaderboard.json 到仓库
  → 构建 React/Vite 静态站点
  → 部署到 GitHub Pages
```

参考实现：**oscomp-grading**（LearningOS 仓库）— 使用 GitHub Actions 每小时刷新学生排名排行榜。

#### 展示层：GitHub Pages

- 纯静态站点（HTML/CSS/JS）
- 数据通过预生成的 JSON 文件注入
- 每次 Actions 运行后自动更新
- 自定义域名 + 免费 HTTPS（Let's Encrypt）

### 2.3 GitHub 方案优劣势

#### 优势

| 维度 | 详情 |
|------|------|
| **零成本** | 全部在免费 tier 内：GitHub Issues（无限）、Actions（2000 分钟/月公开仓库）、Pages（1GB 存储 + 100GB 带宽/月） |
| **公开透明** | 所有打卡记录公开可见，任何人都能审计排名变化，天然防止后台篡改 |
| **Git 版本控制** | 每次排名更新都有 commit 历史，可追溯任意历史时刻的排名状态 |
| **社区可见** | 项目本身吸引关注，GitHub Star/Watch/Fork 形成额外社交激励 |
| **零基础设施** | 无需管理服务器、数据库、域名（可选），维护成本极低 |
| **开发简单** | 一套 Node.js/Python 脚本即可，无需学习新平台 |
| **跨平台接入** | Claude Code/Cherry Studio/Codex 等 AI 工具均原生支持 GitHub API 调用 |

#### 劣势

| 维度 | 详情 |
|------|------|
| **API 频率限制** | 未认证：60 次请求/小时；已认证（OAuth Token）：5,000 次请求/小时。大规模用户时可能成为瓶颈 |
| **隐私问题（致命缺陷）** | **GitHub Issues 在公开仓库中完全公开可见**。提肛锻炼涉及个人健康行为数据，即使脱敏（用 GitHub 用户名），仍有隐私风险。Git 历史永久保留，删除操作无法真正抹除记录 |
| **写入延迟** | GitHub API 写入非实时（~1-3 秒延迟），高频打卡场景有延迟感 |
| **依赖 GitHub 平台** | 平台故障/政策变更将直接影响系统可用性 |
| **不支持实时交互** | 静态页面刷新后才有最新排名（取决于 Actions 调度频率，最多 5 分钟一次） |
| **前端功能受限** | 仅静态 JS，无法实现实时推送、WebSocket 等特性 |
| **安全风险** | 个人资料/Secret 意外泄露到公开仓库（已有真实事故案例，如 Lobster #794） |

#### GitHub 免费 Tier 关键限制

| 资源 | 限制 |
|------|------|
| API 请求 | 60/小时（未认证），5,000/小时（认证） |
| Actions 运行时间 | 2,000 分钟/月（公开仓库） |
| Pages 存储 | 1 GB |
| Pages 带宽 | 100 GB/月（软限制） |
| Pages 构建 | 10 次/小时 |
| Issues 数量 | 无明确上限（但大量 Issues 会减慢 API 查询） |

---

## 三、Cloudflare 方案详细分析

### 3.1 架构概述

使用 Cloudflare 生态构建打榜系统：

- **数据存储**：Cloudflare D1（边缘 SQLite）/ Workers KV（键值存储）/ Durable Objects（有状态计算单元）
- **计算层**：Cloudflare Workers（边缘函数，全球 330+ 节点）
- **榜单展示**：Cloudflare Pages（静态站点，类似 GitHub Pages）
- **身份认证**：Cloudflare Access / 自建 JWT

### 3.2 存储方案三选一

| 维度 | D1 (SQLite Edge) | Workers KV | Durable Objects |
|------|-------------------|------------|-----------------|
| **数据模型** | 关系型 SQL | 键值对 | 任意 JS 对象 |
| **读写特性** | 读快（全球复制）/ 写最终一致 | 读极快（边缘）/ 写最终一致（≤60s 全局传播） | 强一致性 |
| **查询能力** | 完整 SQL（JOIN/GROUP BY/排序） | 仅键查询 | 自定义 JS 逻辑 |
| **适合场景** | 复杂排名查询（按总分、连续天数排序） | 用户偏好、计数器、简单状态 | 实时对战、WebSocket 连接管理 |
| **免费额度** | 500 万读/天、10 万写/天、5GB 存储 | 10 万读/天、1,000 写/天、1GB 存储 | 按请求计费 |
| **延迟** | 读 < 10ms（边缘）/ 写 ~50-100ms | 读 < 1ms（边缘）/ 写 ~1-10ms | < 10ms |
| **ORM 支持** | Drizzle ORM / Prisma | 无 | 无 |

**对于打榜系统，D1 是最佳选择**：
- 需要 SQL 排序和聚合：`SELECT user, SUM(sets) as total FROM checkins GROUP BY user ORDER BY total DESC`
- 需要分页：`LIMIT ? OFFSET ?` 配合 `COUNT(*)`
- 免费额度足够：500 万读/天远超小规模打卡系统的需求

参考案例：dev.to 开发者使用 Cloudflare Pages + Workers + D1 + R2 构建零成本全球 Web 应用（Slitherlinks 拼图游戏），D1 存储 1,900 条谜题和用户排行榜数据。

### 3.3 Cloudflare 方案优劣势

#### 优势

| 维度 | 详情 |
|------|------|
| **极致低延迟** | 全球 330+ 边缘节点，亚洲用户访问 < 20ms |
| **数据私密** | 可以设置访问控制，数据不公开。适合健康行为这种敏感数据 |
| **实时性好** | Workers 可以支持 WebSocket + Durable Objects 实现实时排名更新 |
| **扩展性强** | 从免费 Tier 到付费无缝扩展，无需架构变更 |
| **全栈支持** | Workers 可运行完整 JS/TS 逻辑，支持 npm 包 |
| **Pages 体验好** | Cloudflare Pages 与 GitHub 集成，自动构建部署 |
| **30 天时间旅行** | D1 支持 30 天时间点恢复（Point-in-Time Recovery） |
| **防 DDoS** | Cloudflare 自带 DDoS 保护 |

#### 劣势

| 维度 | 详情 |
|------|------|
| **学习曲线** | 需要学习 Wrangler CLI、Workers 运行时、D1 SQL 方言 |
| **免费额度较低（KV 写入）** | KV 每日仅 1,000 次写入，高频打卡场景可能不够（但 D1 写入 10 万/天够用） |
| **D1 写入延迟** | D1 写入是最终一致性，全局同步有短暂延迟 |
| **平台绑定** | 相比 GitHub 更深的平台绑定，迁移成本高 |
| **开发调试复杂** | 本地开发需要 Wrangler，线上调试工具有限 |
| **社区资源少** | 相比 GitHub Actions 生态，D1 的教程和开源案例少很多 |

#### Cloudflare 免费 Tier 关键限制

| 服务 | 免费额度 |
|------|---------|
| Workers 请求 | 100,000/天 |
| Workers CPU | 10ms/调用 |
| KV 读取 | 100,000/天 |
| KV 写入 | 1,000/天（不同键） |
| KV 存储 | 1 GB |
| D1 读取 | 5,000,000/天 |
| D1 写入 | 100,000/天 |
| D1 存储 | 5 GB |
| Pages 构建 | 500 次/月 |
| Pages 带宽 | 无限制 |
| Cron 触发器 | 5 个/账户 |

---

## 四、综合对比表

| 维度 | GitHub Issues + Actions + Pages | Cloudflare D1 + Workers + Pages |
|------|-------------------------------|--------------------------------|
| **成本** | 完全免费（公开仓库） | 免费 Tier 足够小规模使用 |
| **隐私保护** | **极差** — 数据完全公开，Git 历史不可删除 | **好** — 可设置私有/认证访问 |
| **读延迟** | 静态文件 < 50ms（CDN） | 边缘读 < 10ms |
| **写延迟** | GitHub API ~1-3 秒 | D1 写入 ~50-100ms |
| **实时更新** | 不支持（需等 Actions 运行） | Workers WebSocket 可实时推送 |
| **排名查询** | 预计算 JSON + 前端排序 | SQL 实时查询 |
| **开发复杂度** | 简单（GitHub 生态熟悉） | 中等（Wrangler + D1 学习） |
| **防作弊** | 依赖 Issues 的开放性（公众监督） | 可服务器端校验签名 |
| **数据迁移性** | 好（JSON 格式，Git 导出） | 中（SQLite dump） |
| **跨平台接入** | GitHub API 通用 | HTTP API 通用 |
| **可扩展性** | 受限于 API 频率 / Actions 时长 | Workers 自动扩展 |
| **社区案例** | 多（CS2 Leaderboard、oscomp-grading） | 少（零星开源项目） |
| **合规风险** | GDPR 问题：健康数据在公开仓库 | 可控：数据在隔离账户中 |

---

## 五、推荐方案及理由

### 首选方案：Cloudflare D1 + Workers + Pages

**推荐理由**（按优先级排序）：

1. **隐私优先（决定性因素）**
   提肛锻炼是个人健康行为。即使用 GitHub 用户名匿名化，公开 Issues 存储的打卡记录仍属敏感数据。GitHub 历史永久保留特性（即使后续删除 Issue，commit 历史仍可检索）带来不可逆的隐私风险。Cloudflare 方案天然支持私有化部署，数据仅对认证用户可见。

2. **实时体验**
   Workers WebSocket + Durable Objects 可以实现实时排名变化推送，比 GitHub Actions 的 5-15 分钟延迟定时排名更有游戏化体验。

3. **全球低延迟**
   亚洲用户（主要目标区域）通过 Cloudflare 边缘网络获得 < 20ms 响应，远优于 GitHub Pages 的 CDN 分发。

4. **免费 Tier 足够**
   100,000 Worker 请求/天 + 5,000,000 D1 读取/天 — 即使 1,000 日活用户仍绰绰有余。

5. **排名查询灵活**
   D1 SQL 支持复杂排序和聚合，无需预计算。

### 备选方案：GitHub Issues + Actions + Pages

适用场景：
- 完全公开透明的打卡社区（用户明确接受数据公开）
- 快速原型验证（开发速度优先于隐私）
- 项目规模极小（< 50 人），依靠公众监督防作弊

---

## 六、打榜机制设计建议

### 6.1 隐私与匿名设计（重要）

参考 NCAT-CTRL-ALT-DELETE 项目的伪匿名架构和 UC Berkeley 的隐私感知运动应用：

| 措施 | 说明 |
|------|------|
| **伪匿名标识** | 用户 ID 使用 `sha256(用户密钥)` 生成，不暴露 GitHub 用户名或邮箱 |
| **部分掩码显示** | 排行榜显示 `a1b2****c3d4` 格式，只有用户本人可认出自己的完整 ID |
| **Opt-in 榜单** | 用户主动选择是否出现在公开排行榜，默认仅自己可见 |
| **最小化数据收集** | 仅存储排名所需的聚合数据（总次数、连续天数），不存储每次打卡的详细健康元数据 |
| **数据存续策略** | 提供数据导出和删除功能 |

### 6.2 防作弊机制

| 层级 | 措施 | 说明 |
|------|------|------|
| **L1: 提交签名** | 每次打卡附带 HMAC 签名 | 服务器用用户密钥验证，防止伪造请求 |
| **L2: 频率限制** | 每日打卡上限 3-5 次 | 防止脚本刷榜 |
| **L3: 时间窗口** | 打卡间隔 >= 30 分钟 | 防止短时间内重复打卡 |
| **L4: 异常检测** | 连续打卡时间戳异常检测 | 如每次打卡精确间隔 30 分 0 秒，判定为机器人 |
| **L5: 社交验证（可选）** | 好友可"见证"打卡 | 类似 Strava 的 AI 反作弊系统 |

参考：Strava 2024 年引入 AI 工具检测虚假活动记录（来源：lifehacker.com.au）。

### 6.3 排名算法

```
综合评分 = 总打卡次数 * 1.0 + 连续天数 * 2.0 + 总组数 * 0.5 + 成就徽章 * 10

排名类型：
- 总榜：累计综合评分
- 周榜：本周综合评分
- 连胜榜：当前连续打卡天数
- 爆发榜：单日最大打卡组数
```

（权重可由社区通过投票调整）

### 6.4 社交激励设计

基于游戏化行为研究：

| 机制 | 设计 |
|------|------|
| **连胜记录** | "你已连续 7 天打卡" — 中断的损失厌恶是强激励 |
| **成就徽章** | "初出茅庐"（7天）、"月度冠军"（30天）、"铁腚传奇"（100天）、"极限挑战"（500天） |
| **PK 挑战** | 用户可向特定好友发起 7 天 PK 赛，胜者获得额外徽章 |
| **等级系统** | 青铜 -> 白银 -> 黄金 -> 铂金 -> 钻石 -> 王者 |
| **匿名"天梯"** | 用户看到自己在全部用户中的百分位排名（"你超越了 73% 的提肛战士"） |
| **日报生成** | 每日自动生成打卡战报（可分享的图片卡片） |

来源依据：
- UC Berkeley / Cal Poly 研究：竞争（排行榜）对高风险患者锻炼激励有效
- 游戏化行为设计中的"损失厌恶"原则（Kahneman & Tversky）

### 6.5 跨平台接入

系统通过标准 HTTP API 暴露接口，任何 AI 工具均可接入：

```
POST /api/checkin        — 提交打卡
GET  /api/leaderboard    — 获取排行榜
GET  /api/stats/{userId} — 获取个人统计
GET  /api/badges/{userId}— 获取徽章列表
```

Claude Code / Codex / Cherry Studio 的 Skill 可以通过 fetch/curl 调用这些 API。

---

## 七、可信来源清单

| # | 来源 | URL | 类型 | 发布日期 | 检索时间 +08:00 |
|---|------|-----|------|---------|-----------------|
| 1 | Cloudflare Workers 免费 Tier 指南 (dev.to) | https://dev.to/ioniacob/which-cloudflare-services-are-free-2025-free-tier-guide-53jl | 社区文章 | 2025 | 2026-06-08 13:32 |
| 2 | Cloudflare D1 官方产品页 | https://www.cloudflare.com/products/d1/ | 官方文档 | 持续更新 | 2026-06-08 13:35 |
| 3 | Cloudflare D1 综合指南 (agentskills.so) | https://agentskills.so/zh/skills/ovachiever-droid-tings-cloudflare-d1 | 技术指南 | 2024-2025 | 2026-06-08 13:35 |
| 4 | Cloudflare 零成本全栈架构 (dev.to) | https://dev.to/ansonchan/the-zero-cost-stack-building-a-global-web-app-with-cloudflare-free-tier-49oi | 社区文章 | 2024 | 2026-06-08 13:35 |
| 5 | Cloudflare Workers 免费 Tier 详情 (Freetiers.com) | https://www.freetiers.com/directory/cloudflare-workers | 第三方统计 | 2025 | 2026-06-08 13:33 |
| 6 | CS2 Leaderboard with GitHub Actions (dev.to) | https://dev.to/ibrahimsezer/how-i-built-a-high-performance-cs2-leaderboard-using-antigravity-github-actions-31o7 | 社区文章 | 2024 | 2026-06-08 13:33 |
| 7 | oscomp-grading — GitHub Actions 排行榜 (LearningOS) | https://github.com/LearningOS/oscomp-grading | 开源项目 | 2024 | 2026-06-08 13:33 |
| 8 | GitHub Pages 免费 Tier 详情 (Freetiers.com) | https://www.freetiers.com/directory/github-pages | 第三方统计 | 2025 | 2026-06-08 13:36 |
| 9 | @ga-ut/gh-db — Issues as Database (npm) | https://www.npmjs.com/package/@ga-ut/gh-db | 开源库 | 2024 | 2026-06-08 13:34 |
| 10 | GitHub Issues as CMS (dev.to) | https://practicaldev-herokuapp-com.global.ssl.fastly.net/abdulrcs/unleash-your-dev-blog-write-more-with-github-issues-as-your-cms-1g5c | 社区文章 | 2024 | 2026-06-08 13:34 |
| 11 | 开源项目数据保护讨论 (Springer) | https://link.springer.com/article/10.1007/s10664-025-10742-x | 学术论文 | 2025 | 2026-06-08 13:37 |
| 12 | 伪匿名排行榜架构 (GitHub NCAT-CTRL-ALT-DELETE) | https://github.com/NCAT-CTRL-ALT-DELETE/Vulnerability-Game/issues/57 | 开源设计 | 2024 | 2026-06-08 13:36 |
| 13 | 隐私感知运动 App 研报 (UC Berkeley) | https://ptolemy.berkeley.edu/projects/truststc/education/reu/12/Posters/Grant_Ibssa_Poster.pdf | 学术海报 | 2023 | 2026-06-08 13:36 |
| 14 | Strava AI 反作弊系统 (Lifehacker AU) | https://au.lifehacker.com/fitness/114281/news/how-strava-is-using-ai-tools-to-crack-down-on-cheaters | 新闻 | 2024 | 2026-06-08 13:34 |
| 15 | Cloudflare Workers 官方文档 — 限制 | https://cloudflare-docs-7ou.pages.dev/workers/platform/limits/ | 官方文档 | 持续更新 | 2026-06-08 13:33 |
| 16 | Cloudflare Workers KV 官方定价 | https://developers.cloudflare.com/kv/platform/pricing/ | 官方文档 | 持续更新 | 2026-06-08 13:33 |
| 17 | Claude 插件注册表 (Kamalnrf) | https://github.com/Kamalnrf/claude-plugins | 开源项目 | 2025-2026 | 2026-06-08 13:35 |
| 18 | Skillrank 基准测试系统 | https://www.npmjs.com/package/skillrank | npm 包 | 2025-2026 | 2026-06-08 13:35 |

---

## 八、下一步建议

1. **立即决策**：确认是否认同"隐私优先"判断，选定 Cloudflare D1 方案
2. **原型开发**：
   - 使用 Wrangler CLI 初始化项目
   - 设计 D1 数据库 Schema（用户表、打卡表、徽章表）
   - 实现 `/api/checkin` 和 `/api/leaderboard` 两个核心端点
3. **防作弊实现**：HMAC 签名验证中间件
4. **前端榜单**：Cloudflare Pages + 轻量框架（React/Vanilla JS）
5. **测试计划**：单元测试（Workers 测试框架 Miniflare）+ 端到端测试
6. **数据迁移预案**：定期导出 D1 数据到 R2/本地备份
