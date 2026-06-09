# CHANGELOG

本文档记录所有值得注意的变更，格式基于 [Keep a Changelog](https://keepachangelog.com/)。

---

## [v1.0.0] — 2026-06-08

### 新增

#### 四大健康提醒模块
- **久坐提醒** (`scripts/sedentary.sh`)：基于 WHO 2020 指南和 Yin 2024 元分析的 30 分钟间隔提醒，支持三级策略（信号型/火花型/促进型），连续久坐 120 分钟硬上限。
- **用眼提醒** (`scripts/eye-care.sh`)：基于 Johnson & Rosenfield 2023、超日节律 90 分钟和注意力子周期 50 分钟的频率，集成远眺（>6m）+ 有意识眨眼（15 次）动作指导。
- **喝水提醒** (`scripts/hydration.sh`)：基于 NASEM/EFSA/中国营养学会三源交叉验证，75 分钟间隔、单次 200mL、09:00-18:00 时段、持续运行模式。
- **凯格尔训练** (`scripts/kegel.sh`)：基于 Cochrane 2024 (63 RCT/4,920 人)、Cleveland Clinic 和 NIH/NIDDK 指导，提供四阶段进阶方案（初学者→过渡→标准→巩固），隐私模式默认开启。

#### 调度与运行时
- `scripts/scheduler.sh`：统一后台守护进程，独立计时器管理四大模块提醒，集成心流检测联动、频道适配分发的完整调度循环。
- `scripts/vita`：CLI 入口，提供 start/stop/status/config/log/test/setup/leaderboard/version 共 9 个子命令。
- `scripts/install.sh`：交互式安装向导，支持目录创建、默认配置复制、个性化提醒间隔设置、打榜昵称设置、Shell alias 添加、LaunchAgent/systemd 开机自启配置。

#### 心流适配系统
- `scripts/flow-detector.sh`：基于进程启发式的心流状态判定，预设高专注应用列表，四级判定（none/light/medium/deep），对应延迟倍率 1.0x/1.5x/2.5x/4.0x，通知风格映射为 normal/normal/gentle/subtle。

#### 自适应引擎
- `scripts/adaptive-engine.sh`：忠诚度评分系统（0-100），根据用户的完成 (+10)/忽略 (-5)/延迟 (-3) 响应动态调整提醒频率，评分影响间隔乘数 (0.6x-1.5x)，支持钻石/黄金/白银/青铜四级段位。

#### 多通道通知
- `scripts/channel-adapter.sh`：按优先级分发通知到桌面弹窗、终端回显、TTS 语音、静默日志四个通道，支持 log_only 安全模式。

#### 智能抑制
- 安静时段检测（23:00-07:00 → 仅日志）
- 会议检测（摄像头使用中 → 静默）
- 锁屏检测（ScreenSaverEngine → 暂停）
- 用户空闲检测（>5 分钟无键盘鼠标活动 → 暂停）

#### 打榜 PK 系统
- `leaderboard/`：完整 Cloudflare Workers + D1 + KV 实现
  - 12 个 REST API 端点：注册、打卡、排行榜、用户列表、用户详情、连胜记录、成就列表、全局统计、PK 挑战发起、挑战列表、挑战详情、健康检查
  - 四层防作弊体系：HMAC 签名验证、频率限制、时间窗口校验、异常检测
  - 隐私保护：伪匿名 ID、部分掩码、可选匿名模式、可选公开排行榜退出
  - 忠诚度等级定义（SS/S/A/B/C/D/E/F，schema + types 已定义，运行时积分更新待 v0.2.0 集成）与 7 种成就徽章
- `scripts/lib/leaderboard-client.sh`：客户端库，处理 API 调用、离线队列、自动重试
- `scripts/lib/nickname-validator.sh`：客户端昵称校验（长度 2-20、字符约束、敏感词过滤）

#### 配置系统
- `config/default.yaml`：126 行默认配置，覆盖四大模块参数、打榜设置、守护进程参数、心流适配参数、多通道配置、智能抑制规则、自适应引擎参数
- `config/schema.yaml`：JSON Schema Draft-07，对所有配置字段提供类型约束、范围限制和格式校验

#### 科学依据与文档
- `references/health-guidelines.md`：四大模块完整健康参数速查表，标注独立来源数与置信度，45+ 独立来源的交叉验证矩阵
- `sedentary-research.md`、`eye-care-research.md`、`hydration-research.md`、`kegel-research.md`、`leaderboard-research.md`、`skills-spec-research.md`：各领域研究文献综述

#### 测试
- `tests/test-scheduler.sh`：8 个测试模块（配置加载、模块触发、智能抑制、频道通知、心流检测、自适应引擎、调度器语法、CLI 语法），45+ 个断言
- `leaderboard/tests/api.test.sh`：打榜 API 端点测试

### 设计原则
- 所有参数默认值均基于独立发表、经过同行评议的 ≥3 个独立来源交叉验证
- 优先修改现有文件、最小化新建（符合项目 "只改不增" 原则）
- 渐进式信息披露架构：SKILL.md（第1层）→ README（第2层）→ references/（第3层）
- 隐私优先：凯格尔默认隐私模式、打榜支持匿名与退出、昵称 AI 合规审查
