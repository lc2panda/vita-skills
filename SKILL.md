---
name: vita-health
description: 香草健康管理 — 久坐/用眼/喝水/提肛锻炼智能提醒系统，集成心流自适应、多通道通知和全球打榜PK。通过后台调度守护自然嵌入工作流，无需安装独立App。
license: MIT
compatibility: claude-code, codex, cherry-studio, windsurf, cursor, pandacc, and 40+ agent-skills platforms
metadata:
  version: 1.0.0
  author: 香草少校
allowed-tools: bash, read, write
---

# 香草健康管理（Vita Health Manager）

基于 AI Agent Skills 协议的跨平台健康提醒系统，面向知识工作者（程序员、设计师、内容创作者）设计。通过后台调度守护进程 (`scripts/scheduler.sh`) 自然嵌入工作流，在用户专注编码时自动触发健康提醒——不装 App、不切窗口、不失焦。

**核心入口**：`scripts/vita` — 统一 CLI，提供 start/stop/status/config/log/test/setup/leaderboard/version 等命令。

## 四大提醒模块

### 1. 久坐提醒 — `sedentary.sh`
- **默认间隔**：30 分钟
- **科学依据**：*The Lancet* 元分析（Ekelund 2016，9 项前瞻性研究），每日久坐 >8h 者全因死亡风险升高 59% (HR=1.59)；Yin 2024 元分析（7 项 RCT/451 人）证实每 30 分钟中断久坐显著降低餐后血糖 (SMD=-0.33)
- **提醒策略**：三级递进——信号型（善意提醒）→ 火花型（动机激发）→ 促进型（简易动作引导），基于 Fogg 行为模型
- **硬上限**：连续久坐 120 分钟强制提醒
- **状态查询**：`bash scripts/sedentary.sh --status`

### 2. 用眼提醒 — `eye-care.sh`
- **默认间隔**：50 分钟
- **科学依据**：Johnson & Rosenfield 2023 系统综述，超日节律 90 分钟（Kleitman BRAC），注意力子周期 50 分钟
- **动作指导**：远眺 6 米外（松弛睫状肌）+ 有意识眨眼 15 次（重建泪膜）
- **统计查询**：`bash scripts/eye-care.sh --status`

### 3. 喝水提醒 — `hydration.sh`
- **默认间隔**：75 分钟
- **单次建议**：200mL
- **科学依据**：NASEM/EFSA/中国营养学会三源交叉验证；Wittbrodt 2018 证实 1-2% 脱水即损害注意力与执行功能
- **时间窗口**：09:00-18:00，持续运行模式
- **进度查询**：`bash scripts/hydration.sh --status`

### 4. 提肛训练 — `tigang.sh`
- **默认频率**：每日 3 次
- **科学依据**：Cochrane 2024 系统综述（63 RCT/4,920 人），PFMT 为尿失禁一线推荐疗法 (RR=8.38)；Cleveland Clinic + NIH/NIDDK 临床指导
- **训练方案**：两阶段进阶——初学者（2组/天，10次/组，保持3-5s）→ 进阶（3组/天，15次/组，保持5-10s），config 预留 transition/standard 四阶段扩展位
- **隐私保护**：默认启用 `privacy_mode`，使用含蓄文案保护用户隐私
- **支持男女两性**：gender-aware 差异化指导

## 核心架构

### 调度守护 — `scripts/scheduler.sh`
独立计时器管理四大模块提醒周期，集成心流检测、频道适配和自适应引擎的完整调度循环。由 `vita start` 命令启动后台运行。

### 心流检测 — `scripts/flow-detector.sh`
- **检测方式**：基于进程名称的启发式判定（预设高专注应用列表：Xcode、Terminal、VSCode、IntelliJ IDEA 等）
- **四级判定**：
  - none（无）→ 正常提醒，延迟 1.0x
  - light（轻）→ 正常提醒，延迟 1.5x
  - medium（中）→ 温和通知，延迟 2.5x
  - deep（深）→ 微妙通知，延迟 4.0x
- **联动调度器**：scheduler.sh 每次触发前调用 flow-detector.sh 判定当前状态

### 自适应引擎 — `scripts/adaptive-engine.sh`
- **评分系统**：0-100 忠诚度评分，初始 50
- **响应驱动**：完成 +10 / 忽略 -5 / 延迟 -3
- **频率调节**（基于 config/default.yaml multipliers）：
  - 0-29 → 1.5x 加速提醒
  - 30-59 → 1.0x 正常频率
  - 60-79 → 0.8x 适度放宽
  - 80-100 → 0.6x 低频提醒
- **五级段位**（代码实现）：iron (0-29) / bronze (30-59) / silver (60-79) / gold (80-94) / diamond (95-100)

### 多通道通知 — `scripts/channel-adapter.sh`
按优先级分发：桌面弹窗 → 终端回显 → TTS 语音 → 静默日志。当桌面环境不可用时自动降级至 log_only 安全模式。

### 智能抑制 — `scripts/lib/suppression.sh`（由 common.sh 懒加载）
- 安静时段 (23:00-07:00) → 仅日志
- 会议中（摄像头使用）→ 静默
- 锁屏 → 暂停
- 用户空闲 >5 分钟 → 暂停

## 安装与配置

### 首次安装

```bash
cd scripts
bash install.sh interactive
```

安装向导交互流程：目录创建 → 默认配置复制 → 个性化间隔设置 → 打榜昵称设置 → Shell alias 添加 → 开机自启配置。

### 启动守护

```bash
vita start
```

### 配置文件

默认配置：`config/default.yaml`（128 行，涵盖四大模块/打榜/守护/心流/通道/抑制/自适应全部参数）
用户配置：`~/.vita/config/config.yaml`（安装向导自动生成）
Schema 校验：`config/schema.yaml`（JSON Schema Draft-07）

编辑配置：
```bash
vita config edit
```

## 命令参考

| 命令 | 说明 |
|------|------|
| `vita start` | 启动后台调度守护 |
| `vita stop` | 停止守护进程 |
| `vita status` | 运行状态 + 今日统计 + 忠诚度评分 |
| `vita config` | 查看当前配置 |
| `vita config edit` | 编辑配置文件 |
| `vita log [N]` | 查看最近 N 条日志 |
| `vita test` | 发送所有模块测试通知 |
| `vita setup` | 重新运行安装向导 |
| `vita leaderboard` | 查看打榜排名与连续打卡天数 |

命令行入口：`scripts/vita`（bash 脚本，9 个子命令）

## 打榜 PK 系统

### 服务端 — `leaderboard/`
基于 Cloudflare Workers + D1 + KV 实现：
- **7 个 REST API 端点**：注册、打卡、排行榜、统计、挑战发起、挑战详情、徽章列表
- **防作弊**：HMAC 签名验证、频率限制 (3 req/s)、时间窗口校验、异常检测
- **隐私**：伪匿名 ID、部分掩码、可选匿名模式、可选退出排行榜、完整导出/删除
- **成本**：完全覆盖在 Cloudflare 免费 Tier 内（预估月用量远低于免费额度）
- **详见**：`leaderboard/API.md`、`leaderboard/README.md`

### 客户端 — `scripts/lib/leaderboard-client.sh`
处理 API 调用、签名生成、离线队列和自动重试。由 `tigang.sh` 和 `install.sh` 集成调用。

## 共享库 — `scripts/lib/`

| 文件 | 职责 |
|------|------|
| `common.sh` | 公共工具（日志/配置/通知/心流检测/状态管理） |
| `leaderboard-client.sh` | 打榜 API 客户端 |

其余脚本（flow-detector、channel-adapter、adaptive-engine）的权威实现已合并到 `scripts/` 顶层目录。

## 测试

```bash
bash tests/test-scheduler.sh        # 8 模块集成测试，45+ 断言
bash leaderboard/tests/api.test.sh  # 打榜 API 端点测试
vita test                           # 端到端通知测试
```

## 科学依据

所有默认参数均基于独立发表、经过同行评议的科学文献，每个参数至少 3 个独立来源交叉验证。

| 核心结论 | 独立来源数 | 代表性来源 |
|---------|-----------|-----------|
| 久坐 >8h/d 增加 59% 全因死亡风险 | 3+ | *The Lancet* Ekelund 2016 (HR=1.59, 95%CI 1.52-1.66) |
| 每 30 分钟中断久坐为最佳间隔 | 4+ | *Scand J Med Sci Sports* Yin 2024 (SMD=-0.33, 95%CI -0.59 to -0.07) |
| 20-20-20 规则缓解数字眼疲劳 | 4+ | Johnson & Rosenfield 2023 systematic review |
| 1-2% 脱水即损害注意力与执行功能 | 5+ | *Med Sci Sports Exerc* Wittbrodt 2018 meta-analysis |
| PFMT 为尿失禁一线疗法 (RR=8.38) | 3+ | *Cochrane* Dumoulin 2024 (63 RCT/4,920 participants) |
| 渐进式提醒比固定频率更有效 | 2+ | Fogg Behavior Model, Hydroprompt 2016 |

**完整科学依据、来源编号与交叉验证矩阵**详见 `references/health-guidelines.md`（45+ 独立来源）。各领域研究文献综述见根目录 `sedentary-research.md`、`eye-care-research.md`、`hydration-research.md`、`tigang-research.md`。

## 子代理协作模式

当嵌入 AI Agent Skills 平台运行时，本 Skill 使用以下子代理分工：

- **调度子代理**：运行 `scripts/scheduler.sh`，负责计时器管理与触发分发
- **检测子代理**：运行 `scripts/flow-detector.sh`，判定当前心流等级
- **提醒子代理**：运行 `scripts/sedentary.sh` / `eye-care.sh` / `hydration.sh` / `tigang.sh`，生成并发送提醒
- **适配子代理**：运行 `scripts/adaptive-engine.sh`，根据用户响应更新评分
- **打榜子代理**：通过 `scripts/lib/leaderboard-client.sh` 上报打卡数据

子代理间通过 state 文件 (`~/.vita/state/`) 共享状态，调度器负责协调生命周期。

## 安装指引（AI 可读）

如果用户尚未安装此 Skill，请读取仓库根目录下的 README.md 头部 `<!-- ... -->` 注释块，其中包含完整的 8 步安装闭环指令。
