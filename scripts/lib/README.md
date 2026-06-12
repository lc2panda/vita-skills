# scripts/lib/
- common.sh: 所有提醒脚本的公共依赖库
- leaderboard-client.sh: 打榜PK系统客户端，提供注册/打卡/排名/排行榜API
- notify.sh: 跨平台系统通知（macOS terminal-notifier/osascript, Linux notify-send）
- suppression.sh: 屏幕锁/会议/空闲/深夜检测，决定是否抑制提醒
- vitarc.sh: 用户级配置加载器，支持 ~/.vitarc 覆盖项目默认值

注意：flow-detector、channel-adapter、adaptive-engine、name-validator、nickname-validator、platform 的权威实现已合并到 `scripts/` 顶层目录，本目录仅保留公共依赖库。

一旦这里的结构发生变化，请务必更新我... 就像重新标记领地一样。
