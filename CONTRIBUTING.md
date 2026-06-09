# 贡献指南

感谢你对香草健康管理（Vita-Skills）的关注。本文档说明如何参与项目贡献。

---

## 行为准则

- 所有交互须保持专业与尊重。
- 代码评审聚焦技术本身，不对人。
- 健康参数修改须有科学来源支撑（见下文"健康参数变更"）。

---

## 如何贡献

### 报告问题

在提交 Issue 之前，请：
1. 搜索已有 Issue 确认未被报告
2. 使用 Issue 模板提供：操作系统/Shell 版本、`vita status` 输出、相关日志（`vita log 20`）、重现步骤

### 提交代码

1. **Fork** 本仓库并创建功能分支：`git checkout -b feature/your-feature`
2. **遵循代码规范**：
   - Shell 脚本：必须通过 `bash -n` 语法检查
   - 所有新脚本必须有文件头部注释（Input/Output/Pos 三行格式）
   - 配置变更必须同步更新 `config/schema.yaml` 中的 Schema 定义
3. **添加测试**：
   - 新模块需在 `tests/test-scheduler.sh` 中添加对应的测试套件
   - 断言函数模板：`assert "描述" "条件表达式" "失败详情"`
4. **运行完整测试套件**：`bash tests/test-scheduler.sh`，所有测试必须通过
5. **Commit** 并发起 Pull Request

### Commit 规范

使用约定式提交格式：

```
<type>: <简短描述>

[可选详细说明]
```

类型标签：
- `feat:` — 新功能
- `fix:` — 修复缺陷
- `docs:` — 文档更新
- `test:` — 测试变更
- `refactor:` — 重构
- `config:` — 配置变更
- `chore:` — 构建/工具链

示例：
```
feat: 新增心率变异性检测的心流判断策略

基于 Apple Watch 的心率变异性数据，新增 HRV-based flow detection method。
当 SDNN < 30ms 时判定为 deep flow。
```

---

## 健康参数变更

任何对默认健康参数（`config/default.yaml` 中的提醒间隔、目标值、阈值）的变更，**必须**满足以下条件：

1. **至少 3 个独立来源**支持新参数值，来源必须：
   - 来自经过同行评议的期刊、权威卫生机构或 Cochrane 系统综述
   - 发表于 10 年内（>10 年需提供补充证据说明为什么仍有效）
2. **在 PR 描述中列出**：来源名称、链接/DOI、发表年份、摘要、效应量（如适用）
3. **更新 `references/health-guidelines.md`** 中的对应条目
4. **更新 `references/README.md`** 中的文件列表

不符合以上条件的健康参数 PR 将被退回。

---

## 项目架构约定

### 文件头部注释

所有源文件开头必须包含三行注释：

```bash
# Input:  [此文件接收的输入]
# Output: [此文件产生的输出]
# Pos:    [此文件在系统中的位置与角色]
#
# 一旦我被修改，请更新我的头部注释，以及所属文件夹的 README.md。
```

### 领地标记

每个文件夹必须包含一个极简 `README.md`（3 行规模），声明：
- 文件列表
- 目录地位
- 功能概述

及声明 *"一旦这里的结构发生变化，请务必更新我... 就像重新标记领地一样。"*

### 渐进式信息披露

文档按以下三层组织，贡献时须遵循对应层的深度限制：
- **第 1 层（SKILL.md）**：Agent 快速理解用，核心功能 + 触发条件 + 子代理调用模式
- **第 2 层（README.md）**：用户操作指南，命令参考 + 安装 + FAQ
- **第 3 层（references/）**：按需加载的科学依据，详细参数与来源索引

---

## 测试框架

### 添加新测试

在 `tests/test-scheduler.sh` 中按现有模式添加测试函数：

```bash
test_my_feature() {
    echo ""
    printf "%b━━━ 测试 N: 功能描述 ━━━%b\n" "$BOLD" "$RESET"

    assert "检查点描述" \
        "条件表达式" \
        "失败时显示的详情"
}
```

并在 `main()` 函数中添加调用：`test_my_feature`。

### 打榜 API 测试

打榜后端测试位于 `leaderboard/tests/api.test.sh`，使用 curl 直接调用 API 端点。运行需要本地 Wrangler 开发环境（`npm run dev`）。

---

## 代码评审要点

评审者将重点关注：
1. 健康参数变更有充分的科学来源支撑
2. Shell 脚本通过 `bash -n` 语法检查
3. 所有新脚本具备完整的三行头部注释
4. 测试覆盖新增/修改的功能路径
5. 配置 Schema 与默认配置保持同步
6. 无硬编码敏感信息（API Key、密码等）

---

## 发布流程

1. 在 `CHANGELOG.md` 中编写版本条目
2. 确保所有测试通过
3. 使用 `git tag vX.Y.Z` 标记版本
4. 推送到远程仓库
