# 开发完成自动评审循环（review-loop）

> Last updated: 2026-10-21

## Overview
- 开发完成后自动评审-修复循环的唯一真源；`/review-loop` 命令与 review-loop-trigger 插件注入提示均指向本文
- Key files: `~/.config/opencode/AGENTS.md`（清单层「行为准则」单行）、`mounts/opencode/commands/review-loop.md`、`.agent/opencode/plugins/review-loop-trigger.ts`、`.githooks/post-commit`（完成信号）、`.agent/review-loop/e2e/review-loop-e2e.sh`（模拟用例，S1-S12/W1-W8）、`.agent/review-loop/run-with-review.sh`（headless 包装器）
- Dependencies: `visual-qa`、`open-code-review`（ocr_review）、`wait`
- See also: [[principles]]、[[worktree]]
- 读者：执行 /review-loop 的 agent 与被插件注入的会话；判据写成可执行规则，不是散文

## 判据

### 评审矩阵
- **Chosen:** 按变更性质从矩阵自选组合：ocr_review=git 仓代码行级快筛/复审；终闸=三分册零共享评审（契约与裁决规则见「三分册终闸」节）；visual-qa=UI 变更叠加（≤1 次）
- **Reason:** 零共享新会话评审跨版本/跨 harness 恒可用，不依赖任何插件或内置终审；叠加评审按需启用，一次循环内各叠加至多一轮

### 三分册终闸（2026-10-22 改制）
- **Chosen:** 终闸一轮内并行派 3 个窄域零上下文子代理，各带固定「报什么/禁报什么」清单；产出由执行会话按固定规则裁决合并：
  - **公共契约:** 零推理上下文＋零记忆库消费（沿用「验证者上下文隔离」与记忆盲区）；输入＝完整 diff＋测试命令解析结果；评审者动手跑验收命令取证据，不轻信生成者自述；评审子代理只读；每条 finding 必含 severity(critical/warning/suggestion)＋file:line＋问题＋证据＋为何不属于禁报项
  - **A 册·需求符合性:** 输入增量＝`Req: <id>` 锚（docs/reqs/ 行级记录＋commit trailer）；逐条 Req 标注 met / gap(指到代码行) / ambiguous，gap 按影响定 critical/warning；禁报与需求无关的风格/重构/性能/防御性编程建议。降级：无 Req 锚时以 commit message 声明意图为基准出「意图符合性」表（做了没声明的/声明了没做的/含糊的）
  - **B 册·崩溃风险:** 报空引用/None 解引用、未处理或吞掉的异常、边界条件（空集/off-by-one/越界/整数溢出）、并发与竞态、资源泄漏、致 panic/5xx/数据丢失路径——每条必须给出触发输入或调用序列；禁报风格/命名/抽象建议、小概率前置条件的理论问题、未改动代码的问题、测试覆盖率建议
  - **C 册·安全:** 报注入（SQL/XSS/命令/路径穿越）、改动代码中的认证/越权 bypass、硬编码密钥、不安全加密、信任边界缺失输入校验；禁报理论风险、主防线充分时的纵深防御建议、未改动代码问题、「考虑用库 X」类建议
  - **裁剪规则（确定性）:** B/C 册输入＝diff 中可执行面文件（代码/脚本/被消费配置——含治理判据等被 agent 当行为指令消费的文本）；过滤后为空 → 该册 skipped 并在证据注明（等价干净）；A 册非豁免环恒开
  - **裁决（执行会话自任，固定规则非自由裁量）:** ①跨册重复保留一次归最相关册；②映射 critical→blocker、warning→high（计入轮次），suggestion→记录不计轮次；③命中禁报清单或投机项丢弃，拿不准读源码验证再判；④三册原文＋裁决表先写证据文件（⑫ findings 先落盘）
- **Reason:** 2026-10-22 用户裁定：单一宽泛终闸 prompt 产出泛化（风格噪声多、需求/崩溃/安全命中浅）。调研实证——Augment 45 万文件横评：需求符合性是全部开源评审工具的共同盲区；Cloudflare 七专项评审架构：「What NOT to Flag」负面清单是降噪主因（13.1 万次评审均 1.2 findings/次）。三分册＝窄域专项＋负面清单＋固定裁决，零新依赖
- **Supersedes:** 评审矩阵节旧「终闸=零共享新会话评审（单一评审者）」定义与「security-review=安全敏感叠加（≤1 次）」——安全评审并入 C 册，安全敏感环释放的叠加预算归 ocr（叠加数仅计 visual-qa）；2026-10-17「弃 /review-work」裁定仍有效，零共享原则不变仅分册化

### 终闸条件与豁免类
- **Chosen:** 默认含终闸评审×1；豁免两类（2026-10-21 扩）——①Trivial 级（≤1 文件且 ≤20 行）且 ocr 干净且测试绿；②纯信息性记录 diff 且 ocr 干净。豁免均须在证据中注明依据
- **Reason:** 豁免只认硬边界，禁止以"改动小"为印象级理由跳过终闸；豁免②溯源 2026-10-21 判例——84 行纯 markdown judge 报告 ocr skipped 仍交全额零共享终闸，评审成本远超爆炸半径，尺寸豁免管不住类型
- **定义:** 「ocr 干净」＝ocr_review 实跑零 blocker/high，或工具返回 skipped/no items selected（无可审内容，等价干净）；未跑/超时/字节帽截断/报错≠干净，豁免不成立。「信息性记录」判别＝读者只知悉（报告/日志/经验/归档决策）→ 可豁免②；读者照做（规则/流程/判据/命令/配置/脚本，无论落在哪个目录，含 knowledge 行为准则详情层）→ 不豁免；判定存疑 → 不豁免（保守方向）
- **约束:** 行为指令/运行链路消费类文件（判据、命令定义、AGENTS.md、skill、插件、脚本、被消费配置）一律不适用豁免②；diff 混入此类文件即整体不豁免

### 循环纪律与绿门禁
- **Chosen:** 发现→修复→fire-and-poll 跑构建+相关测试→绿了才准进下一轮复审；测试红=blocker 级 finding 计入轮次
- **Reason:** 禁止在未验证构建/测试的情况下续跑评审；终闸评审者同样动手验证，不轻信生成者自述

### 轮次预算分配优先级
- **Chosen:** 优先级=终闸>叠加>ocr；ocr 轮数=3−(终闸1+叠加数)；总轮次硬上限 3
- **约束:** 叠加启用时 ocr 自动让位；循环持续到无 blocker/high 发现或待办清空为止，但不得突破上限 3

### 测试命令解析顺序
- **Chosen:** 项目 docs/构建系统声明的命令优先→仓内既有脚本（Makefile / package.json scripts / pyproject）→都无则跳过并注明"无测试命令"
- **Reason:** 禁止凭空发明测试命令；解析顺序决定证据中记录的命令来源

### 超限上报
- **Chosen:** 用完轮次预算仍有 blocker/high 残留→停下，带 `.review-loop/` 剩余问题清单通知用户，禁止继续自动循环
- **Reason:** 超限续跑=规则失效；上报后由用户决定是否追加预算或转 plan

### Trivial 边界
- **Chosen:** 循环发起者为执行侧（build/实现类会话），直接修复评审发现，不逐条走 plan；finding 修复 >1 文件或 >20 行或涉及架构/需求决策→停，可转 plan 规划会话
- **Reason:** 边界自持定义（≤1 文件/≤20 行，与豁免①同源硬边界），外部无依赖；边界外禁止执行侧自作主张
- **约束:** 「执行侧直接修复评审发现」的授权仅覆盖 scope 中 session-edited/delegated 类文件；residue/origin(report-only) 文件上的发现一律记录并上报用户，不得自动修复

### 待办清空定义
- **Chosen:** "待办清空"=会话 todo 列表全部 completed（cancelled 不算 completed）
- **Reason:** 与循环终止条件配套：无 blocker/high 发现或待办清空，二者其一即停

### 评审范围与完成标记 (2026-09-27)
- **Chosen:** 自动注入的评审范围以插件 prompt 携带的 scope 为准（roots + `{起点}..HEAD` 或 dirty-tree）；手动 /review-loop 自行推导：`.review-loop/.last-reviewed..HEAD`，无该标记则以本会话首个产品提交前 HEAD 为起点或工作区 diff。每轮评审完成（证据落盘）后，向各被审 root 写 `.review-loop/.last-reviewed` = 当前 HEAD——它是下一轮评审范围的起点，也是 commit-flag 消费后范围可恢复的锚点
- **Reason:** commit 触发路径下树是净的，diff 语义失效；范围必须由触发器显式交接，完成状态必须落盘可恢复
- **Chosen:** 注入 scope 现携带文件级归属——`session-edited`（本会话 edit/write 观察到的编辑，含直接子会话 delegated(child-observed)）授权评审并修复；`residue(report-only)`（未经会话 edit/write 观察到的改动——含 bash 途径的本会话改动与他会话遗留）与 `origin: <v|unknown> (report-only)`（外来提交段）只报告，未经用户确认归属不得修改；2026-10-08 加硬：此类项任何落盘/补录/修复动作须先获用户确认（插件 reviewPrompt 已内嵌硬话术；判例：2026-10-08 15:05 误跳事故中 residue 被违规 landing 致 .agent-experiences 草稿误删）
- **Reason:** 评审发现按归属分类分流：session-edited/delegated 类可进修复循环；residue/origin(report-only) 类发现必须记录并上报用户，待用户确认归属后才能处理

### 触发信号降级与权威门 (2026-10-16)
- **Chosen:** 用户裁定 A+C：dirty-tree 不再单独构成欠债（欠债门仅 HEAD≠.last-reviewed 或 .commit-flag——commit-first 纪律）；注入新增权威门——debtRoots 须含 equivRoots（本会话[+直接子会话] editPaths 实际解析到的仓；cwd 覆盖的 'session' provenance 不算），否则 `gate=authority BLOCK` 仅记 plugin-debug（would-scope 附审计）。脏树文件仍进 scope 归属（session-edited/residue 二分不变，限已因提交入债的仓）。
- **Reason:** 误激活治理——idle≠done 暂停骚扰与 residue 噪声（2026-10-16 会话四连催实证：评审已闭环仍每 600s 重催待 commit 的脏树）；2026-09-27 dirty-tree 主路径判断被用户 commit-first 工作流取代，known gap ① 重开为接受面（改了不提交的工作不触发评审，由用户纪律兑底）。
- **e2e:** S6/S14 改提交制（prompt 加 commit 指令、S6a 断言改 flag 范围）；S7a/b 经由会话内真实编辑过权威门，行为不变；S12 claim-skip 先于权威门，不变。
- **Supersedes:** 本节欠债门与权威门语义 2026-10-17 被「欠债门时间轴化与空闲门」取代（commit 信号降级为范围携带者、权威门移除）；dirty 二分归属（session-edited/residue）仍有效。

### 欠债门时间轴化与空闲门 (2026-10-17)
- **Chosen:** 用户裁定：欠债不再以 commit 为准（HEAD≠.last-reviewed 与 .commit-flag 均降级为 scope 范围携带者；flag 的 rename-claim 消费与 at-most-once 语义不变）——欠债＝本会话[+直接子会话]在「最后一次 review-loop」之后有产品编辑（edit/write 观测带时间戳）；「最后一次 review-loop」锚＝候选目录集合（会话目录 `${dir}/.review-loop/` ＋各欠债根 `<root>/.review-loop/` 双扫——命令按<项目根>落 marker/证据，dir≠仓根拓扑下会话目录侧扑空、根侧兜住；终闸评审 medium 修正）下本会话证据文件 `*-<sid8>.md` 与 `.injected-<sid>` 标记的 mtime 最大值（手动环第 1 步 touch 同名标记，注入环由插件落标——两路环都刷新锚）。权威门随之移除（欠债根必含等价编辑，条件恒真）。另新增空闲门：session.idle 不立即评估，空闲持续 ≥10s（`REVIEW_LOOP_IDLE_MIN_S` 可调；2026-10-17 二批由 30s 调低）才跑闸门管线，更近 idle 取消重挂——回合间隙的瞬时 idle 永不触发。
- **Reason:** 误启发治理换轴——commit 基准下「已评审会话＋他会话新提交/外来旗标」反复误催（editPaths 全会话累计无时间维度，2026-10-16 权威门拦不住此形态）；时间轴基准把「该不该催」收敛为「本会话自己是否又干了活」，同时重开 dirty 接受面（改了不提交的工作重新入债，但评审后无新编辑即静默——时间维度使 dirty 不再无限期骚扰）。空闲门治「回合间隙催促」：idle 即评会在用户连续追问/多步工作中途插话。
- **e2e:** S11/S12 新欠债改真实编辑（空提交不再构成会话新欠债）；全部 S 场景 tmux 注入 `REVIEW_LOOP_IDLE_MIN_S=5`（门路径不变，时延缩短）；S10 EXPECTED_HOOKS 保持主仓稳定路径（ensureHooks 派生路径在本插件布局不存在→恒走 HOME 回退，分支期 e2e 亦然；hooks 本分支未改）；其余场景经新门语义不变（S6a 范围仍由 flag 携带）。
- **天花板:** ①sloppy 评审环「最后动作是修复编辑且未再写证据」会在冷却后自催一次（⑫纪律「findings 先落盘＋每轮写证据」兑底，marker 600s 冷却吸收大部分）；②纯 bash 编辑（不经 edit/write）即使提交也不再触发（旧缝隙②的 commit 路径覆盖随 flag 降级失效——手动 /review-loop 与 headless 包装器 lane 兜底）；③重启丢 editPaths 时间戳→静默（安全方向，同既有重启天花板）；④空闲门计时中「新回合已开始但尚无工具调用」的纯思考回合可能被提前注入（promptAsync 排队，回合结束才消费，无害）。

### 观测过滤扩展：.agent-experiences 非产品编辑 (2026-10-21)
- **Chosen:** isOmoPath 增 `.agent-experiences` 三形态（`==`/`startsWith`/`includes`，与 .omo/.review-loop 同级）——经验沉淀写入（agent-experience capture/他会话 residue 草稿/INDEX 更新）不计 editPaths，不构成欠债、不入 scope。
- **Reason:** 事故溯源：2026-10-21 NPU 会话经验写入（`~/.dotfiles/.agent-experiences/experiences/20261021-171747-1c3d.md`）被欠债门计为产品编辑→dotfiles 根误入 scope→review-loop 空转自催一轮（无产品变更的评审）。经验记忆是记忆基础设施的常态写入，与 `.review-loop/` 证据写入同类（后者已在过滤内），属基础设施噪声非产品编辑。
- **e2e:** S16 新增（仅写 .agent-experiences 路径→gate=edits BLOCK 零注入，S4 语义同级扩展）；其余场景语义不变。

### 绿态知识积累与自动提交推送 (2026-10-17 二批裁定；2026-10-18 加知识积累；2026-10-21 ingest 前置)
- **Chosen:** 评审循环收敛（无 blocker/high 残留）后、终闸前先落知识积累——按 project-compound Ingest 快路径：有 material（Decision/Strategy/Bug/Failed Approach 等）才写 `<项目根>/docs/agents/knowledge/`（文件缺失按需 bootstrap）；No material → 证据中注明即止、零落盘（禁为 No material 在无知识库的仓新建文件）。终闸 scope 必须含积累产物 diff，其对积累 diff 的 blocker/high 发现按轮内 finding 处理（计入轮次上限）；终闸豁免环（Trivial/记录类）积累产物随豁免无独立评审。绿后自动提交并 push：提交范围仅 scope 中 session-edited/delegated 类文件——知识库文件系本会话写入即属 session-edited，随绿提交入库（residue 与 origin(report-only) 一律不入提交，report-only 铁律不变）；当前分支非 main/master → 只 push 当前分支（无上游则 `push -u origin HEAD`），**不合并主分支**（合并仍为人工/后续显式决策，ff-only 铁律不变）；当前分支即主分支 → 直接提交推送。提交成功后向各被审根写 `.last-reviewed`＝新 HEAD（循环自身产出含知识积累视为已覆盖），hook 落下的 `.commit-flag` 惰性无害。push 失败（无远端/凭证/网络）＝上报不阻塞，本地提交保留。
- **Reason:** 用户裁定：绿后落库自动化——评审保证「值得提交」，提交推送是机械动作；非主分支不并主保住 ff-only 线性历史与人工合并决策点。积累置于提交前：知识文件随绿提交一次落库；有 material 时 ingest 结果补记证据文件（刷新欠债锚 mtime——现行门为时间轴基准，锚晚于积累编辑即不构成新欠债；仅写 `.last-reviewed`＝HEAD 覆盖不 sufficient，那是降级后的范围携带者）。积累前置终闸前（2026-10-21 裁定）：原「终闸后落盘＋提交前覆盖门补速览」为一缝多付一趟零共享评审——前置后终闸视野天然含积累 diff，一趟全覆盖；所补之缝（2026-10-18 判例：软链双源重复靠执行侧自查捕获，终闸未见该 diff）由前置同等封堵，覆盖门废除。
- **约束:** 超限上报/带 blocker-high 残留终态＝不提交（未绿终态下已落盘的积累文件留工作区，上报注明由用户处置）；`.review-loop/` 状态目录与证据文件永不入提交（repo hygiene）。积累产物晚于终闸落盘（⑫重入/乱序）→ 对该 diff 补一发终闸同合同速览（零共享、只读；发现按轮内 finding 计入上限，速览本身不计轮次）——旧覆盖门语义仅此场景保留。
- **Supersedes:** 2026-10-18「ingest diff 终闸覆盖门」（积累后置于终闸后、提交前以终闸同合同补零共享速览）——由 2026-10-21 ingest 前置取代，一趟终闸全覆盖。

### 落库分级：知识/配置载体仓写后提交落库（2026-10-19 立法「只写不落库」；2026-11-07 用户裁定改为提交）
- **Chosen:** 被审根分两级——①**工作主仓**（当次任务交付仓）绿后自动提交+push 维持原语义；②**知识/配置载体仓**（判据：会话在该根内仅写入经验/知识/治理文件，无产品代码变更；典型 `~/.dotfiles`）→ agent 写后（评审绿后）**commit 落库、永不 push**——push 节奏仍归用户治理；写后照常落证据（欠债锚正常刷新），评审照常（知识内容仍需核对）
- **Reason:** 2026-10-19 判例：经验文件落 dotfiles 触发绿态自动提交推送，会话两次 push 用户个人配置仓 master（40f3325 等）——当时裁定方案 A「只写不提交」全禁 git 操作。2026-11-07 用户裁定改为提交：commit 禁令解除（经验/知识不再积压工作区），push 面禁令保留——当年事故是 push 不是 commit
- **约束:** 载体仓 commit 永不 push（含 master）；commit 范围仅本会话写入的经验/知识/治理文件；工作主仓内知识文件（`docs/agents/knowledge/`）仍随绿自动提交入库，不受本条影响
- **Supersedes:** 本条 2026-10-19「只写不落库」的 commit 禁令部分（push 禁令不变）

### 汇报分域：未决/状态清单按归属仓分列（2026-10-20）
- **Chosen:** 轮次汇报与"未决清单"必须按归属仓分域——工作主仓事项入主仓清单；载体仓/会话治理事项（dotfiles 裁定落库等）单列"跨仓事项"段并标注归属仓，禁止混入项目未决清单
- **Reason:** 2026-10-20 判例：OSMDataCompiler 会话的未决清单两次混入 dotfiles 治理待办（推送分级落库），用户指出"多次出现"——清单注水稀释真实未决项，跨域归属不清
- **约束:** 证据文件同规则：跨仓事项记入对应仓证据或单列段，不入主仓清单
- **Supersedes:** 「绿态知识积累与自动提交推送」节中"知识库文件随绿提交入库"对载体仓的隐含自动提交+推送语义（工作主仓部分不变）

### 交接原子性与交付语义 (2026-09-27)
- **Chosen:** 完成 flag 消费用 rename-claim（`mv .commit-flag → .commit-flag.claimed-<sid>`，POSIX rename 原子，防跨进程双消费）；交付为 at-most-once——注入即消费，不等评审完成；`claimed-*` 清理双保险：owner=消费会话在 idle 顶部按内存 sid→claimedRoots 映射删除 + groom 7 天 TTL 兜底（仅 dotfiles 仓跑 groom，他仓孤儿惰性无害）
- **Reason:** 刻意取舍（2026-09-27 信号重设计）：完成才消费会让多个 idle 会话反复收到同一提醒（跨会话重复骚扰）；义务偶尔丢失的代价小于重复骚扰，git 提交天然是恢复点（flag 丢失后下次提交重建信号）

### 已知缝隙与兜底
- **【2026-10-19 修复】dbg 通道 v2.0.32 适配（含二批漂移，supersede 同日「缝隙·未修」条）**——根因三重（opencode.db 会话记录＋service 进程实证）：①v2.0.32 起 TUI 默认连接常驻 background service（`opencode serve --service`；`--standalone` 退回私有 server），插件在 service 进程内执行——e2e 注入 TUI 的 `REVIEW_LOOP_*` env 与磁盘新插件代码均不可达（现役 service 10-18 22:09:54 起恒无 env＝「唯 dbg 静默、注入/marker/旗消费照常」的机理；插件模块缓存持旧＝三连修与 HEAD 基线全部无效的原因）；②委派工具更名 task→subagent，hook 只匹配 task → delegators 永不注册（S8/S9/S13d 假红）；③edit/write `input.path` 可为 cwd 相对路径，「工具 args 恒绝对」假设失效 → 编辑已观测但 repoRootOf 拒绝 → 欠债恒无（S10 假红）。修复＝e2e 16 处启动行 `--standalone`（每场景独立 env＋新载插件，恢复 2.0.32 前隔离语义）＋hook 双名匹配＋钩内 `resolve()` 归一（standalone server cwd=TUI cwd）＋RL_E2E_WAIT 快速失败开关；全套件 102/0 绿实证。诊断教训：排障先比对「env 注入进程」与「插件执行进程」是否同一——拓扑问题先于字段形状假设（会话形状漂移假说系陈旧 dbg 文件误读，见 eb5c4953 环）；残留缝隙（service 模式相对路径错误归属，独立任务）记 log.md Residual 条
- **【2026-10-18 修复】孤儿旗标**——amend/rebase 把旗上起点改写成孤儿号（实证：本仓绿态收尾 amend 后注入范围起点＝被弃 d1031a5，靠 reflog 存活碰巧解析；reflog 过期 GC 后范围构造将报错）；修复＝消费端 merge-base --is-ancestor 可达性双检（可解析∧HEAD 祖先），不过即弃用范围、落「session-edited since last review」兜底并记 plugin-debug（flag-start orphan），旗本体消费与 origin 归属不变；e2e S15（孤儿 fixture → 断言无 `<孤儿>..HEAD`＋守卫 dbg 行＋兜底非空），合法起点路径由 S6a 回归。
- **Supersedes:** 2026-09-26 版缝隙清单（①②已被信号重设计改写）
- **Chosen:** 缝隙现状（2026-09-27 信号重设计后）：①【已修复】commit-before-idle——完成信号改为「脏树 OR `.review-loop/.commit-flag`」，post-commit 钩子落 flag，插件注入后消费；该缝隙曾是主路径而非边缘（主日志零自动注入、唯一证据为手动触发）；②【2026-10-17 扩大】纯 bash 写文件不计编辑——欠债门时间轴化后 commit 路径覆盖亦失效（flag 不再构成欠债）：bash 途径编辑无论提交与否均不触发，手动 /review-loop 与 headless 包装器兜底；③【新增修复】非仓 cwd 会话——仓根从编辑文件路径解析（rev-parse），会话目录仓仅作回退；附带发现：`$` 在非零退出时抛 ShellError（与旧注释相反），探仓/探 flag 必须包 try/catch，否则 handler 崩掉且零 debug 痕迹（旧版「静默死」的真实机理；**2026-09-28 已随去 $ 化失效**——gitQuiet 失败 resolve null 永不抛，探仓不再依赖 try/catch）
- **Reason:** dirty-tree 信号与本工作流「任务含提交」纪律反相关——e2e 夹具用「编辑不提交直接 idle」验证，恰好绕开唯一致命场景；信号重设计后 e2e 补齐真实工作流模拟（review-loop-e2e.sh S1-S5，15/15 绿，2026-09-27）
- ⑦【2026-10-08 修复】跨实例会话误消费——事故时间线：15:05 并行 worktree 修复会话（dotfiles__wt-rl-fixes__10081505）与主检出评审会话同仓并发，后发会话 idle 误消费先发会话的评审信号，其评审环将 residue（.agent-experiences 脏态）违规 landing 致 467f/bfaa 草稿误删；修复=插件仓级 scope-claim（`<root>/.review-loop/.scope-claim.json`：root/sessionID/claimed_at 毫秒，tmp+rename 原子写）——注入前他人新鲜认领（TTL 40min=2× 典型评审回合）→ claim-skip 跳过并记 plugin-debug.log（含双方 sid 与 root）；认领会话每次对该 root 的 idle 刷新 claimed_at（活性近似）；rename-claim 消费 .commit-flag 时删除对应认领；TTL 过期可被接管；同实例 injected Set 语义不变（本修复只管跨会话）；残余天花板：TTL 非真实活性检测（认领者静默 40min 即可被接管，活性刷新依赖认领实例存活）、claim 检查→写入非原子（同瞬双会话可双双放行）、prompt 硬话术非硬保证（软约束层，模型仍可能违规）
- opencode run 非交互会话不处理注入提示（进程退出即丢）——评审循环仅交互式会话可达；自动化验证以交互/TUI 驱动为准
- opencode run headless 模式下插件异步尾段可能与进程 dispose 竞速（毫秒级窗口，注入偶发丢失）——交互/TUI 会话不受影响；自动化断言以 TUI 驱动为准
- 钩子部署（2026-09-29 起自动化）：直入仓由插件启动自检 ensureHooks 自动配置；跨库仓由父会话在派发前经 ~/.dotfiles/.agent/review-loop/install.sh enroll 预挂（自定位工件钩目录）；仅余手配场景：纯浏览仓改提交、dotfiles 自身（相对路径 .githooks）
- 2026-09-28 去 $ 化：opencode 1.18.33 插件 `$` 捕获+镜像双写子进程 stdio 到 TTY（TUI 污染根因，经验 20260928-154839-c056）——trigger/req-gate 全部探测与文件操作改 node:child_process execFile（pipe）+ node:fs，日志一律落 plugin-debug.log / gate-debug.log，插件内零 `console.*`；e2e S1-S7b 25/25 绿（736f09a/ad30be5/d116e84）
- **Supersedes:** 2026-09-27 版缝隙现状之 delegated-roots 项——delegated direct-child roots 已修复（等价集 editPaths 入 roots + provenance 门控权威，commit ab095e3/c99f9cf）；清理推迟规则见 worktree 模块
- **Chosen:** 天花板现状（2026-09-29 delegated-child 修复后，六项）：
  - 孙辈嵌套不自动归因（须评审时人工确认）
  - background task 父先 idle 则子会话编辑不完整入 roots
  - headless opencode run 不处理注入
  - 无钩子仓提交后净树无信号（须每仓配 core.hooksPath .githooks）
  - 重启丢失内存 editPaths 含子会话编辑（安全方向 residue）
  - 同 equiv 根混外来提交 flag 时权威化（D2 授权语义，记录为决策非意外）

### defer 规则
- **Chosen:** ⑩ defer 规则三条：
  - ①纯规划 agent（plan 等规划/评审类，不交付产品代码）跳过自动注入
  - ②`<项目根>/.omo/boulder.json` 存在 active work（start-work 执行中）→ 跳过注入，由 F1-F4 终验波收尾
  - ③build 等实现类会话（含委派子代理编辑）正常触发
- **Reason:** 正则只匹配纯规划者，实现主力不误伤；父会话派 task 即经 delegators 有评审资格（ocr#9）

### 子循环扩展点
- **Chosen:** 可实例化同骨架子循环（专属评审器+通过判据），挂载点仅规则矩阵加行+命令编排嵌段，插件不动；硬约束=子循环共享主循环总轮次预算 3，不设独立无限轮次；不预建任何子循环（YAGNI）
- **Reason:** 出现高频需求后按需添加；预算共享防止嵌套循环突破上限

### 验证者上下文隔离（2026-10-04，ext-orch-survey #6）
- **Chosen:** 评审者与生成者默认零共享上下文——评审会话不携带生成会话的推理轨迹/决策史；同会话修复循环完成后，必须补一发零共享验证（ocr run 或零共享新会话评审）方可宣称绿
- **Reason:** Cognition Devin Review 实证：零共享评审平均 2 bug/PR、58% 严重；context rot 使长上下文生成者对自己盲区失明；短上下文验证者能反向质疑生成者因用户指令而盲从的错误
- **约束:** 「零共享」指推理上下文，不指验收标准——contract/verify_commands 必须给评审者；例外（如需生成者背景才能判断的归属类发现）须人工批准并在证据中注明
- **记忆盲区（2026-10-12，rsiagent-borrow）:** 零共享扩至记忆面——评审者另不得为被审任务消费执行者的记忆库（`.agent-experiences/`、`docs/agents/knowledge/`），防生成侧自我叙事污染裁决；终闸 scope 以 diff 形式含此类文件不构成消费
- **评审为 pre-merge 门（2026-10-12）:** review-loop 绿是 ff-only 合并的前置条件，先绿后并；不存在「合并后补评审」的合法路径

### headless lane（包装器路径，2026-10-06）
- **Chosen:** 无自持编排的 headless `opencode run` 消费者（CI 机器人、issue 自动修复等）以 `run-with-review.sh` 为规范入口，调用形态 `run-with-review.sh run <flags> <message>`：包装器透传工作 run 并捕获原退出码，退出后扫描 `<root>/.review-loop/.commit-flag`；归属双门（mtime≥包装器启动时刻 且 旗标 origin 行==本实例 `REVIEW_LOOP_WRAP_ID`）全部通过才消费，at-most-once 经 rename-claim（`.claimed-<pid>-<ts>`）；范围由旗标首行 SHA 构造 `<sha>..HEAD`（禁 .last-reviewed 推导）；评审 run 经 `timeout -k 5`（`REVIEW_LOOP_TIMEOUT`，默认 1800s）有界执行，超时/非零非阻塞——包装器以工作 run 退码退出；证据目录由包装器解析 `REVIEW_LOOP_EVIDENCE_DIR`（默认 `<root>/.review-loop/`）为绝对路径并内嵌评审 prompt 四要素（真 /review-loop 命令+显式范围+证据目录+Trivial 边界与推送纪律）；防递归 `REVIEW_LOOP_HEADLESS=1`（检测即纯透传＋评审 run 环境注入，双重防护）
- **分工判据:** 带自持编排的集成（跨分支范围/临时 worktree 评审/推送管制，如 HXNativeApp issue-agent）保留 prompt 直调 /review-loop 形态——为模块认可的并行形态而非降级备选（包装器 cwd 仓扫描几何不匹配其评审编排）；跨会话来源经钩子 origin 标记区分，交互会话注入不消费 WRAP_ID 旗标（归属门排它）
- **Reason:** headless 进程退出即丢注入（上方已知缝隙②）——进程级编排（包装器）替代插件注入，插件零改动；不经 idle 注入，defer 规则不适用
- **已知缝隙:** ①同仓并发 headless run 跨会话误消费由交互会话 W2 水平触发兑底；②评审 run 自身提交的孤儿旗标惰性无害（包装器在工作 run 后一次性扫描，评审期新旗标不追扫；worktree 随删）；③钩子保留旧旗标时新提交可能不被包装器覆盖（首值保留语义＋旧 mtime）→交互会话 W2 兑底

## ⑫ 上下文检查点（压缩免疫）

- 轮次以文件为准：每轮开始（及察觉会话被压缩后）先重读本会话证据文件 `.review-loop/<YYYYMMDD-HHMM>-<会话ID前8>.md`——轮次计数与剩余清单以文件为唯一真源，不信任对话记忆。
- findings 先落盘再修：评审输出的第一动作是写入证据文件（原文或要点），修复动作对着文件清单执行，不对着聊天记录执行。
- 重入即续跑：`/review-loop` 发现本会话证据文件已存在且未到 3 轮上限 → 从记录轮次继续（已耗轮次计入上限），不重头开始；插件自动注入后的循环同理。
- 超大 diff：ocr 字节帽报错时按目录或提交段分批评审，禁止静默截断。

## Practices

### 执行入口
- 手动：`/review-loop` 命令；自动：插件在 session.idle 门控满足时注入一次指向本文与命令的提示
- 循环内禁止新建 worktree，延续开发会话当前工作区；评审子代理只读

### 证据纪律
- 每轮发现与修复落盘 `.review-loop/`；豁免终闸时必须在证据中注明理由与豁免类判定（Trivial/记录类）

### 排障处方（诊断 agent 必读；用户只需三件套：重启实例 / 转述横幅原文 / 手动 /review-loop 兜底）
- 四探针逐条跑，输出即定位失败形态（静默型=该发生没发生；吵闹型=崩溃横幅）：
- 空闲门提醒（2026-10-17）：闸门行在 idle 后 ≥IDLE_MIN_MS（默认 10s）才出现——「idle 后日志未立即落」不是故障；排障时先等窗过或设 REVIEW_LOOP_IDLE_MIN_S=0
  1. **flag 状态**：`test -f <repo>/.review-loop/.commit-flag && cat <repo>/.review-loop/.commit-flag`——存在=有待审未触发（idle 门控故障或会话未 idle）；**内容为空=旧 touch 式 flag，删之，下次提交重建带范围版**
  2. **评审欠账**：`git -C <repo> log --oneline $(cat <repo>/.review-loop/.last-reviewed)..HEAD | wc -l`——无 `.last-reviewed` 文件=本仓评审环从未完成；落后多=环停摆（flag 被消费但评审未跑完）
  3. **孤儿 marker**：`ls <repo>/.review-loop/.injected-* | wc -l` 对比 `ls <repo>/.review-loop/2026*.md | wc -l`——marker 多于证据=注入了但 agent 未执行循环
  4. **崩溃痕迹**：TUI 横幅即时报错（重启旧实例后才可见）；持久层查 `grep -a "\[review-loop\]" ~/.local/share/opencode/log/opencode.log | grep -av permission`
- roots=- 且 delegator 会话：检查子会话是否同步派发（background 不计）、孙辈、以及 opencode 实例是否重启过（重启丢内存 editPaths）
- 复现真相：`REVIEW_LOOP_DEBUG=1` 重启实例 → `<会话目录>/.review-loop/plugin-debug.log` 逐 gate 真相（卡哪道门、roots 解析结果）——**2026-10-19 修正：v2.0.32 起 TUI 默认连接常驻 background service，插件在 service 进程内执行，注入 TUI 的 env 与磁盘新代码均不可达——排障/调试一律 `opencode --standalone` 起独立实例（或先 `opencode service restart`）**
- 插件改动回归门：全套 `.agent/review-loop/e2e/review-loop-e2e.sh`（全场景断言，随场景增长）全绿才可提交
- 长实例注意：插件代码在进程启动时加载——任何修复对未重启的 opencode 实例不可见，排障第一步先查实例启动时间 vs 修复提交时间；**2026-10-17 实测修正：当前 opencode 存在插件热重载**（运行中实例吃到中间版构建并按其行为注入，证据＝无提交脏树触发欠债注入＋中间版 ownRel 误分类），排障勿再假设旧版绝对滞留

## Supersedes
- 无（2026-09-25 首次建立）
