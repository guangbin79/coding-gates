# coding-gates

两道开发闸的独立产品仓（提取自 guangbin79/dotfiles）：进门需求闸 **req-gate** ＋ 出门评审环 **review-loop**。

- **req-gate**：OpenCode V2 插件（execute.before 拦截）——阻断会话首个产品 edit/write，直到需求门验收快检记录存在；配套 `req-check` CLI 与 `/req-gate` 命令。
- **review-loop**：OpenCode V2 插件（session.execution.succeeded 触发）——会话有未评审产品编辑时注入评审环；配套 post-commit hook、`/review-loop` 命令、知识模块与 e2e。

## 安装

```sh
./install.sh req-gate      # 部署 3 个 symlink
./install.sh review-loop   # 部署 2 个 symlink
```

无参/错参打印 usage 退出非零；目标已存在且 `readlink -f` 后不指向本仓时打印「拒绝覆盖」并退出 1（指向本仓或不存在则幂等建链）。

## 部署落点表

| 目标 | symlink | 仓内源 |
|---|---|---|
| req-gate | `~/.config/opencode/plugins/req-gate-enforcer.ts` | `req-gate/req-gate-enforcer.ts` |
| req-gate | `~/.config/opencode/commands/req-gate.md` | `req-gate/command.md` |
| req-gate | `~/.local/bin/req-check` | `req-gate/req-check` |
| review-loop | `~/.config/opencode/plugins/review-loop-trigger.ts` | `review-loop/review-loop-trigger.ts` |
| review-loop | `~/.config/opencode/commands/review-loop.md` | `review-loop/command/review-loop.md` |

hooks 不部署：review-loop 插件启动自检 ensureHooks 幂等自动配 `core.hooksPath`（派生路径缺工件时回退 `~/.dotfiles` 主仓，与提取前 live 行为一致）。

## 验收

- `bash -n install.sh` 干净；`bash tests/install_sandbox.sh` 全过（沙箱 HOME 双目标部署/幂等/异源守卫）。
- live e2e：操作者部署＋service restart 后跑 `review-loop/e2e/review-loop-e2e.sh`。

两插件保持 builtin-only imports（仅 `node:*` 可解析），部署一律 symlink——拷贝成 bare import 会静默挂死。
