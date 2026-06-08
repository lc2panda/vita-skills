# Vita Skills -- .pandacc 体系适配

## 概述

Vita Skills（香草健康管理）已适配 Panda CLI (.pandacc) 体系。通过软链接方式集成，无需复制文件，保持单一源。

## 集成机制

### 1. Skills 目录集成

```
~/.pandacc/skills/vita-health  ->  /path/to/vita-skills
```

`.pandacc` 的 skill loader 通过 SKILL.md 元数据识别技能。软链接创建后，Panda CLI 可直接加载 vita-health 技能及其子代理定义。

### 2. CLI 命令集成

```
~/.pandacc/bin/vita  ->  /path/to/vita-skills/scripts/vita
```

将 `vita` 命令链接到 `.pandacc/bin/`，配合 PATH 配置可在终端直接调用。

### 3. PATH 自动配置

安装脚本自动检测 shell 类型（zsh/bash），在对应 profile 文件（`.zshrc`/`.bashrc`/`.profile`）中追加：

```bash
export PATH="$HOME/.pandacc/bin:$PATH"
```

## 安装步骤

### 自动安装（推荐）

在任意安装模式下，install.sh 会自动检测 `.pandacc` 存在并执行集成：

```bash
cd /path/to/vita-skills/scripts
bash install.sh auto
```

或交互式：

```bash
bash install.sh interactive
```

### 独立 .pandacc 集成安装

如果已经完成基础安装，仅需补装 .pandacc 集成：

```bash
bash /path/to/vita-skills/scripts/pandacc-install.sh
source ~/.zshrc  # 或 ~/.bashrc，使 PATH 生效
```

### 手动安装

```bash
# 创建 skills 软链接
ln -s /path/to/vita-skills ~/.pandacc/skills/vita-health

# 创建 bin 软链接
ln -s /path/to/vita-skills/scripts/vita ~/.pandacc/bin/vita

# 追加 PATH（可选）
echo 'export PATH="$HOME/.pandacc/bin:$PATH"' >> ~/.zshrc
```

## 使用方式

集成完成后，可通过以下任一方式使用 vita：

```bash
# 通过 .pandacc/bin（需 source profile 或使用绝对路径）
vita start
vita status
vita test

# 通过原始安装路径
/path/to/vita-skills/scripts/vita status

# 通过 skills 软链接
~/.pandacc/skills/vita-health/scripts/vita status
```

## 验证安装

```bash
# 运行集成测试
bash /path/to/vita-skills/tests/test-pandacc.sh

# 手动检查
ls -la ~/.pandacc/skills/vita-health
ls -la ~/.pandacc/bin/vita
~/.pandacc/bin/vita version
```

## Panda CLI Channel 集成

`.pandacc/channels/` 目录下的飞书/微信等 channel 可与 vita 的通知系统协作。

### 通知联动

vita 的多通道通知（`scripts/channel-adapter.sh`）支持的通道类型：

| 优先级 | 通道 | .pandacc 关联 |
|--------|------|---------------|
| 1 | 桌面弹窗 (osascript) | 独立于 .pandacc |
| 2 | 终端回显 | 独立于 .pandacc |
| 3 | TTS 语音 | 独立于 .pandacc |
| 4 | 静默日志 (~/.vita/logs/) | 独立于 .pandacc |

如需通过 Panda CLI channel（如飞书）发送健康提醒，可在 `config/default.yaml` 中配置 `channels` 段，指向 `.pandacc/channels/` 对应的适配器。

### 子代理协作

`.pandacc/agents/` 下的代理定义（如 `triage.md`、`code-generator.md`）可与 vita-health 的五大子代理（调度、检测、提醒、适配、打榜）协同工作。SKILL.md 中声明的子代理通过 `scripts/` 下的脚本实现，`.pandacc` skill loader 可自动发现并调度。

## 卸载

```bash
# 移除软链接（不删除源文件）
rm ~/.pandacc/skills/vita-health
rm ~/.pandacc/bin/vita

# 移除 PATH 配置（手动编辑 ~/.zshrc 或 ~/.bashrc）
# 删除以 "# Panda CLI .pandacc 集成 (vita-skills)" 开头的行
```

## 技术说明

- **软链接优先**：遵循 `.pandacc/skills/` 既有一致风格（现有 wps-excel、feishu-calendar 等均为软链接）
- **幂等安装**：`pandacc-install.sh` 可安全重复执行，不会产生重复条目
- **零依赖增量**：不引入新的系统依赖，所有操作限于文件系统软链接和 shell profile 文本追加
- **向后兼容**：不影响非 `.pandacc` 用户的正常安装和使用
