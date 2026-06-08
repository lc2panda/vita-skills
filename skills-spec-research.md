# Skills 编写规范与平台兼容性调研报告

> 检索基准时间：2026-06-08 13:30:54 +08:00 (Asia/Singapore)
> 时间校验状态：通过（Google/Cloudflare 双源，最大偏差 6 秒，阈值 100 秒）
> 检索时间范围：2026-06-08 13:31:00 ~ 2026-06-08 13:35:00 +08:00

---

## 一、调研摘要

本报告调研了当前（2026年6月）主流 AI 编码助手的 Skills 编写规范，覆盖 Claude Code、OpenAI Codex、Vercel agent-skills（通用标准）、Windsurf Cascade、Cursor Rules、GitHub Copilot Instructions 六大平台/生态。

**核心发现：**

1. **统一标准正在形成**：以 `SKILL.md`（YAML frontmatter + Markdown body）为基础的 Agent Skills 规范已被 Claude Code、OpenAI Codex、Vercel agent-skills 共同采纳，成为事实上的跨平台标准。
2. **Vercel agent-skills 是通用桥梁**：vercel-labs/agent-skills 提供跨 40+ 平台兼容的 SKILL.md 规范，npx skills CLI 可自动检测并安装到各 agent 对应目录。
3. **渐进式信息披露（Progressive Disclosure）**是核心设计模式：先加载元数据(~100 tokens)，按需加载完整指令(<5000 tokens)，详细资料从 references/ 目录按需读取。
4. **Claude Code 的 Skills 机制通过 Plugin Marketplace 分发**，目录位置为 `~/.claude/skills/`，与 Codex 的 `~/.agents/skills/` 不同但格式兼容。
5. **各平台差异主要在安装路径和触发机制**，而非文件格式。

---

## 二、各平台 Skills 规范对比表

### 2.1 核心格式对比

| 维度 | Claude Code | OpenAI Codex | Vercel agent-skills (通用) | Windsurf Cascade | Cursor Rules | GitHub Copilot |
|---|---|---|---|---|---|---|
| **文件格式** | SKILL.md (YAML frontmatter + MD) | SKILL.md (YAML frontmatter + MD) | SKILL.md (YAML frontmatter + MD) | .md (无 frontmatter) | .cursor/rules/*.mdc | .github/copilot-instructions.md |
| **元数据字段** | name, description | name, description, license, compatibility, metadata, allowed-tools | name (必须), description (必须), license, compatibility, metadata, allowed-tools | 无标准字段 | description, globs, alwaysApply | 无（纯 Markdown） |
| **目录结构** | .claude/skills/<name>/SKILL.md | .agents/skills/<name>/SKILL.md | <name>/SKILL.md + scripts/ + references/ + assets/ | .windsurf/rules/<name>.md | .cursor/rules/<name>.mdc | 单文件 |
| **脚本支持** | scripts/ 目录 | scripts/ 目录 | scripts/ 目录 | 无 | 无 | 无 |
| **参考资料** | references/ 目录 | references/ 目录 | references/ 目录 | 无 | 无 | 无 |

### 2.2 安装与触发机制

| 维度 | Claude Code | OpenAI Codex | Vercel agent-skills | Windsurf | Cursor | Copilot |
|---|---|---|---|---|---|---|
| **安装方式** | `/plugin marketplace add` 或 `/plugin install` | `$skill-installer` 或 `npx skills add` | `npx skills add <repo>` | 手动放置文件 | 手动放置文件 | 手动放置文件 |
| **发现位置** | ~/.claude/skills/, .claude/skills/, marketplace | ~/.agents/skills/, .agents/skills/, /etc/codex/skills/ | 自动写入对应 agent 目录 | .windsurf/rules/ | .cursor/rules/ | .github/copilot-instructions.md |
| **触发方式** | 斜杠命令 + 自动匹配 description | `/skills` 命令 + 自动匹配 description | 取决于各平台 | 手动@mention / Always / Glob / AI自动 | 手动@mention / Always / Glob / AI自动 | 自动加载 |
| **Marketplace** | 有（anthropics/claude-plugins-official, community marketplace） | 有（openai/skills curated catalog, 社区 repos） | 有（skills.sh 公共目录，npx skills find） | 无 | 无 | 无 |
| **热加载** | 支持 | 需重启 Codex | 取决于各平台 | 支持 | 支持 | 支持 |

### 2.3 Claude Code 特有机制

- **Plugin 与 Skill 关系**：Plugin 是 Skills 的打包分发单位，一个 Plugin 可包含多个 Skills
- **官方 Marketplace**：`anthropics/claude-plugins-official`（28,274+ stars），`anthropics/skills`（官方示例 Skill 集）
- **安装命令**：`/plugin marketplace add anthropics/skills` → `/plugin install document-skills@anthropic-agent-skills`
- **CLAUDE.md 技巧**：CLAUDE.md 中的 `#` 前缀指令可作为全局持久 hack，但 Claude Code 同时支持 SKILL.md 格式的插件机制
- **Skills 发现位置**：`~/.claude/skills/`（用户级），项目 `.claude/skills/`（项目级）
- **已知问题**：Marketplace 安装的 Skills 可能不出现在斜杠命令自动补全中（GitHub issue #18949），可 symlink 到 `~/.claude/skills/` 解决
- **Skills 官方示例仓库**：`anthropics/skills` 提供 PDF/DOCX/XLSX/PPTX 文档处理、创意设计、企业工作流 Skills

### 2.4 Agent Skills 通用规范（Vercel 主导）

**仓库**：vercel-labs/agent-skills（20,500+ stars）

**核心理念**："一次编写，处处生效"——单一 SKILL.md 文件兼容 40+ AI Agent 平台。

**安装命令**：
```bash
npx skills add vercel-labs/agent-skills
```

**关键里程碑**：仓库中将 `CLAUDE.md` 重命名为 `AGENTS.md`（commit 20f4a04），以实现通用 agent 兼容。保留 `CLAUDE.md → AGENTS.md` 的 symlink 以维持 Claude Code 兼容性。

**已包含的 Skills**：
1. react-best-practices — 40+ 条最佳实践规则
2. web-design-guidelines — 100+ 条可访问性/性能/UX 规则
3. react-native-skills — 35+ 条 React Native 规则
4. composition-patterns — React 组件组合模式
5. vercel-deploy-claimable — Vercel 部署脚本 Skill

**发现服务**：
- skills.sh — 公开 Skill 目录和排行榜
- `npx skills find` — 交互式搜索
- RFC 8615 `/.well-known/skills/index.json` — 企业/组织内部 Skill 注册

---

## 三、SKILL.md 完整格式规范

### 3.1 最小文件结构

```
my-skill/
├── SKILL.md          # 必须：YAML frontmatter + Markdown body
├── scripts/          # 可选：可执行脚本（Python/Bash/JavaScript）
├── references/       # 可选：详细参考文档（按需加载）
├── assets/           # 可选：模板、图片、数据文件
└── agents/           # 可选：平台特定配置
    └── openai.yaml   # 仅 Codex：界面外观与依赖声明
```

### 3.2 SKILL.md Frontmatter 字段（Agent Skills 通用规范 v1）

| 字段 | 必须 | 类型/约束 | 说明 |
|---|---|---|---|
| `name` | **是** | 最长 64 字符，仅小写字母、数字、连字符，不能以连字符起始或结束，不能包含连续连字符（`--`），**必须与父目录名一致** | Skill 唯一标识符 |
| `description` | **是** | 最长 1024 字符，非空 | 描述 Skill 用途和触发条件，应包含 agent 可匹配的关键词 |
| `license` | 否 | 许可证名称或指向打包许可证文件 | 建议简短 |
| `compatibility` | 否 | 最长 500 字符 | 环境需求（目标产品、系统包、网络访问等） |
| `metadata` | 否 | 任意 key-value 映射（string → string） | 扩展元数据，key 应唯一避免冲突 |
| `allowed-tools` | 否 | 空格分隔的工具名称字符串 | **实验性**，预授权可使用的工具列表 |

### 3.3 命名规范

**有效示例**：`pdf-processing`, `data-analysis`, `code-review`, `react-best-practices`

**无效示例**：`PDF-Processing`（大写）、`-pdf`（以连字符开头）、`pdf--processing`（连续连字符）

### 3.4 Body 内容规范

- **无格式限制**：Markdown body 部分可自由编写
- **推荐结构**：分步骤指令、输入/输出示例、常见边界情况处理
- **长度限制**：建议 < 500 行；超过时拆分为 references/ 中的独立文件
- **文件引用**：使用从 Skill 根目录的相对路径，如 `references/REFERENCE.md`、`scripts/extract.py`
- **引用深度**：保持一级深度（从 SKILL.md 出发一层路由），避免深层嵌套引用链

### 3.5 渐进式信息披露（Progressive Disclosure）

```
第 1 层：元数据 (~100 tokens)
  所有 Skills 在 agent 启动时加载 name + description
  初始 Skill 列表上限：~8,000 字符（Codex）或模型上下文窗口 2%

第 2 层：完整指令 (< 5,000 tokens 推荐)
  SKILL.md body 在 Skill 被激活时完整加载

第 3 层：参考资料（按需）
  scripts/、references/、assets/ 中的文件仅在需要时加载
```

**设计原则**：用 description 帮助 agent 匹配场景，用 body 提供具体指令，将细节资料放入 references/ 节省上下文。

### 3.6 验证工具

```bash
# Agent Skills 验证工具
skills-ref validate ./my-skill

# 功能：检查 SKILL.md frontmatter 有效性和命名规范
# 参考库：github.com/agentskills/agentskills/tree/main/skills-ref
```

### 3.7 Codex 特有扩展：agents/openai.yaml

```yaml
interface:
  display_name: "My Skill"
  short_description: "Brief user-facing description"
  icon_small: icon.svg
  icon_large: icon-large.svg
  brand_color: "#3B82F6"
  default_prompt: "Surrounding prompt text"

policy:
  allow_implicit_invocation: true  # false 则禁止自动调用

dependencies:
  tools:
    - type: mcp
      value: server-name
      description: "What this MCP server provides"
      transport: stdio
      url: "https://example.com"
```

---

## 四、其他平台 Skills/Rules 机制

### 4.1 Windsurf Cascade Rules

**格式**：无 frontmatter 的纯 Markdown，或 XML 标记结构

**存储位置**：`.windsurf/rules/`

**激活模式（4 种）**：
1. **Manual**：通过 `@mention` 在对话中调用
2. **Always On**：始终生效，适合核心标准
3. **Model Decision**：AI 基于自然语言 description 判断
4. **Glob**：匹配文件模式时激活（如 `*.ts`、`src/**/*.js`）

**技术限制**：
- 单文件 ≤ 6,000 字符
- 总规则 ≤ 12,000 字符
- 全局规则优先于工作区规则

**规则编写建议**：
```xml
<coding_guidelines>
- 尽可能使用 early return
- 新函数和类必须添加文档
- 遵循项目命名约定
</coding_guidelines>
```

### 4.2 Cursor Rules

**格式**：`.cursor/rules/*.mdc` 文件

**关键字段**：
```yaml
---
description: "规则描述，AI 用于判断何时应用"
globs:
  - "*.ts"
  - "src/**/*.ts"
alwaysApply: false
---
# 规则内容（Markdown）
```

**激活模式**：与 Windsurf 类似（Manual / Always / Glob / Agent Decision）

### 4.3 GitHub Copilot Instructions

**格式**：单文件 `.github/copilot-instructions.md`（纯 Markdown，无 frontmatter）

**机制**：自动加载到 Copilot Chat 上下文中，无需手动触发

**适用**：GitHub Copilot 在 VS Code / JetBrains / GitHub.com 中的行为指令

---

## 五、Skills 设计模式与最佳实践

### 5.1 设计原则（综合多平台）

| 原则 | 说明 | 来源 |
|---|---|---|
| **单一职责** | 每个 Skill 只做一件事 | Codex 官方文档 + Agent Skills 规范 |
| **指令优先于脚本** | 大多数情况用指令优于脚本 | Codex 官方文档 |
| **祈使句风格** | 使用明确的步骤描述，含输入/输出 | Codex 官方文档 + 社区实践 |
| **关键词优化** | description 包含 agent 匹配场景所需关键词 | Codex 官方文档 |
| **长度控制** | SKILL.md < 500 行，详细资料放 references/ | Agent Skills 规范 + Codex 文档 |
| **测试描述** | 用真实提示词测试 description 匹配准确性 | Codex 官方文档 |
| **错误处理** | 脚本需自包含，含友好错误信息 | Agent Skills 规范 |
| **避免冗余** | description 要有足够区分度，避免与其他 Skill 混淆 | Codex 官方文档 |
| **可移植性** | 不依赖特定平台的内部机制，使用标准 SKILL.md 格式 | Vercel agent-skills |

### 5.2 推荐的 Skill 文件组织（项目级）

```
project/
├── .claude/
│   └── skills/           # Claude Code 本地 Skills
│       └── my-skill/
│           └── SKILL.md
├── .agents/
│   └── skills/           # Codex 本地 Skills
│       └── my-skill/
│           └── SKILL.md
├── .windsurf/
│   └── rules/            # Windsurf Rules
│       └── my-guidelines.md
├── .cursor/
│   └── rules/            # Cursor Rules
│       └── my-guidelines.mdc
├── .github/
│   └── copilot-instructions.md  # GitHub Copilot
└── AGENTS.md             # 通用 agent 指导文件（兼容 40+ 平台）
    └── CLAUDE.md → AGENTS.md    # Claude Code symlink
```

### 5.3 推荐跨平台策略

1. **核心 Skill 逻辑**：编写符合 Agent Skills 通用规范的 `SKILL.md`
2. **平台适配**：在 `agents/` 目录下添加平台特定配置（openai.yaml 等）
3. **分发**：使用 Vercel `npx skills` 或各平台 Marketplace 分发
4. **本地开发**：symlink 到各平台对应目录进行测试

### 5.4 成功 Skill 的 Description 编写指南

**优秀示例**：
> "Extracts text and tables from PDF files, fills PDF forms, and merges multiple PDFs. Use when working with PDF documents or when the user mentions PDFs, forms, or document extraction."

**不良示例**：
> "Helps with PDFs."

**关键要素**：
- 描述做什么（功能）
- 描述何时使用（触发条件）
- 包含具体关键词（PDF, forms, document extraction）

### 5.5 Community Skills 参考

| Skill 集 | 仓库 | 说明 |
|---|---|---|
| Superpowers | obra/superpowers | 完整 SDLC：planning → TDD → debugging → review → Git（社区最强者） |
| SkillIssue | daamitt/skill-issue | 跨 3 个 Marketplace 搜索 Skills（索引 52+ plugins, 100+ skills） |
| awesome-ai-agent-skills | seb1n/awesome-ai-agent-skills | 90+ 通用 Skills，覆盖 AI/ML、API、DevOps、Security 等 |
| awesome-skills | gmh5225/awesome-skills | 元列表，聚合各平台 Skills 资源 |
| codex-skills | am-will/codex-skills | Agent 编排（planner, llm-council）、前端设计、浏览器自动化 |
| infinite-skills | Infinite-Labs-OS/infinite-skills | 含 goal skill 的轻量集合 |
| claude-skills | alirezarezvani/claude-skills | 营销和业务运营 Skills |

---

## 六、可信来源清单（16 个来源）

所有来源检索时间均为 2026-06-08 13:31:00 ~ 13:35:00 +08:00。

### 官方/标准来源

| # | 来源 | URL | 类型 | 版本/日期 | 采用性 |
|---|---|---|---|---|---|
| 1 | Agent Skills 规范 (agentskills/agentskills) | https://github.com/agentskills/agentskills/blob/main/docs/specification.mdx | 标准 | v1, 2025 | **核心参考** |
| 2 | OpenAI Codex Skills 官方文档 | https://developers.openai.com/codex/skills | 官方文档 | 2025-2026 | **核心参考** |
| 3 | Vercel agent-skills 仓库 | https://github.com/vercel-labs/agent-skills | 官方仓库 | Commit 20f4a04, 2025 | **核心参考** |
| 4 | Vercel Skills 生态发布 | https://vercel.com/changelog/introducing-skills-the-open-agent-skills-ecosystem | 官方公告 | 2025 | **采用** |
| 5 | OpenAI Skills 官方仓库 | https://github.com/openai/skills | 官方仓库 | 2025-2026 | **核心参考** |
| 6 | Claude Code 插件市场文档 | https://code.claude.com/docs/en/discover-plugins | 官方文档 | 2025-2026 | **核心参考** |
| 7 | Claude Code 插件官方仓库 | https://github.com/anthropics/claude-plugins-official | 官方仓库 | 2025-2026 (28,274 stars) | **核心参考** |
| 8 | Claude Code 官方 Skills 仓库 | https://github.com/anthropics/skills | 官方仓库 | 2025-2026 | **核心参考** |

### 社区/实践来源

| # | 来源 | URL | 类型 | 版本/日期 | 采用性 |
|---|---|---|---|---|---|
| 9 | awesome-ai-agent-skills | https://github.com/seb1n/awesome-ai-agent-skills | 社区目录 | 2025-2026 (90+ skills) | **参考** |
| 10 | awesome-skills (gmh5225) | https://github.com/gmh5225/awesome-skills | 社区目录 | 2025-2026 | **参考** |
| 11 | Skills.sh 社区目录 | https://skywork.ai/clihub/keywords/skills.html | 公共目录 | 2025-2026 | **参考** |
| 12 | Claude Code Skills Market 指南 | https://skywork.ai/blog/claude-code-skills-market-ultimate-guide/ | 社区文章 | 2026 | **补充参考** |
| 13 | GitHub Copilot Instructions 规范 | https://docs.github.com/copilot/customizing-copilot/adding-custom-instructions | 官方文档 | 2025 | **参考** |
| 14 | Windsurf Cascade 指南 (Paradigma) | https://en.paradigmadigital.com/dev/windsurf-cascade-guide-best-practices/ | 社区文章 | 2025 | **参考** |
| 15 | Claude Code issue #18949 (Skills 自动补全) | https://github.com/anthropics/claude-code/issues/18949 | Issue | 2025 | **参考** |
| 16 | SKILL.Md 开源集合 (KraitDev) | https://github.com/KraitDev/skiLL.Md | 社区仓库 | 2025 | **参考** |

### 交叉验证矩阵（关键规范的独立确认）

| 规范项 | 来源 1 | 来源 2 | 来源 3 | 一致性 |
|---|---|---|---|---|
| SKILL.md 格式 (YAML frontmatter + MD body) | Agent Skills 规范 (1) | Codex 官方文档 (2) | Vercel agent-skills (3) | ✅ 一致 |
| name 字段约束（64字符/小写/连字符） | Agent Skills 规范 (1) | skills-ref 验证工具 (1) | — | ✅ 单一权威源 |
| 目录结构 (SKILL.md + scripts/ + references/ + assets/) | Agent Skills 规范 (1) | Codex 官方文档 (2) | Vercel agent-skills (3) | ✅ 一致 |
| Progressive Disclosure 机制 | Agent Skills 规范 (1) | Codex 官方文档 (2) | — | ✅ 一致 |
| 安装路径 (~/.claude/skills/ vs ~/.agents/skills/) | Claude Code 文档 (6) | Codex 官方文档 (2) | Vercel agent-skills (3) | ✅ 各平台路径不同但格式统一 |
| 隐式触发机制 (description 匹配) | Codex 官方文档 (2) | Windsurf 文档 (14) | Cursor Rules 规范 | ✅ 一致模式 |

---

## 七、设计建议

### 7.1 对当前项目的建议

1. **采用 Agent Skills 通用规范**作为 Skills 编写标准——这是 Claude Code、Codex 和 40+ 平台共同遵循的事实标准。

2. **文件结构建议**：
   ```
   skills/
   ├── AGENTS.md                     # 通用 agent 指导文件
   ├── my-skill/
   │   ├── SKILL.md                  # 符合通用规范
   │   ├── scripts/                  # 可执行脚本
   │   ├── references/               # 详细参考文档
   │   └── agents/
   │       └── openai.yaml           # Codex 特定配置
   ```

3. **description 是关键**：它是 Skills 被自动发现和匹配的核心机制，需包含明确的关键词和触发条件。

4. **保持单向职责**：一个 Skill 只做一件事，避免"万能 Skill"。

5. **SKILL.md 长度控制**：主体指令 < 500 行，详细参考材料放入 references/ 目录。

6. **跨平台分发**：如需支持多平台，使用 Vercel `npx skills` 工具链或 symlink 策略。

### 7.2 兼容性优先级

| 优先级 | 平台 | 理由 |
|---|---|---|
| P0 | Agent Skills 通用规范 | 事实标准，覆盖最广 |
| P1 | Claude Code (SKILL.md) | 当前主要目标平台 |
| P1 | OpenAI Codex (SKILL.md) | 格式完全兼容，主流平台 |
| P2 | Windsurf/Cursor Rules | 格式不同，需额外适配 |
| P3 | GitHub Copilot Instructions | 纯 Markdown 单文件，最简适配 |

### 7.3 Skill 质量 Checklist

- [ ] `name` 符合规范（小写字母、数字、连字符，<= 64 字符）
- [ ] `description` 明确描述功能和触发条件（含关键词）
- [ ] SKILL.md body < 500 行
- [ ] 复杂细节已拆分到 references/
- [ ] 需要可执行脚本时放入 scripts/ 且标注依赖
- [ ] 用真实提示词测试 description 触发准确性
- [ ] 通过 `skills-ref validate` 验证
- [ ] 兼容性信息在 `compatibility` 字段中声明

---

## 八、附录：时间校验记录

| 项目 | 详情 |
|---|---|
| 校验时间 | 2026-06-08 13:30:54 +08:00 ~ 2026-06-08 13:31:00 +08:00 |
| 本机系统时区 | Asia/Singapore (+08:00) |
| 时间源 1 | URL: https://www.google.com (HTTPS Date header) -> Mon, 08 Jun 2026 05:30:57 GMT -> 2026-06-08 13:30:57 +08:00 |
| 时间源 2 | URL: https://www.cloudflare.com (HTTPS Date header) -> Mon, 08 Jun 2026 05:31:00 GMT -> 2026-06-08 13:31:00 +08:00 |
| 本机系统时间 | 2026-06-08 13:30:54 +08:00 |
| 最大偏差 | 6 秒（阈值：100 秒） |
| 判定 | **通过** |
