---
name: goal-gate
description: 目标门——收到要派发/委托/指挥其他 agent 的目标时、issue 类外部目标开工前、或目标被判定过大/不可行/验收不明时激活：过三查（可达成/可验证/两层收口）再进入派发链。
---

> 状态：skill-evolution 候选（溯源：2026-11-15/16 设计会话与用户共同定稿，前瞻设计非事故驱动；待评测晋升）

# goal-gate——OpenCode 绑定

判据真源：本目录经 readlink -f 解析后的 ../module/goal-gate.md——三查、超限阀、飞行纪律、能力槽位全以真源为准，本文件只做槽位绑定。

## 槽位绑定表

| 槽位 | 本环境实现 |
|---|---|
| 语义完备检查器 | /req-gate 命令（7 维快检） |
| 目标资格审查 | 本 skill（按真源三查执行） |
| 任务定档器 | agora-dispatch-gate skill（三可定档/七件套） |
| 派发执行器 | agora-dispatch skill ＋ agora 服务 |
| 收尾评审器 | /review-loop 命令 ＋ OCR 独立终审 |

## 超限阀（在场通道）

超三层复杂度 → 问用户：plan 流程细化目标，或改写更细致的目标。复杂度回给人，不越权深拆。

## 链路

/req-gate 语义完备 → goal-gate 三查 → agora-dispatch-gate 任务定档 → agora-dispatch 派发（飞行期只处理状态转换）→ /review-loop＋OCR 收尾。
