# coding-gates

[![made for opencode v2](https://img.shields.io/badge/made%20for-opencode%20v2-6e7bff.svg)](https://opencode.ai)

[English](README.md) | [简体中文](README.zh-CN.md)

两道开发质量闸的独立产品仓，面向 [opencode](https://opencode.ai) v2——**req-gate**（进门闸）＋**review-loop**（出门评审环）。提取自 [guangbin79/dotfiles](https://github.com/guangbin79/dotfiles)：插件以 symlink 部署、保持 builtin-only imports（仅 `node:*`），随仓附带配套命令、钩子、CLI 与测试。

> **Super Agent 三支柱**：本仓为「质量监督门」支柱（req-gate 进门闸＋review-loop 出门评审环）。另两根：[opencode-agora](https://github.com/guangbin79/opencode-agora)（调度 Router）· [silicon-memory](https://github.com/guangbin79/silicon-memory)（存算分离：记忆/状态层）。三仓协同构成 super agent 实现。

## 快速开始

前置：[opencode](https://opencode.ai) v2、`bash`、`git`。

```bash
git clone https://github.com/guangbin79/coding-gates.git
cd coding-gates
./install.sh req-gate      # 部署 3 个 symlink
./install.sh review-loop   # 部署 2 个 symlink
```

无参/错参打印 usage 退出非零。守卫纪律：目标已存在且 `readlink -f` 后不指向本仓时，打印「拒绝覆盖：<目标>（指向 <现状>）。接管请确认后手工处理或删除后重跑」并退出 1——绝不覆盖你已有的工具；指向本仓或不存在的目标则幂等建链。装完重启 opencode（或重载插件）生效。

## 两道质量闸

**req-gate——进门闸。** `execute.before` 插件：阻断会话首个产品 edit/write，直到需求门记录落在 `<TMPDIR||/tmp>/opencode/req-gate/<sessionID>.md`（仓外落盘，不脏 worktree）。记录即先于代码写下的验收标准，三选一：`PASS(trivial)`（≤1 文件 ≤20 行）、`PASS`（可执行验收清单）或 `ESCALATE`。配套：`req-check` CLI（用 `docs/reqs/scratch.md` 条目交叉核对代码里的 `Req:` 标签）与 `/req-gate` 命令。

**review-loop——出门评审环。** 完成插件：会话在上次评审后又动了产品代码，下次空闲即注入提示驱动 agent 跑 `/review-loop`——判定→评审→修复→绿门禁→复审→上报。启动时 `ensureHooks` 幂等配置 `core.hooksPath`（仅在未设置时），不部署钩子也有 post-commit 盖章。配套：post-commit/post-checkout/pre-push 钩子、`/review-loop` 命令、知识模块（`review-loop/module/review-loop.md`）与 e2e 套件。`.review-loop/.last-reviewed` 锚同时是开放评审契约——[opencode-agora](https://github.com/guangbin79/opencode-agora) 在 `done` 时校验、合并前复检的就是它。

## 部署落点

| 闸 | symlink | 仓内源 |
|---|---|---|
| req-gate | `~/.config/opencode/plugins/req-gate-enforcer.ts` | `req-gate/req-gate-enforcer.ts` |
| req-gate | `~/.config/opencode/commands/req-gate.md` | `req-gate/command.md` |
| req-gate | `~/.local/bin/req-check` | `req-gate/req-check` |
| review-loop | `~/.config/opencode/plugins/review-loop-trigger.ts` | `review-loop/review-loop-trigger.ts` |
| review-loop | `~/.config/opencode/commands/review-loop.md` | `review-loop/command/review-loop.md` |

hooks 不部署：review-loop 插件自配 `core.hooksPath` 指向其工件根——2026-11-08 提取后工件根就在本仓内解析（`review-loop/hooks`，与插件同级）。遗留的 `review-loop/install.sh`（enroll/unenroll/audit 辅助器）如今同样从本仓取源。

## 验收

```bash
bash -n install.sh && bash tests/install_sandbox.sh
```

沙箱测试在一次性 `HOME`（mktemp）下跑安装器，断言 11 项：双目标部署的 symlink 均落回本仓、重跑幂等、预置异源目标被拒绝且退出 1。live e2e 是操作者步骤：部署并重启 opencode service 后跑 `review-loop/e2e/review-loop-e2e.sh`（需 tmux＋真实 opencode serve）。

## 配置

| 环境变量 | 缺省 | 说明 |
|-----|---------|-------------|
| `REQ_GATE_OFF` | 关 | `=1` 使 req-gate 完全惰性（卸载＝删 symlink） |
| `REQ_GATE_DEBUG` | 关 | `=1` 把闸门判定追加到 req-gate 调试日志 |
| `REVIEW_LOOP_OFF` | 关 | `=1` 使 review-loop 完全惰性 |
| `REVIEW_LOOP_DEBUG` | 关 | `=1` 每次闸门评估落 `.review-loop/` 日志 |
| `REVIEW_LOOP_IDLE_MIN_S` | `10` | 完成后空闲多少秒才跑闸门（e2e/演练旋钮） |
| `REVIEW_LOOP_COOLDOWN_S` | `600` | 两次注入间 marker 冷却窗（e2e/演练旋钮） |

## 安全模型

- **只 symlink 不拷贝**——插件保持 builtin-only imports（`node:*` 经运行时解析）；拷进插件目录改 bare import 会静默挂死。禁止把 symlink 换成拷贝。
- **拒绝覆盖守卫**——部署落点上的异源文件绝不替换；接管是人工确认步骤。
- **豁免开关**——`REQ_GATE_OFF=1` / `REVIEW_LOOP_OFF=1` 不动文件即可让插件惰性。
- **状态不出仓**——req-gate 记录落 `TMPDIR`；`.review-loop/` 为机器本地态，已 gitignore。

## FAQ

**怎么更新？** `git pull` 后重跑 `./install.sh <目标>`——部署就是指向本仓的 symlink，pull 即生效；安装器只刷新链接（幂等）。

**怎么卸载？** 删掉上表五个 symlink（可选：对 `core.hooksPath` 指向本仓的仓执行 `git config --unset core.hooksPath`，并删 `.review-loop/` 标记）。或设两个 `*_OFF` 开关软禁用。

**还依赖 dotfiles 吗？** 不依赖。2026-11-08 提取后工件根在本仓内自定位；`~/.dotfiles` 回退仅为旧 dotfiles 布局保留。

**平台？** Linux（已验证，即开发环境）。macOS 理论可用（只需 bash＋coreutils＋node）但未实测。
