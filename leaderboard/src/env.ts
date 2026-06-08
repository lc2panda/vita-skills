// Input: Cloudflare Workers 环境绑定（D1, KV）
// Output: 类型安全的 Hono Bindings 类型导出
// Pos: 全局环境变量类型定义，被所有路由 handler 引用

import type { D1Database } from "@cloudflare/workers-types";

export interface Bindings {
  DB: D1Database;
  KV_CACHE: KVNamespace;
}
