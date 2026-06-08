---
name: vita-health
description: 香草健康管理 — 久坐/用眼/喝水/提肛锻炼智能提醒，支持心流适配与打榜PK。在Claude Code/Codex等AI编码助手中自然触发健康提醒，无需安装独立App。
license: MIT
compatibility: claude-code, codex, cherry-studio, windsurf, cursor, and 40+ agent-skills platforms
metadata:
  version: 1.0.0
  author: 香草少校
allowed-tools: bash, read, write
---

# 香草健康管理（Vanilla Health Manager）

香草健康管理是一套基于 AI Agent Skills 协议的跨平台健康提醒系统，面向知识工作者（程序员、设计师、内容创作者）设计。通过嵌入 AI 编码助手的 Skills 机制，在用户与 AI 协作的过程中自然触发健康提醒——不装 App、不切窗口、不失焦。

四大模块覆盖了久坐、用眼、饮水和盆底锻炼四个知识工作者最易忽视的健康维度，每个提醒参数均有顶级医学期刊/权威机构来源支撑。

## 四大提醒模块

### 1. 久坐提醒（sedentary）
默认每 30 分钟提醒起身活动，最低中断 2 分钟。基于 *The Lancet* 元分析（Ekelund 2016）：每日久坐超过 8 小时且活动水平最低的人群，全因死亡风险升高 59%（HR=1.59）。采用三级递进提醒策略（信号型→火花型→促进型），基于 Fogg 行为模型。

### 2. 用眼提醒（eye-care）
默认每 50 分钟提醒远眺 60 秒。改良自经典 20-20-20 规则，融合超日节律研究与注意力科学，在打断频率与眼保护效果之间折中。引导用户远眺 6 米外 + 有意识眨眼 15 次以重建泪膜。

### 3. 喝水提醒（hydration）
默认每 75 分钟提醒饮水 200mL，每日总目标男性 2000mL、女性 1600mL（基于 NASEM/EFSA/中国营养学会三源交叉验证）。含进度反馈机制——研究证实进度反馈效果优于简单提示（Hydroprompt 2016）。

### 4. 提肛锻炼提醒（kegel）
每日 3 次提醒盆底肌训练（PFMT），分阶段方案从初学者（3s 保持）到巩固期（10s 保持）。基于 Cochrane 2024 系统综述——PFMT 为尿失禁一线推荐疗法。提醒文案使用含蓄表述保护用户隐私。支持男女两性特定指导。

## 心流适配与强提醒机制

在 Vibe Coding 场景下，健康提醒采取渐进式策略：

- **心流检测**：通过多维度信号（输入活跃度、代码变更速率、窗口焦点等）综合判定用户是否处于心流状态。
- **渐进提醒**：未在心流中 → 标准弹窗；心流中 <30 分钟 → 温和 Toast；30-60 分钟 → 状态栏文字；>60 分钟 → 半透明 Overlay + AI 上下文暂存。
- **AI 托管过渡**：触发强提醒后，AI 自动暂存当前任务上下文，用户选择休息/推迟/跳过，休息结束后自动恢复上下文。

## 安装与配置

```bash
# 方式 1：npx skills add（通用，兼容 40+ 平台）
npx skills add <repo-url>

# 方式 2：Claude Code Marketplace
/plugin marketplace add <repo-url>
/plugin install vanilla-health-skills@vanilla-health

# 方式 3：手动 symlink（Claude Code）
ln -s /path/to/vanilla-health-skills/skills/health-sedentary ~/.claude/skills/health-sedentary
```

配置文件位于 `config/default.yaml`，用户可覆盖至 `~/.vanilla-health/config.yaml`：

```yaml
health-eye-care:
  enabled: true
  interval_minutes: 50
  break_seconds: 60
```

## 使用示例

在 Claude Code 对话中自然触发：

> 用户："写一个排序算法"
> （AI 正常工作...）
> （约 50 分钟后自动触发）→ "已连续注视屏幕约 50 分钟。休息眼睛 | 远眺 6 米外 | 眨眼 15 次"

用户亦可主动调用：
- `/health-sedentary status` — 查看久坐统计
- `/health-eye-care` — 立即触发用眼休息引导
- `/health-hydration stats` — 查看今日饮水进度
- `/health-kegel begin` — 开始一次凯格尔训练

## 打榜 PK 系统

基于 Cloudflare D1 + Workers + Pages 的隐私优先打榜系统：

- **伪匿名排行**：用户 ID 为 `sha256(user_secret)`，排行榜显示部分掩码
- **防作弊**：5 层机制（HMAC 签名验证、频率限制、时间窗口、异常检测、组数上限）
- **社交激励**：连胜记录、成就徽章、等级系统、匿名天梯、7 天 PK 赛
- **隐私保护**：Opt-in 排行榜、数据导出/删除 API、最小化数据采集

## 科学依据

本产品的每个参数均源自顶级医学期刊与权威机构：

| 核心结论 | 独立来源数 | 代表性来源 |
|---------|-----------|-----------|
| 久坐 >8h/d 增加 59% 全因死亡风险 | 3 | *The Lancet* Ekelund 2016 |
| 每 30 分钟中断久坐为最佳间隔 | 4 | *Scand J Med Sci Sports* Yin 2024 |
| 1-2% 脱水即损害注意力与执行功能 | 5 | *Med Sci Sports Exerc* Wittbrodt 2018 |
| PFMT 为尿失禁一线疗法 | 3 | *Cochrane* Hay-Smith 2024 |

完整科学依据及来源编号详见 `references/health-guidelines.md`。
