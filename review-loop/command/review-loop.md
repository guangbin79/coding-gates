---
description: 开发收尾评审循环——判定→评审→修复→绿门禁→复审→终闸→上报
agent: build
---

你是开发收尾评审循环的编排者。按以下步骤严格执行，逐步落地，不得跳步。

背景（可选透传，无参数系统）：$ARGUMENTS

## 第 1 步：写入防重入标记

在任何评审之前，先写入与自动触发插件同款的持久标记，防止本轮手动评审结束后 session.idle 又触发自动注入，造成双重评审。

1. 获取当前会话 ID：首选 python3 标准库 sqlite3 以只读 URI（`file:...?mode=ro`）打开 `~/.local/share/opencode/opencode.db`（opencode 会话存储现为单文件 SQLite，**2026-10-19 实证 v2.0.32 起表名 session → session_v2**，含 id/directory/time_created 列），执行 directory 锚定查询取最新会话 ID：
   ```bash
   python3 -c "import sqlite3,os; con=sqlite3.connect('file:'+os.path.expanduser('~/.local/share/opencode/opencode.db')+'?mode=ro',uri=True); root='<项目根>'; row=con.execute(\"SELECT id FROM session_v2 WHERE directory=? OR directory LIKE ? ORDER BY time_created DESC LIMIT 1\",(root,root+'/%')).fetchone(); print(row[0] if row else '')"
   ```
   - `<项目根>` 必须显式传入主仓根（非评审临时 worktree）：headless 评审在临时 worktree 内执行，但会话 directory 记录的是主仓根，按主仓根取 time_created 最新即本会话自身。
   - 警示：勿依赖 sqlite3 CLI（本机未装）；勿读 `~/.local/share/opencode/repos/`（旧布局已废弃为空）。
   - 回退：查询失败（库缺失/无匹配行/报错）再用原目录探测法——实测本机会话存储（~/.local/share/opencode/ 下相关目录），按 project 归属匹配本项目目录，按时间取最新会话，取其 ID。
2. 标记文件名必须精确等于插件契约：`<项目根>/.review-loop/.injected-<会话ID>`。
3. 先 `mkdir -p <项目根>/.review-loop`，再 `touch` 该标记文件。
4. 取不到会话 ID 则跳过本步，并在证据文件中注明：此时防重入退化为仅靠插件门控。

## 第 2 步：读取判据真源

通读评审知识模块——路径以注入提示词所附 knowledge module 路径为准（手动直入默认 `~/.dotfiles/.agent/review-loop/module/review-loop.md`），全量判据以该文件为准。本命令不内嵌判据，避免双源漂移。模块文件不存在则停止并上报阻塞，不得自行编造判据。

## 第 3 步：按评审矩阵执行评审

按判据模块中的评审矩阵，结合本次改动范围自选合适的评审方式并执行。逐项记录 finding：位置、问题、严重度、建议修法。

**知识积累前置（2026-10-21 重排）**：循环收敛（无 blocker/high 残留）且仅剩终闸未跑时，先完成知识积累再执行终闸——按 project-compound Ingest 快路径：有 material（决策/策略/Bug/失败路径等）才写 `<项目根>/docs/agents/knowledge/`（文件缺失按需 bootstrap）；No material 在证据中注明即止、零落盘（禁在无知识库的仓新建文件）。终闸 scope 必须含积累产物 diff，其对积累 diff 的 blocker/high 发现按轮内 finding 处理（计入轮次上限）；终闸豁免环的积累产物随豁免无独立评审。

## 第 4 步：修复与绿门禁

每轮修复完成后，按 fire-and-poll 纪律（后台发射加零占用等待，禁止同步阻塞构建）跑构建与相关测试，构建与测试的解析顺序以判据模块的说明为准。全绿才允许进入下一轮评审；未绿则继续修复，不许带病推进。

## 第 5 步：证据落盘

若本会话已存在证据文件且未到 3 轮上限：从其记录的轮次继续（已耗轮次计入上限），不重头开始。
每轮的发现、修复、复测结果写入证据文件：

`<项目根>/.review-loop/<YYYYMMDD-HHMM>-<会话ID前8>.md`

会话 ID 取不到时，文件名用 `unknown` 占位并在文内注明。
每轮开始及察觉会话被压缩后，先重读证据文件恢复轮次与剩余清单；评审输出先写入证据文件再修复，对着文件清单做——不信任对话记忆（判据模块⑫）。

## 第 6 步：循环终止与上报

- 总轮次上限 3 轮，达到即停。
- 任一 finding 超出 Trivial 边界（修复需改动超过 1 个文件或超过 20 行）即停。
- 终止后输出剩余 finding 清单，并向用户上报：轮次数、已修复项、剩余项、证据文件路径。

## 第 7 步：绿态提交与推送（2026-10-17 二批裁定；2026-10-21 ingest 前置后本步只管提交推送）

仅当循环终态无 blocker/high 残留（绿）时执行；超限上报或带残留终态一律跳过本步并在上报中注明未提交（终闸前已落盘的积累文件留工作区，由用户处置）。

1. 提交范围＝本循环 scope 中 session-edited / delegated(child-observed) 类文件（知识库文件系本会话写入，随此范围入库）；residue 与 origin(report-only) 项**一律不碰、不入提交**。
2. 当前分支非 main/master：`git add`（仅上述文件）→ `git commit` → `git push -u origin HEAD`（已有上游则直接 push）——**禁止合并主分支**。
3. 当前分支即 main/master：直接提交并 push 主分支。
4. 提交成功后向各被审根写 `.review-loop/.last-reviewed`＝新 HEAD。
5. push 失败（无远端/凭证/网络）＝如实上报，不阻塞、不回滚本地提交。
6. 提交信息遵循仓库惯例；`.review-loop/` 状态目录与证据文件永不入提交。

## 约束

- 循环内不新建 git worktree，全部在当前工作区内完成。
- 不修改判据真源文件。
- 不做本命令未要求的重构或清理。
