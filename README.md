# 香草健康管理 (vita-skills)

**此项目的任何功能、架构更新，必须在结束后同步更新相关文档。这是我们契约的一部分。**

基于 AI Agent Skills 协议的跨平台健康提醒系统。四大模块：久坐提醒、用眼提醒、喝水提醒、提肛锻炼，支持心流适配与打榜 PK。

## 快速开始

```bash
npx skills add <repo-url>
```

## 目录结构

| 路径 | 用途 |
|------|------|
| `SKILL.md` | 主 Skills 文件（YAML frontmatter + Markdown body） |
| `scripts/` | 提醒脚本（sedentary/eye-care/hydration/kegel） |
| `references/` | 健康参数速查与科学来源 |
| `assets/` | 静态资源 |
| `config/` | 默认配置与配置 Schema |
| `tests/` | 测试套件 |
