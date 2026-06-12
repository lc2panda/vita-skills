# vita-skills TODO

> 此文件为项目待办追踪清单，新建于 2026-06-12。

## 已完成

- [x] 完善用户使用文档（已完成，README 542 行，覆盖率 95%+，提交 7086ab6）
- [x] API.md challenge 端点鉴权说明（已实现，见 leaderboard/API.md:353，`需要认证：Authorization: Bearer <token>`）

## 待验证（需运行环境）

- [ ] 验证调度器周期性排行榜推送是否正常（端到端）

  **背景**：`scripts/scheduler.sh` 目前仅在 tigang 打卡时触发 `lb_checkin`（见 scheduler.sh:264），无独立的周期性 `leaderboard_push` 函数。

  **验证步骤**：
  1. 确认是否需要独立的周期性推送（当前设计为打卡触发，非定时推送）
  2. 如需定时推送：在 `scripts/lib/leaderboard-client.sh` 中实现 `lb_push_snapshot` 函数，在 scheduler.sh 主循环中按频率调用
  3. 端到端验证命令：`VITA_DEPLOYED=1 bash scripts/scheduler.sh` 并观察日志中 leaderboard API 调用记录

## 中期计划

- [ ] 增加更多运动类型支持

  **说明**：当前支持：久坐提醒（sedentary）、护眼（eye-care）、喝水（hydration）、提肛（tigang）。
  后续可考虑：站立提醒、拉伸、深呼吸等。
