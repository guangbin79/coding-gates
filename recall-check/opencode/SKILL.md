---
name: recall-check
description: Use when the user says 写后自查/代码召回/召回自查/recall-check, or when an agent completes a logical code unit before moving on or entering review, or when capturing a code-related experience during wrap-up — 查：代码摘要+标识符查语义记忆防再踩坑；写：涉代码经验 capture 须带代码指纹行（判据真源见 module）。
---

写后代码召回自查（opencode 绑定）。判据真源（写/查两节+边界）见 `../module/recall-check.md`，本页只做槽位绑定：

- 检索工具：`memory_recall`（MCP 工具）。注意返回为 JSON 字符串——先解析再取 hits，勿按对象解构（2026-11-21 乌龙实证）
- 服务健康检查：`curl -s -m 5 <MEMORY_PLUGIN_URL 或 http://127.0.0.1:8765>/health`；检索空且健康异常 → 显式上报，禁按「空即过」放行
- capture 侧代码指纹行：写入经验正文（capture 流程详见 silicon-memory 仓 agent-experience skill）
