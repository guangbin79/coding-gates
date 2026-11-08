#!/usr/bin/env bash
# review-loop 信号重设计 e2e — 模拟真实工作流的触发用例（2026-09-27）
# 场景（对应根因诊断）：
#   S1 commit-then-idle   主杀场景：编辑+提交后 idle（老插件 gate=porcelain 必 BLOCK）→ 必须注入
#   S2 非仓 cwd           会话根在非 git 目录，编辑+提交发生在嵌套仓（老插件静默死）→ 必须注入
#   S3 零工作 idle         无编辑无提交 → gate=edits BLOCK，不得注入
#   S4 .omo 噪声           仅写 .omo 路径 → gate=edits BLOCK，不得注入
#   S16 经验写入噪声       仅写 .agent-experiences 路径 → gate=edits BLOCK，不得注入（gt-12c3，2026-10-21）
#   S5 冷却封口            S1 注入后：flag 被删；再 idle → marker mtime 冷却 BLOCK（W2：不再永拒）
#   S6 混合脏树归属       会话编辑 hello.ts + bash 直写 leftover.ts → scope 同时含 session-edited 与 residue(review-only)，且 residue 不被改动
#   S7 flag origin 标注   S7a 双行 flag origin=external / S7b 旧单行 flag → scope 含 origin: <external|unknown> (report-only)
#   S8 delegated roots     非仓 cwd + task 子会话直编嵌套仓（改2提1）→ 父注入：scope 含嵌套仓 root + delegated(child-observed) 且不落 residue（批A）/ 无 report-only（批B）
#   S9 delegated worktree  同 S8 但子会话在 linked worktree 内改2提1不清理 → root=worktree + flag 存活至消费；批B 无 report-only
#   S10 直入新仓自动配钩   cwd=无 hooksPath 新仓直接开工（无 task 委托）→ 编辑+提交 → 插件启动自检应配 core.hooksPath 并注入
#   S11 水平触发再注入     冷却过期（REVIEW_LOOP_COOLDOWN_S=10）+ 新欠债（评审后新编辑，2026-10-17 时间轴）→ 同会话二次注入，scope 含 session-edited 归属（老插件 marker 存在即永拒此处必漏）
#   S12 跨会话竞态       双实例同仓：A 注入持 scope-claim → B idle claim-skip 零注入；A 消费 flag 后 claim 释放（2026-10-08 事故修复）
#   S13 规划误投负例       phase1 仅写 .omo/.review-loop（gate=edits）+ phase2 task 只读子代理成 delegator 零等价编辑 → gate=cwd-fallback BLOCK，全程零注入（task-5 defer 回归，2026-10-08）
#   S14 boulder defer 解除     boulder active→gate=boulder BLOCK（临时 defer）；work 完成后同会话再 idle→必须恢复注入（老缺陷：boulder 门 return 未解 injected 占位→永久封口）
#   S15 孤儿旗标守卫       amend/rebase 后旗上起点非 HEAD 祖先 → 弃用旗范围落兜底（flag-start orphan debug），旗本体照常消费（2026-10-18）
#   W1  有提交→追加评审       stub 工作 run 真实提交落旗标→包装器追加评审 stub run＋rename-claim 消费
#   W2  无旗标→零追加         无提交（预清旗标）→评审 stub 零调用
#   W3  陈旧旗标不消费        mtime 回拨 1h→跳过+stderr 记录
#   W4  异源旗标不消费        origin=他会话（未来时刻锚定过 mtime 门）→跳过+stderr 记录
#   W5  超时退码不污染        评审超时(124)/非零(7)→包装器退码仍=工作 run 退码
#   W6  证据目录重定向        REVIEW_LOOP_EVIDENCE_DIR 相对路径→prompt 含解析后绝对路径
#   W7  防递归               REVIEW_LOOP_HEADLESS=1→纯透传（旗标保留+零追加）
#   W8  空旗标处置           旧 touch 式空旗标→删除跳过

# 空闲门（2026-10-17 用户裁定）：session.idle 后空闲持续 ≥IDLE_MIN_MS 才评估——全部 S 场景注入 REVIEW_LOOP_IDLE_MIN_S=5（默认 10s，2026-10-17 二批调低；e2e 缩短；回合间隙不触发）
# 驱动：tmux TUI + REVIEW_LOOP_DEBUG=1；断言 plugin-debug.log 闸门行 + git 状态 + flag 生命周期
# v2.0.32 适配（2026-10-19）：TUI 默认连接常驻 background service，插件在 service 进程内执行，
# 场景 env（DEBUG/IDLE_MIN_S/COOLDOWN_S）与磁盘插件代码均不可达——全部 S 启动行改
# `opencode --standalone`（私有 server＝每场景独立 env＋新载插件代码，恢复 2.0.32 前隔离语义）
# 用法: bash review-loop-e2e.sh S1 [S2 ...]   （默认全跑；RL_E2E_WAIT=<秒> 缩短失败场景等待上限，默认 480；产物 ~/.omo/evidence/review-loop/signal-e2e-<ts>.log）
set -u
EVDIR="$HOME/.omo/evidence/review-loop"
TS=$(date +%Y%m%d-%H%M%S)
LOG="$EVDIR/signal-e2e-$TS.log"
HOOKSRC="${RL_E2E_HOOKSRC:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../hooks}" # 自定位：e2e 自身所在工件 e2e/../hooks（分支期=worktree 钩，回并后=master 钩，同 S10a/ensureHooks/install.sh 自定位语义）
PASS=0; FAIL=0
WAIT="${RL_E2E_WAIT:-480}" # 快速失败开关：缩短原 480s 注入/闸门类等待（S3/S4/S13 闸门 300s 等次级等待仍固定）；默认 480 不变
case "$WAIT" in ''|*[!0-9]*) WAIT=480 ;; esac; [ "$WAIT" -lt 5 ] && WAIT=5 # 非数字/过小回退：防 for((i<$WAIT/5)) 零迭代假超时
mkdir -p "$EVDIR"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }

mkrepo() { # $1=path  $2=name
  rm -rf "$1"; mkdir -p "$1"; cd "$1"
  git init -q .; git config user.email e2e@t; git config user.name e2e
  cp -r "$HOOKSRC" .githooks; git config core.hooksPath .githooks
  printf '.omo/\n.review-loop/\n' > .gitignore
  printf 'export function hello() { return 1; }\n' > hello.ts
  git add .gitignore .githooks hello.ts; git commit -qm "init $2"   # hooks 入库：idle 时树真净，退 flag 分支（脚本 v1 教训）
}

tui_send() { # $1=tmux-session $2=prompt
  tmux send-keys -t "$1" -l "$2"; sleep 1; tmux send-keys -t "$1" Enter
}

wait_log() { # $1=file $2=regex $3=timeout_s → 0 命中
  local i; for ((i=0; i<$3/5; i++)); do
    [ -f "$1" ] && grep -aqE "$2" "$1" && return 0
    sleep 5
  done; return 1
}

wait_log_absent() { # $1=file $2=regex $3=grace_s（宽限期后再判缺失）
  sleep "$3"; [ -f "$1" ] && grep -aqE "$2" "$1" && return 1; return 0
}

assert() { # $1=desc $2=cmd...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then log "  ✅ $desc"; PASS=$((PASS+1)); else log "  ❌ $desc"; FAIL=$((FAIL+1)); fi
}

s1() {
  local R=/tmp/rl-e2e-s1 S=rls1 DBG
  log "=== S1 commit-then-idle（主杀场景）==="
  mkrepo "$R" s1
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "把 hello.ts 里的函数名 hello 改成 greet，改完用 git commit -m rename 提交。在收到自动评审提醒之前，不要自己运行 /review-loop；收到提醒后，按提醒内容执行评审。"
  DBG="$R/.review-loop/plugin-debug.log"
  if ! wait_log "$DBG" "gates PASS .* injecting" $WAIT; then
    log "  ❌ S1 超时未见 gates PASS（$WAIT s）"; tail -5 "$DBG" 2>/dev/null; FAIL=$((FAIL+1)); return
  fi
  assert "S1a gates PASS（老插件此处 gate=porcelain BLOCK）" grep -aq "gates PASS" "$DBG"
  assert "S1b injected OK" grep -aq "injected OK" "$DBG"
  wait_log "$DBG" "injected OK" 60 || true # 消费 mv 先于该行落定，claimed glob 断言时点锚
  assert "S1c 无 worktree BLOCK（注入前；注入后欠债清零 BLOCK 属水平触发正常态）" test 0 -eq "$(awk '/gates PASS/{f=1} /gate=worktree BLOCK/{if(!f)c++} END{print c+0}' "$DBG")"
  assert "S1d 提交存在且树净" bash -c "cd $R && [ \$(git rev-list --count HEAD) -ge 2 ] && [ -z \"\$(git status --porcelain)\" ]"
  wait_log "$R/.review-loop" "injected OK" 10 2>/dev/null # noop settle
  assert "S1e commit-flag 已被消费" bash -c "! test -f $R/.review-loop/.commit-flag"
  local i cl=0; for ((i=0; i<90; i++)); do # claimed 观测窗：注入即改名；下游 idle 会清理，观测到即过（快 turn 竞态免疫）
    ls $R/.review-loop/.commit-flag.claimed-* >/dev/null 2>&1 && { cl=1; break; }
    sleep 1
  done
  assert "S5b flag 已转 claimed（消费即改名）" test $cl -eq 1
  log "  （等待注入后的评审环产出证据文件…）"
  local i ev=0; for ((i=0; i<420/5; i++)); do
    ls $R/.review-loop/2026*.md >/dev/null 2>&1 && { ev=1; break; }
    sleep 5
  done
  [ $ev -eq 1 ] && { log "  ✅ S1f 评审证据文件产出"; PASS=$((PASS+1)); } || log "  ⚠ 评审证据 420s 未出现（触发已验证，环执行另行观察）"
  local i lr=0; for ((i=0; i<120/5; i++)); do
    test -f $R/.review-loop/.last-reviewed && { lr=1; break; }
    sleep 5
  done
  [ $lr -eq 1 ] && { log "  ✅ S1g .last-reviewed 落盘"; PASS=$((PASS+1)); } || { log "  ❌ S1g .last-reviewed 未在 120s 内落盘"; FAIL=$((FAIL+1)); }
  assert "S1h 证据含范围记法" bash -c "grep -aqE '\.\.(HEAD|[0-9a-f]{6,})' $R/.review-loop/2026*.md"
  # S5：同会话再 idle → 冷却封口（W2：marker=600s mtime 冷却而非永拒；评审环自身 idle 同样命中）
  tui_send $S "回复 done 两个字母即可"
  if wait_log "$DBG" "gate=marker BLOCK" 180; then
    assert "S5a 复 idle 被冷却封口（marker mtime<600s）" grep -aq "gate=marker BLOCK" "$DBG"
  elif [ "$(grep -ac 'injected OK' "$DBG" 2>/dev/null || true)" -eq 1 ]; then
    log "  ✅ S5a 复 idle 无二次注入（冷却已过且无新欠债）"; PASS=$((PASS+1))
  else log "  ⚠ S5 未捕获冷却封口（180s）"; FAIL=$((FAIL+1)); fi
  tmux kill-session -t $S 2>/dev/null
}

s2() {
  local H=/tmp/rl-e2e-s2-home
  local P=$H/projects/proj S=rls2 DBG
  log "=== S2 非仓 cwd + 嵌套仓编辑（B 修复）==="
  rm -rf "$H"; mkdir -p "$H/projects"; mkrepo "$P" s2
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $H && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "把 projects/proj/hello.ts 里的函数名 hello 改成 greet，改完在 projects/proj 里 git commit -m rename 提交。不要自己运行 /review-loop。"
  DBG="$H/.review-loop/plugin-debug.log" # debug 锚定会话目录（非仓也可写）
  if ! wait_log "$DBG" "gates PASS .* injecting" $WAIT; then
    log "  ❌ S2 超时未见 gates PASS"; tail -5 "$DBG" 2>/dev/null | tee -a "$LOG"; FAIL=$((FAIL+1)); return
  fi
  assert "S2a gates PASS（会话根非仓仍触发）" grep -aq "gates PASS" "$DBG"
  assert "S2b injected OK" grep -aq "injected OK" "$DBG"
  assert "S2c 嵌套仓提交在" bash -c "cd $P && [ \$(git rev-list --count HEAD) -ge 2 ]"
  sleep 30
  assert "S2d 嵌套仓 flag 已消费" bash -c "! test -f $P/.review-loop/.commit-flag"
  tmux kill-session -t $S 2>/dev/null
}

s3() {
  local R=/tmp/rl-e2e-s3 S=rls3 DBG
  log "=== S3 零工作 idle（负例）==="
  mkrepo "$R" s3
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "只列出当前目录的文件名，不要编辑任何文件。"
  DBG="$R/.review-loop/plugin-debug.log"
  wait_log "$DBG" "gate=edits BLOCK" 300 || { log "  ⚠ S3 未捕获 gate=edits BLOCK（可能 idle 未触发，查 TUI）"; }
  assert "S3a gate=edits BLOCK" grep -aq "gate=edits BLOCK" "$DBG"
  assert "S3b 无注入" bash -c "! grep -aq 'injected OK' $DBG 2>/dev/null"
  tmux kill-session -t $S 2>/dev/null
}

s4() {
  local R=/tmp/rl-e2e-s4 S=rls4 DBG
  log "=== S4 纯 .omo 噪声（负例，D2 语义保持）==="
  mkrepo "$R" s4
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "把一行文字 hello 写进 .omo/notes/x.md 文件（用写文件工具），不要动其他文件。"
  DBG="$R/.review-loop/plugin-debug.log"
  wait_log "$DBG" "gate=(edits|worktree) BLOCK" 300 || log "  ⚠ S4 未捕获零欠债 BLOCK（edits|worktree）"
  # S4a 接受任一零欠债 BLOCK 行（ag-8128ba 实证：模型路径回显噪音（西里尔 о/双 o）→ 写失败
  # → 挣扎；existsSync 后幻影写入已不计，但挣扎落盘 tmp 再挪入 .omo 的形态会以 worktree
  # BLOCK(no debt) 呈现——终态等价：omo 噪声零欠债零注入，判定语义一致）
  assert "S4a gate=edits/worktree BLOCK（.omo 不算产品编辑）" bash -c "grep -aqE 'gate=(edits|worktree) BLOCK' $DBG 2>/dev/null"
  assert "S4b 无注入" bash -c "! grep -aq 'injected OK' $DBG 2>/dev/null"
  tmux kill-session -t $S 2>/dev/null
}

s16() {
  local R=/tmp/rl-e2e-s16 S=rls16 DBG
  log "=== S16 纯 .agent-experiences 噪声（负例，S4 语义同级扩展 gt-12c3）==="
  mkrepo "$R" s16
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "把一行文字 hello 写进 .agent-experiences/experiences/x.md 文件（用写文件工具），不要动其他文件。"
  DBG="$R/.review-loop/plugin-debug.log"
  wait_log "$DBG" "gate=edits BLOCK" 300 || log "  ⚠ S16 未捕获 gate=edits BLOCK"
  assert "S16a gate=edits BLOCK（.agent-experiences 不算产品编辑）" grep -aq "gate=edits BLOCK" "$DBG"
  assert "S16b 无注入" bash -c "! grep -aq 'injected OK' $DBG 2>/dev/null"
  tmux kill-session -t $S 2>/dev/null
}

s6() {
  local R=/tmp/rl-e2e-s6 S=rls6 DBG SHA
  log "=== S6 混合脏树归属（session-edited + residue review-only）==="
  mkrepo "$R" s6
  # bash 直写残留脏文件：不经会话编辑工具 → 归属须落 residue(review-only)，评审环不得改动
  printf 'export function leftover() { const unusedVar = 1; return 2; }\n' > "$R/leftover.ts"
  SHA=$(sha256sum "$R/leftover.ts" | cut -d" " -f1)
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "把 hello.ts 里的函数名 hello 改成 greet，只改这一个文件并提交它（git commit），不要动 leftover.ts、不要提交 leftover.ts。在收到自动评审提醒之前，不要自己运行 /review-loop；收到提醒后，按提醒内容执行评审。"
  DBG="$R/.review-loop/plugin-debug.log"
  if ! wait_log "$DBG" "gates PASS .* injecting" $WAIT; then
    log "  ❌ S6 超时未见 gates PASS（$WAIT s）"; tail -5 "$DBG" 2>/dev/null | tee -a "$LOG"; FAIL=$((FAIL+1)); return
  fi
  assert "S6a scope 含 flag 范围（2026-10-17：欠债＝会话编辑，flag 仅范围携带者）" bash -c "grep -a 'gates PASS' '$DBG' | grep -aqE '[0-9a-f]{7,40}\\.\\.HEAD'"
  assert "S6b scope 含 residue(review-only): leftover.ts" grep -aq "residue(review-only): leftover.ts" "$DBG"
  log "  （等待注入后的评审环产出证据文件…）"
  local i ev=0; for ((i=0; i<420/5; i++)); do
    ls $R/.review-loop/2026*.md >/dev/null 2>&1 && { ev=1; break; }
    sleep 5
  done
  if [ $ev -eq 1 ]; then
    assert "S6c leftover.ts 字节不变（residue 不被改）" bash -c "[ \"\$(sha256sum $R/leftover.ts | cut -d' ' -f1)\" = \"$SHA\" ]"
    assert "S6d 证据文本提及 residue（中英任一）" bash -c "grep -aqE 'residue|review-only|遗留' $R/.review-loop/2026*.md"
  else log "  ⚠ S6 证据文件 420s 未出现，跳过行为断言"; FAIL=$((FAIL+1)); fi
  tmux kill-session -t $S 2>/dev/null
}

s7() {
  # S7a：净树仓手写双行 flag（SHA + origin: external）→ scope 含 origin: external (report-only)，注入后 flag 转 claimed
  local R=/tmp/rl-e2e-s7a S=rls7a DBG
  log "=== S7a 手写双行 flag origin=external ==="
  mkrepo "$R" s7a
  mkdir -p "$R/.review-loop"
  { git -C "$R" rev-parse HEAD; echo "origin: external"; } > "$R/.review-loop/.commit-flag"
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "把 hello.ts 里的函数名 hello 改成 greet，不要提交，不要自己运行 /review-loop。"
  DBG="$R/.review-loop/plugin-debug.log"
  if ! wait_log "$DBG" "injected OK" $WAIT; then
    log "  ❌ S7a 超时未见 injected OK（$WAIT s）"; tail -5 "$DBG" 2>/dev/null | tee -a "$LOG"; FAIL=$((FAIL+1)); return
  fi
  assert "S7a1 scope 含 origin: external (report-only)" grep -aq "origin: external (report-only)" "$DBG"
  local i cl=0; for ((i=0; i<90; i++)); do # claimed 观测窗（同 S5b：下游 idle 会清理，观测到即过）
    ls $R/.review-loop/.commit-flag.claimed-* >/dev/null 2>&1 && { cl=1; break; }
    sleep 1
  done
  assert "S7a2 flag 已转 claimed（消费即改名）" bash -c "[ $cl -eq 1 ] && [ ! -f $R/.review-loop/.commit-flag ]"
  tmux kill-session -t $S 2>/dev/null

  # S7b：新仓手写单行旧格式 flag（仅 SHA）→ origin 缺失 → scope 含 origin: unknown (report-only)
  local R2=/tmp/rl-e2e-s7b S2=rls7b DBG2
  log "=== S7b 旧格式单行 flag origin 未知 ==="
  mkrepo "$R2" s7b
  mkdir -p "$R2/.review-loop"
  git -C "$R2" rev-parse HEAD > "$R2/.review-loop/.commit-flag"
  tmux kill-session -t $S2 2>/dev/null; tmux new-session -d -s $S2 -x 220 -y 50 "cd $R2 && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S2 "把 hello.ts 里的函数名 hello 改成 greet，不要提交，不要自己运行 /review-loop。"
  DBG2="$R2/.review-loop/plugin-debug.log"
  if ! wait_log "$DBG2" "injected OK" $WAIT; then
    log "  ❌ S7b 超时未见 injected OK（$WAIT s）"; tail -5 "$DBG2" 2>/dev/null | tee -a "$LOG"; FAIL=$((FAIL+1)); return
  fi
  assert "S7b1 scope 含 origin: unknown (report-only)" grep -aq "origin: unknown (report-only)" "$DBG2"
  tmux kill-session -t $S2 2>/dev/null
}

s8() {
  local H=/tmp/rl-e2e-s8-home P S=rls8 DBG V i gl
  P=$H/projects/proj
  log "=== S8 非仓 cwd + task 子会话直编嵌套仓（delegated roots）==="
  rm -rf "$H"; mkdir -p "$H/projects"; mkrepo "$P" s8
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $H && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "用 task 工具同步派发一个 general 子代理（禁止 run_in_background，等子代理做完再继续）：让子代理把 $P/hello.ts 里的函数名 hello 改成 greet，再用写文件工具创建 $P/notes.md 内容为一行 child note，然后只在 $P 里 git add hello.ts 并 git commit -m rename，notes.md 必须保持未提交。你自己不要编辑任何文件，也不要自己运行 /review-loop。"
  DBG="$H/.review-loop/plugin-debug.log" # debug 锚定会话目录（非仓也可写，同 S2）
  V=""; for ((i=0; i<$WAIT/5; i++)); do
    { [ -f "$DBG" ] && grep -aq "gates PASS .* injecting" "$DBG"; } && { V=green; break; }
    { [ -f "$DBG" ] && grep -aq "gate=worktree BLOCK .* roots=-" "$DBG"; } && { V=red; break; }
    sleep 5
  done
  if [ "$V" != "green" ]; then
    assert "S8-fix 子会话已落 dirty+flag 并存（夹具自检，红灯有效性前提）" bash -c "cd $P && [ \$(git rev-list --count HEAD) -ge 2 ] && [ -n \"\$(git status --porcelain)\" ] && [ -f $P/.review-loop/.commit-flag ]"
    gl=$(grep -a 'gate=worktree BLOCK' "$DBG" 2>/dev/null | tail -1); [ -z "$gl" ] && gl=$(grep -a 'gate=' "$DBG" 2>/dev/null | tail -1)
    log "  ❌ S8 批A 未达（红灯观察: ${gl:-无闸门行，$WAIT s 超时}）"; FAIL=$((FAIL+1))
    log "  ❌ S8 批B 未达（红灯在案）"; FAIL=$((FAIL+1))
    tmux kill-session -t $S 2>/dev/null; rm -rf "$H"; return
  fi
  assert "S8a gates PASS（老插件此处 gate=worktree BLOCK roots=-）" grep -aq "gates PASS" "$DBG"
  assert "S8b injected OK" grep -aq "injected OK" "$DBG"
  assert "S8c scope 含嵌套仓 root" grep -aFq "$P (" "$DBG"
  assert "S8d scope 含 delegated(child-observed" grep -aq "delegated(child-observed" "$DBG"
  assert "S8e 子会话未提交文件不落 residue" bash -c "! grep -aq 'residue(review-only)' '$DBG'"
  assert "S8f scope 无 report-only（批B）" bash -c "grep -aq 'gates PASS' '$DBG' && ! grep -a 'gates PASS' '$DBG' | grep -aq 'report-only'"
  tmux kill-session -t $S 2>/dev/null; rm -rf "$H"
}

s9() {
  local H=/tmp/rl-e2e-s9-home P W S=rls9 DBG V i gl
  P=$H/projects/proj; W=$P-wt
  log "=== S9 同 S8 但子会话在 linked worktree 内工作且不清理（flag 存活至消费）==="
  rm -rf "$H"; mkdir -p "$H/projects"; mkrepo "$P" s9 # 主仓+worktree 两路径同在 $H 下，rm -rf 一次覆盖跨运行清理
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $H && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "用 task 工具同步派发一个 general 子代理（禁止 run_in_background，等子代理做完再继续）：让子代理先在 $P 里执行 git worktree add $W -b wt-e2e-s9 建 linked worktree，然后把 $W/hello.ts 里的函数名 hello 改成 greet，再用写文件工具创建 $W/notes.md 内容为一行 child note，然后只在 $W 里 git add hello.ts 并 git commit -m rename，notes.md 保持未提交，不要执行 git worktree remove（worktree 必须保持存活）。你自己不要编辑任何文件，也不要自己运行 /review-loop。"
  DBG="$H/.review-loop/plugin-debug.log"
  V=""; for ((i=0; i<$WAIT/5; i++)); do
    { [ -f "$DBG" ] && grep -aq "gates PASS .* injecting" "$DBG"; } && { V=green; break; }
    { [ -f "$DBG" ] && grep -aq "gate=worktree BLOCK .* roots=-" "$DBG"; } && { V=red; break; }
    sleep 5
  done
  if [ "$V" != "green" ]; then
    assert "S9-fix worktree dirty+flag 且存活（夹具自检，红灯有效性前提）" bash -c "git -C $P worktree list | grep -aq '$W' && [ \$(git -C $W rev-list --count HEAD) -ge 2 ] && [ -n \"\$(git -C $W status --porcelain)\" ] && [ -f $W/.review-loop/.commit-flag ]"
    gl=$(grep -a 'gate=worktree BLOCK' "$DBG" 2>/dev/null | tail -1); [ -z "$gl" ] && gl=$(grep -a 'gate=' "$DBG" 2>/dev/null | tail -1)
    log "  ❌ S9 批A 未达（红灯观察: ${gl:-无闸门行，$WAIT s 超时}）"; FAIL=$((FAIL+1))
    log "  ❌ S9 批B 未达（红灯在案）"; FAIL=$((FAIL+1))
    tmux kill-session -t $S 2>/dev/null; rm -rf "$H"; return
  fi
  assert "S9a gates PASS（老插件此处 gate=worktree BLOCK roots=-）" grep -aq "gates PASS" "$DBG"
  assert "S9b injected OK" grep -aq "injected OK" "$DBG"
  assert "S9c root=worktree 根" grep -aFq "$W (" "$DBG"
  assert "S9d scope 含 delegated(child-observed" grep -aq "delegated(child-observed" "$DBG"
  local i cl=0; for ((i=0; i<90; i++)); do # claimed 观测窗（同 S5b：下游 idle 会清理，观测到即过）
    ls $W/.review-loop/.commit-flag.claimed-* >/dev/null 2>&1 && { cl=1; break; }
    sleep 1
  done
  assert "S9e worktree flag 存活至消费（消费即改名）" test $cl -eq 1
  assert "S9f 子会话未提交文件不落 residue" bash -c "! grep -aq 'residue(review-only)' '$DBG'"
  assert "S9g scope 无 report-only（批B）" bash -c "grep -aq 'gates PASS' '$DBG' && ! grep -a 'gates PASS' '$DBG' | grep -aq 'report-only'"
  tmux kill-session -t $S 2>/dev/null; rm -rf "$H"
}

s10() {
  local R=/tmp/rl-e2e-s10 S=rls10 DBG V i gl
  log "=== S10 直入新仓自动配钩（cwd=无 hooksPath 新仓，期望插件启动自检配钩）==="
  rm -rf "$R"; mkdir -p "$R"; cd "$R"
  git init -q .; git config user.email e2e@t; git config user.name e2e # 无 core.hooksPath：本场景前提，禁用 mkrepo
  printf '.omo/\n.review-loop/\n' > .gitignore
  printf 'export function hello() { return 1; }\n' > hello.ts
  git add .gitignore hello.ts; git commit -qm "init s10"
  LOADED_PLUGIN="$RLCFG/plugins/review-loop-trigger.ts" # 与插件同法派生期望钩路径（2026-11-08 单级化锁步；ag-8128ba 改锚沙箱被测插件＝ensureHooks 实际加载源）：realpath 单级 dirname/hooks，缺目录回退 HOME 主仓
  EXPECTED_HOOKS="$(dirname "$(readlink -f "$LOADED_PLUGIN" 2>/dev/null || echo "$LOADED_PLUGIN")")/hooks"
  [ -d "$EXPECTED_HOOKS" ] || EXPECTED_HOOKS="$HOME/.dotfiles/.agent/review-loop/hooks" # 派生根缺 hooks（dotfiles 旧布局）→插件 ensureHooks 同款兜底
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "把 hello.ts 里的函数名 hello 改成 greet，改完用 git commit -m rename 提交。不要自己运行 /review-loop。"
  DBG="$R/.review-loop/plugin-debug.log" # cwd 即仓根，同 S1 锚法
  V=""; for ((i=0; i<$WAIT/5; i++)); do
    { [ -f "$DBG" ] && grep -aq "gates PASS .* injecting" "$DBG"; } && { V=green; break; }
    { [ -f "$DBG" ] && grep -aq "gate=worktree BLOCK .* roots=$R" "$DBG"; } && { V=red; break; } # 红灯：roots 非空（sessionRoot=本仓），区别于 S8/S9 roots=-
    sleep 5
  done
  if [ "$V" != "green" ]; then
    assert "S10-fix 新仓无 hooksPath 且提交已落（夹具自检，红灯有效性前提）" bash -c "cd $R && [ \$(git rev-list --count HEAD) -ge 2 ] && [ -z \"\$(git config core.hooksPath)\" ]"
    gl=$(grep -a 'gate=worktree BLOCK' "$DBG" 2>/dev/null | tail -1); [ -z "$gl" ] && gl=$(grep -a 'gate=' "$DBG" 2>/dev/null | tail -1)
    log "  ❌ S10 批A 未达（红灯观察: ${gl:-无闸门行，$WAIT s 超时}）"; FAIL=$((FAIL+1))
    log "  ❌ S10 批B 未达（红灯在案）"; FAIL=$((FAIL+1))
    tmux kill-session -t $S 2>/dev/null; rm -rf "$R"; return
  fi
  assert "S10a hooksPath 已自动配置（老插件此处仍空）" bash -c "test \"$(git -C $R config core.hooksPath)\" = \"$EXPECTED_HOOKS\""
  assert "S10b gates PASS（老插件此处 gate=worktree BLOCK roots=$R）" grep -aq "gates PASS" "$DBG"
  assert "S10c injected OK" grep -aq "injected OK" "$DBG"
  assert "S10d scope 含会话仓 root" grep -aFq "$R (" "$DBG"
  assert "S10e 注入含范围信号（..HEAD / session-edited since last review）" bash -c "grep -a 'gates PASS' '$DBG' | grep -aqE '\.\.(HEAD|[0-9a-f]{6,})|session-edited since last review'"
  assert "S10f 提交已落（自动配置的钩子实际生效）" bash -c "cd $R && [ \$(git rev-list --count HEAD) -ge 2 ]"
  tmux kill-session -t $S 2>/dev/null; rm -rf "$R"
}

s11() {
  # W2 水平触发验收：同会话冷却后再欠债 → 可再注入（老插件 marker 存在即永拒，此处必漏）
  local R=/tmp/rl-e2e-s11 S=rls11 DBG AN i c
  log "=== S11 水平触发：冷却过期+新欠债 → 二次注入 ==="
  mkrepo "$R" s11
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_COOLDOWN_S=10 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "把 hello.ts 里的函数名 hello 改成 greet，改完用 git commit -m rename 提交。在收到自动评审提醒之前，不要自己运行 /review-loop；收到提醒后，按提醒内容执行评审。"
  DBG="$R/.review-loop/plugin-debug.log"
  if ! wait_log "$DBG" "injected OK" $WAIT; then
    log "  ❌ S11 首次注入超时（$WAIT s）"; tail -5 "$DBG" 2>/dev/null | tee -a "$LOG"; FAIL=$((FAIL+1)); tmux kill-session -t $S 2>/dev/null; rm -rf "$R"; return
  fi
  assert "S11a 首次注入恰 1 次" bash -c "[ \$(grep -ac 'injected OK' '$DBG') -eq 1 ]"
  # 等评审环落 .last-reviewed 锚（首轮评审完成，欠债清零）
  AN=""; for ((i=0; i<300/5; i++)); do
    if [ -s "$R/.review-loop/.last-reviewed" ]; then AN=$(cat "$R/.review-loop/.last-reviewed"); [ ${#AN} -eq 40 ] && break; fi
    sleep 5
  done
  [ ${#AN} -eq 40 ] && { log "  ✅ S11b .last-reviewed 锚落盘"; PASS=$((PASS+1)); } || { log "  ❌ S11b 锚未落盘（300s）"; FAIL=$((FAIL+1)); tmux kill-session -t $S 2>/dev/null; rm -rf "$R"; return; }
  # 冷却（10s）早已过期；制造新欠债：评审后新编辑（2026-10-17 欠债门时间轴化——空提交/外来提交不再构成会话欠债）
  tui_send $S "再用编辑工具把 hello.ts 里当前的函数名改成 howdy（无论它现在叫什么），只改这一个文件，禁止用 bash/sed 改文件，不要提交，改完直接回复 ok。"
  c=0; for ((i=0; i<300/5; i++)); do
    c=$(grep -ac 'injected OK' "$DBG" 2>/dev/null || true); [ "$c" -ge 2 ] && break
    sleep 5
  done
  assert "S11c 冷却过期后新欠债二次注入" bash -c "[ \$(grep -ac 'injected OK' '$DBG') -ge 2 ]"
  assert "S11d 二次 scope 含 session-edited: hello.ts（欠债＝评审后新编辑）" bash -c "grep -a 'gates PASS' '$DBG' | tail -1 | grep -aq 'session-edited: hello.ts'"
  tmux kill-session -t $S 2>/dev/null; rm -rf "$R"
}

s12() {
  # A 跨会话认领（2026-10-08 15:05 事故修复）：双实例同仓竞态——A 注入持 scope-claim →
  #   2026-10-17 欠债门时间轴化适配：A 欠债＝会话编辑（空提交/锚点差分仅为范围携带者）。
  #   驱动：A 编辑（欠债门）+ 夹具空提交（锚点差分范围）；二次注入须再造新编辑。
  # S12d 改 sid 归因（A 冷却再注入不算 B 注入）；S12f 前锚点追平防 A 复活认领。
  local R=/tmp/rl-e2e-s12 SA=rls12a SB=rls12b DBG ASID BSID i c gone
  log "=== S12 跨会话竞态：A 持 scope-claim → B claim-skip；A 消费 flag 后 claim 释放 ==="
  mkrepo "$R" s12
  mkdir -p "$R/.review-loop"
  git -C "$R" rev-parse HEAD > "$R/.review-loop/.last-reviewed" # 锚定 init：下一提交即锚点差分欠债
  git -C "$R" commit -q --allow-empty -m "unreviewed baseline work"
  rm -f "$R/.review-loop/.commit-flag" # 清旗标须在造债提交之后：post-commit 钩子会重建 flag，先删无效（ocr high）
  DBG="$R/.review-loop/plugin-debug.log" # A/B 同仓 cwd → 共享 debug 日志，按 claimed-by=sid 与注入计数区分
  tmux kill-session -t $SA 2>/dev/null; tmux new-session -d -s $SA -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_COOLDOWN_S=10 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $SA "把 hello.ts 里的函数名 hello 改成 greet，不要提交任何文件。在收到自动评审提醒之前，不要自己运行 /review-loop；收到提醒后也不要执行评审，直接执行 git checkout hello.ts 撤销刚才的修改，然后回复 ok 两个字母。"
  if ! wait_log "$DBG" "injected OK" $WAIT; then
    log "  ❌ S12 A 首次注入超时（$WAIT s）"; tail -5 "$DBG" 2>/dev/null | tee -a "$LOG"; FAIL=$((FAIL+1)); tmux kill-session -t $SA 2>/dev/null; rm -rf "$R"; return
  fi
  assert "S12a A gates PASS 会话编辑欠债注入（持有认领；2026-10-17：commit 信号仅为范围）" grep -aq "gates PASS" "$DBG"
  if ! wait_log "$R/.review-loop/.scope-claim.json" "sessionID" 30; then
    log "  ❌ S12b scope-claim 未落盘"; FAIL=$((FAIL+1)); tmux kill-session -t $SA 2>/dev/null; rm -rf "$R"; return
  fi
  assert "S12b scope-claim 三字段齐全（root/sessionID/claimed_at）" bash -c "grep -aq '\"root\":\"$R\"' '$R/.review-loop/.scope-claim.json' && grep -aq '\"sessionID\":\"ses_' '$R/.review-loop/.scope-claim.json' && grep -aq '\"claimed_at\":' '$R/.review-loop/.scope-claim.json'"
  ASID=$(grep -ao '"sessionID":"[^"]*"' "$R/.review-loop/.scope-claim.json" | head -1 | cut -d'"' -f4)
  [ -n "$ASID" ] || { log "  ❌ S12 ASID 提取失败"; FAIL=$((FAIL+1)); tmux kill-session -t $SA 2>/dev/null; rm -rf "$R"; return; }
  # A 回落静：无新编辑即无新欠债（2026-10-17 时间轴——A 冷却过期也不会再注入）——短 settle 即可
  sleep 20
  # B：第二实例同仓 idle → 他人新鲜认领 → claim-skip 零注入
  tmux kill-session -t $SB 2>/dev/null; tmux new-session -d -s $SB -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $SB "把 hello.ts 里的函数名 hello 改成 welcome，只改这一个文件，不要提交，不要自己运行 /review-loop，改完直接回复 ok。"
  if ! wait_log "$DBG" "claim-skip" $WAIT; then
    log "  ❌ S12 B 未见 claim-skip（$WAIT s）"; tail -5 "$DBG" 2>/dev/null | tee -a "$LOG"; FAIL=$((FAIL+1)); tmux kill-session -t $SA 2>/dev/null; tmux kill-session -t $SB 2>/dev/null; rm -rf "$R"; return
  fi
  assert "S12c B claim-skip 且认领方为 A（claimed-by=$ASID）" bash -c "grep -aq 'claim-skip.*claimed-by=$ASID' '$DBG'"
  BSID=$(grep -ao 'claim-skip) id=[^ ]*' "$DBG" | head -1 | sed 's/.*id=//')
  assert "S12d B 零注入（sid 归因；A 冷却再注入不计）" bash -c "[ -n '$BSID' ] && ! grep -aq \"injected OK id=$BSID\" '$DBG'"
  # A 消费 flag：新编辑（欠债）+空提交造 flag → A idle 二次注入 → rename-claim 消费 → scope-claim 释放
  tui_send $SA "先用编辑工具把 hello.ts 里当前的函数名改成 greet（禁止用 bash/sed），保持不提交；再执行 git commit --allow-empty -m post-race 建一个空提交，然后回复 ok。不要自己运行 /review-loop；若再收到自动评审提醒也不要执行评审，回复 ok 即可。"
  c=0; for ((i=0; i<300/5; i++)); do # 等消费工件而非注入计数：A 冷却再注入会虚增计数（ocr medium）
    ls "$R"/.review-loop/.commit-flag.claimed-* >/dev/null 2>&1 && { c=1; break; }
    sleep 5
  done
  assert "S12e A 二次注入消费 flag（claimed 工件出现）" test $c -eq 1
  git -C "$R" rev-parse HEAD > "$R/.review-loop/.last-reviewed" # 锚点追平：清欠债防 A 复活认领（须在 claimed 工件出现后＝post-race 已 HEAD，ocr medium 竞态修复）
  gone=0; for ((i=0; i<60/2; i++)); do
    [ ! -f "$R/.review-loop/.scope-claim.json" ] && { gone=1; break; }
    sleep 2
  done
  assert "S12f A 消费 flag 后 scope-claim 释放消失" test $gone -eq 1
  assert "S12g flag 已被消费" bash -c "! test -f $R/.review-loop/.commit-flag"
  tmux kill-session -t $SA 2>/dev/null; tmux kill-session -t $SB 2>/dev/null; rm -rf "$R"
}

s13() {
  local R=/tmp/rl-e2e-s13 S=rls13 DBG
  log "=== S13 规划误投负例（零产品编辑 + 外部欠债 → 零注入；phase2 delegator 回退资格门）==="
  mkrepo "$R" s13
  # 外部欠债夹具（误投形态固化）：外部提交留下的双行 flag + bash 直写脏文件（同 S7a/S6 外部语义）
  mkdir -p "$R/.review-loop"
  { git -C "$R" rev-parse HEAD; echo "origin: external"; } > "$R/.review-loop/.commit-flag"
  printf 'export function leftover() { return 9; }\n' > "$R/leftover.ts"
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  # phase1：仅 .omo/.review-loop 写入 → isOmoPath 过滤 → 零产品编辑 → 既有 gate=edits BLOCK（回归保护）
  tui_send $S "用写文件工具分别创建 .omo/plan/todo.md 和 .review-loop/notes/x.md 两个文件，各写一行文字即可。不要编辑其他任何文件，不要提交，不要运行 /review-loop。"
  DBG="$R/.review-loop/plugin-debug.log"
  wait_log "$DBG" "gate=edits BLOCK" 300 || log "  ⚠ S13 phase1 未捕获 gate=edits BLOCK（可能 idle 未触发，查 TUI）"
  # S13a 接受任一零欠债 BLOCK 行（ag-8128ba 实证：模型会把双文件写入委派给子代理/路径回显
  # 噪音→phase1 不总落在 edits 门——worktree(no debt)/cwd-fallback 同为审慎零欠债裁决；
  # 契约（零注入）由 S13b/S13e 把关，本断言只钉「评估发生且审慎 BLOCK」）
  assert "S13a 仅 .omo/.review-loop 编辑被闸（isOmoPath 过滤→零产品编辑）" bash -c "grep -aqE 'gate=(edits|worktree|cwd-fallback) BLOCK' $DBG 2>/dev/null"
  assert "S13b phase1 零注入" bash -c "! grep -aq 'injected OK' $DBG 2>/dev/null"
  # phase2（fix 回归，2026-10-08 误投形态）：task 派只读子代理 → delegator 过 gate=edits（delegators.has），
  # 但自身+子会话仍零产品编辑 → cwd 回退资格门须 BLOCK。真 TUI 驱动 task()（同 S8/S9 派发约定；
  # 子代理只读约束若被模型违反且写了产品文件，本场景按真实红灯处理，不做 stub 降级）。
  tui_send $S "用 task 工具同步派发一个 general 子代理（禁止 run_in_background，等子代理做完再继续）：让子代理只读统计当前目录 .md 文件的数量并回复数字，不要让它编辑或创建任何文件。子代理返回后，你自己再用写文件工具创建 .omo/plan/step2.md 写一行文字。不要编辑其他任何文件，不要提交，不要运行 /review-loop。"
  wait_log "$DBG" "gate=cwd-fallback BLOCK" $WAIT || log "  ⚠ S13 phase2 未捕获 gate=cwd-fallback BLOCK（$WAIT s）"
  assert "S13d delegator 零等价编辑被 cwd 回退资格门拦截（planish=false hasEquivEdits=false）" grep -aq "gate=cwd-fallback BLOCK (planish=false hasEquivEdits=false)" "$DBG"
  assert "S13e 全程零注入（外部欠债未触发评审）" bash -c "! grep -aq 'injected OK' $DBG 2>/dev/null"
  assert "S13c 外部欠债夹具在案且未消费（红灯有效性前提）" bash -c "[ -f $R/.review-loop/.commit-flag ] && ! ls $R/.review-loop/.commit-flag.claimed-* >/dev/null 2>&1 && [ -n \"\$(git -C $R status --porcelain)\" ]"
  tmux kill-session -t $S 2>/dev/null; rm -rf "$R"
}

s15() {
  # S15 孤儿旗标守卫（2026-10-18）：amend/rebase 使旗上起点成孤儿（非 HEAD 祖先）→
  # 范围不得使用 <孤儿>..HEAD，须落入兜底（dirty tree/session-edited）；旗本体照常消费。
  # 合法起点路径（旗范围正常携带）由 S6a 回归覆盖。
  local R=/tmp/rl-e2e-s15 S=rls15 DBG ORPHAN
  log "=== S15 孤儿旗标：start 非 HEAD 祖先 → 范围弃用落兜底 ==="
  mkrepo "$R" s15
  ORPHAN=$(git -C "$R" commit-tree "$(git -C "$R" rev-parse 'HEAD^{tree}')" -m orphan) # 有效对象、不在任何分支＝非 HEAD 祖先
  mkdir -p "$R/.review-loop"
  { echo "$ORPHAN"; echo "origin: external"; } > "$R/.review-loop/.commit-flag"
  DBG="$R/.review-loop/plugin-debug.log"
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "把 hello.ts 里的函数名 hello 改成 greet，只改这一个文件，不要提交，不要自己运行 /review-loop；收到自动评审提醒后按提醒内容执行评审即可。"
  if ! wait_log "$DBG" "injected OK" $WAIT; then
    log "  ❌ S15 注入超时（$WAIT s）"; tail -5 "$DBG" 2>/dev/null | tee -a "$LOG"; FAIL=$((FAIL+1)); tmux kill-session -t $S 2>/dev/null; rm -rf "$R"; return
  fi
  assert "S15a 孤儿起点不构成范围（无 <orphan>..HEAD）" bash -c "! grep -aq '$ORPHAN..HEAD' '$DBG'"
  assert "S15b 守卫落 debug（flag-start orphan）" grep -aq "flag-start orphan" "$DBG"
  assert "S15c 范围兜底非空（dirty tree/session-edited）" bash -c "grep -a 'gates PASS' '$DBG' | tail -1 | grep -aqE 'dirty tree|session-edited'"
  c=0; for ((i=0; i<60/2; i++)); do # 旗本体照常消费：注入即 rename-claim（守卫不得误挪到消费点之前，S5b/S7a2 同款窗口）
    ls "$R"/.review-loop/.commit-flag.claimed-* >/dev/null 2>&1 && { c=1; break; }
    sleep 2
  done
  assert "S15d 旗本体照常消费（claimed 工件出现且原旗消失）" bash -c "test $c -eq 1 && ! test -f '$R/.review-loop/.commit-flag'"
  tmux kill-session -t $S 2>/dev/null; rm -rf "$R"
}

s14() {
  # S14 boulder defer 非永封（2026-10-11 缺陷修复）：boulder active 时 idle → gate=boulder BLOCK
  # （start-work owns review，临时 defer）；boulder work 完成后同会话再 idle → 必须恢复注入。
  # 老缺陷：boulder 门 return 未解 injected 占位 → 后续 idle 全部 gate=injected.has 永久封口。
  local R=/tmp/rl-e2e-s14 S=rls14 DBG
  log "=== S14 boulder defer 后解除 → 同会话恢复注入 ==="
  mkrepo "$R" s14
  mkdir -p "$R/.omo"
  printf '{"works":{"w1":{"status":"active"}}}' > "$R/.omo/boulder.json"
  tmux kill-session -t $S 2>/dev/null; tmux new-session -d -s $S -x 220 -y 50 "cd $R && MEMORY_PLUGIN_AUTOSTART=0 REVIEW_LOOP_DEBUG=1 REVIEW_LOOP_IDLE_MIN_S=5 XDG_CONFIG_HOME="$RL_CFGROOT" opencode --standalone"
  sleep 15
  tui_send $S "用编辑工具（edit 或 write）把 hello.ts 里的函数名 hello 改成 greet，只改这一个文件，禁止用 bash/sed 改文件，改完提交它（git commit），不要自己运行 /review-loop，提交完直接回复 ok。"
  DBG="$R/.review-loop/plugin-debug.log"
  if ! wait_log "$DBG" "gate=boulder BLOCK" $WAIT; then
    log "  ❌ S14 首轮未捕获 gate=boulder BLOCK（$WAIT s）"; tail -5 "$DBG" 2>/dev/null | tee -a "$LOG"; FAIL=$((FAIL+1)); tmux kill-session -t $S 2>/dev/null; rm -rf "$R"; return
  fi
  assert "S14a boulder active 首轮 defer BLOCK" grep -aq "gate=boulder BLOCK" "$DBG"
  assert "S14b defer 阶段零注入" bash -c "! grep -aq 'injected OK' $DBG 2>/dev/null"
  # boulder work 完成（外部夹具翻转，同 S7a 旗标 bash 直写惯例）→ 同会话再 idle 必须恢复注入
  printf '{"works":{"w1":{"status":"done"}}}' > "$R/.omo/boulder.json"
  tui_send $S "回复 ok 两个字母即可"
  if ! wait_log "$DBG" "injected OK" $WAIT; then
    gl=$(grep -a 'gate=' "$DBG" 2>/dev/null | tail -1)
    log "  ❌ S14 解除后未恢复注入（$WAIT s；封口观察: ${gl:-无闸门行}）"; tail -5 "$DBG" 2>/dev/null | tee -a "$LOG"; FAIL=$((FAIL+1)); tmux kill-session -t $S 2>/dev/null; rm -rf "$R"; return
  fi
  assert "S14c boulder 完成后同会话恢复注入（老缺陷此处 gate=injected.has 永封）" grep -aq "injected OK" "$DBG"
  assert "S14d 恢复注入走正常闸门（gates PASS）" grep -aq "gates PASS" "$DBG"
  assert "S14e scope 含会话仓欠债（flag 范围，root 前缀）" bash -c "grep -a 'gates PASS' '$DBG' | grep -aqF '$R ('"
  tmux kill-session -t $S 2>/dev/null; rm -rf "$R"
}

# ── W 系列：run-with-review 包装器（headless lane）— stub opencode 驱动（2026-10-06）──
# 与 S 系列互补：S=交互 TUI+真实 opencode；W=stub opencode（PATH 前置注入，函数内子壳隔离防泄漏）
# 复用 mkrepo（钩子拷贝自本工件 hooks/＝含 WRAP_ID 捕获的 post-commit）；
# stub 两模式：消息含 /review-loop → 评审模式（prompt 落盘+可控 sleep/退码）；否则工作模式（真实 git commit 落真实旗标）
WRAP="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../run-with-review.sh"
WSTUBBIN="$(mktemp -d)/stubbin" # 逐跑唯一：固定 /tmp 路径可被多用户主机预植入 stub 劫持（2026-11-08 评审 C1）
trap 'rm -rf "$(dirname "$WSTUBBIN")" ${RL_CFGROOT:+"$RL_CFGROOT"}' EXIT # 逐跑唯一伴随逐跑回收：stub 目录无调试价值，防 /tmp 累积（2026-11-08 ocr 轮2）；连带沙箱 config 根（空值跳过＝W-only 跑无沙箱，ocr 轮3）
WENV=()

# ── 场景 serve 配置隔离（ag-8128ba 根因修复）──
# 全局 ~/.config/opencode 携带 agora MCP／superpowers 等，诱导夹具 agent 把场景工作委派给
# agora 子任务（worktree merge 回夹具仓→夹具状态污染，live 首跑 19/61 红的共同根因）。
# 沙箱＝逐跑 mktemp config 根，XDG_CONFIG_HOME 只指给场景会话（`opencode debug paths` 实证
# v2.2.6 遵守；⚠ opencode 自行追加 /opencode——env 必须指 $RL_CFGROOT 父目录，指 $RLCFG
# 会解析到 <root>/opencode/opencode 空目录＝零 config→provider 落默认上游 401）；opencode.json＝全局副本剥 mcp+plugins（保 model/providers/agents 路由与
# permissions allow-all；剥 npm plugins 防离线安装炸弹）；plugins/ 只挂被测插件（套件自定位
# symlink，分支期测 worktree 码）＋open-code-review（注入评审步骤需 ocr_review 工具）；
# command/ 挂 /review-loop（注入提示词要求 agent 执行评审）。node_modules symlink 供 ocr
# 插件的 @opencode-ai/plugin bare import 解析（离线安全，零安装）。
# ⚠ package.json 必须在场（内容任意，private 即可）：实证 v2.2.6 TUI 启动路径下，config 根
# 无 package.json 时自定义 provider 的 settings.baseURL 不生效（请求落 zai 默认上游→401
# token expired）；headless `opencode run` 不受影响。bisect 取证 2026-11-08。
RL_CFGROOT=""; RLCFG="" # 缺省置空：EXIT trap 与底部沙箱日志引用安全（set -u）；W-only 跑不建沙箱（stub opencode 不读 config，ocr 轮3）
SEL="${*:-S1 S2 S3 S4 S16 S6 S7 S8 S9 S10 S11 S12 S13 S14 S15 W1 W2 W3 W4 W5 W6 W7 W8}"
case " $SEL " in
*" S"*)
  RL_SRC_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  RL_CFGROOT="$(mktemp -d "${TMPDIR:-/tmp}/rl-e2e-cfg.XXXXXX")"
  RLCFG="$RL_CFGROOT/opencode"; mkdir -p "$RLCFG/plugins" "$RLCFG/command"
  if ! python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); [c.pop(k,None) for k in ("mcp","plugins")]; json.dump(c,open(sys.argv[2],"w"),indent=2)' "$RL_SRC_CFG/opencode.json" "$RLCFG/opencode.json"; then
    rm -rf "$RL_CFGROOT"; echo "e2e: 沙箱 config 生成失败（缺失或不可读: $RL_SRC_CFG/opencode.json；若为 JSONC（含注释/尾逗号）本套件不解析，需严格 JSON）" >&2; exit 1
  fi
  for dep in plugins/open-code-review.ts node_modules; do # 前置缺失即停：静默跳过会让注入评审缺 ocr_review，红灯不可诊断（ocr 轮3）
    [ -e "$RL_SRC_CFG/$dep" ] || { rm -rf "$RL_CFGROOT"; echo "e2e: 沙箱前置缺失: $RL_SRC_CFG/$dep" >&2; exit 1; }
  done
  printf '{"name":"rl-e2e-sandbox","private":true}\n' > "$RLCFG/package.json"
  ln -sfn "$HOOKSRC/../review-loop-trigger.ts" "$RLCFG/plugins/review-loop-trigger.ts"
  ln -sfn "$HOOKSRC/../command/review-loop.md" "$RLCFG/command/review-loop.md"
  ln -sfn "$RL_SRC_CFG/plugins/open-code-review.ts" "$RLCFG/plugins/open-code-review.ts"
  ln -sfn "$RL_SRC_CFG/node_modules" "$RLCFG/node_modules"
  ;;
esac

mkwstub() { # $1=logdir — 建 stub opencode 与干净 logdir（幂等）
  rm -rf "$1"; mkdir -p "$WSTUBBIN" "$1"
  cat > "$WSTUBBIN/opencode" <<'EOS'
#!/usr/bin/env bash
# e2e W 系列 stub opencode：$1=run $2=msg；评审模式按 /review-loop 关键词识别
msg="${2:-}"
if printf '%s' "$msg" | grep -aq '/review-loop'; then
  n=$(cat "$STUB_LOG_DIR/count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_LOG_DIR/count"
  printf '%s' "$msg" > "$STUB_LOG_DIR/review-prompt-$n.txt"
  [ -n "${STUB_REVIEW_SLEEP:-}" ] && sleep "${STUB_REVIEW_SLEEP}"
  exit "${STUB_REVIEW_RC:-0}"
fi
if [ "${STUB_WORK_NOCOMMIT:-0}" != "1" ]; then
  printf 'export function greet() { return %d; }\n' "${RANDOM:-42}" > hello.ts # 随机内容：多次调用均有真 diff，不依赖时序
  git add hello.ts && git commit -q --allow-empty -m "stub work commit" # --allow-empty：钩子必触发（同轮重复调用免疫）
fi
exit "${STUB_WORK_RC:-0}"
EOS
  chmod +x "$WSTUBBIN/opencode"
}

wrap_run() { # $1=repo 其余=包装器 argv；子壳内 PATH 前置 stub（防泄漏）；WENV 数组经 env 注入
  local R="$1"; shift
  ( export PATH="$WSTUBBIN:$PATH" STUB_LOG_DIR="$WLOG"
    cd "$R" && env "${WENV[@]}" "$WRAP" "$@" )
}

w1() {
  local R=/tmp/rl-e2e-w1 L=/tmp/rl-e2e-w1-log FLAG_SHA wrc
  log "=== W1 有提交→包装器追加评审 run＋消费旗标 ==="
  mkrepo "$R" w1
  rm -f "$R/.review-loop/.commit-flag" # 清 init 旗标：真实入口态＝净仓（无待审），首个未审提交在包装器工作 run 内落旗标
  WLOG="$L"; WENV=(OPENCODE_SESSION_ID=fake-sid); mkwstub "$L" # 伪造会话变量在场：锁定 WRAP_ID 优先序
  wrc=0; wrap_run "$R" run "e2e work" 2>"$L/wrapper-stderr.txt" || wrc=$?
  FLAG_SHA=$(sed -n '1p' "$R/.review-loop/.commit-flag.claimed-"* 2>/dev/null) # 旗标首行＝range 起点（自取自验）
  assert "W1a 退码=工作 run 退码（0，评审附加不污染）" test "$wrc" -eq 0
  assert "W1b 评审 run 恰被追加 1 次" test "$(cat "$L/count" 2>/dev/null || echo 0)" -eq 1
  assert "W1c 旗标已转 .claimed-*（rename-claim 消费）" bash -c "ls $R/.review-loop/.commit-flag.claimed-* >/dev/null 2>&1 && [ ! -f $R/.review-loop/.commit-flag ]"
  assert "W1d claimed origin=本实例 WRAP_ID（伪造 OPENCODE_SESSION 在场仍 WRAP_ID 必胜）" bash -c "grep -aq 'origin: wrap-' $R/.review-loop/.commit-flag.claimed-* && ! grep -aq 'origin: fake-sid' $R/.review-loop/.commit-flag.claimed-*"
  assert "W1e prompt 四要素①真 /review-loop 命令" grep -aq '/review-loop' "$L/review-prompt-1.txt"
  assert "W1f prompt 四要素②显式范围 旗标首行SHA..HEAD（禁 .last-reviewed 推导）" grep -aqF "${FLAG_SHA}..HEAD" "$L/review-prompt-1.txt"
  assert "W1g prompt 四要素③证据目录解析为绝对路径（默认 <root>/.review-loop/）" grep -aqF "$R/.review-loop/" "$L/review-prompt-1.txt"
  assert "W1h prompt 四要素④Trivial 边界与推送纪律" grep -aq 'Trivial' "$L/review-prompt-1.txt"
  # 钩子回退序验证（无 WRAP_ID 时恢复原 grep 行为）：OPENCODE.*SESSION 命中→取值；全无→external
  ( cd "$R" && env -i PATH="$PATH" HOME="$HOME" OPENCODE_SESSION_ID=fake-sid-99 git commit --allow-empty -qm probe1 )
  assert "W1i 钩子无 WRAP_ID 时回退原 grep（origin=OPENCODE 变量值）" bash -c "grep -aq 'origin: fake-sid-99' $R/.review-loop/.commit-flag"
  rm -f "$R/.review-loop/.commit-flag"
  ( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git commit --allow-empty -qm probe2 )
  assert "W1j 钩子无任何会话变量→origin=external（external 回退保留）" bash -c "grep -aq 'origin: external' $R/.review-loop/.commit-flag"
  rm -rf "$R"
}

w2() {
  local R=/tmp/rl-e2e-w2 L=/tmp/rl-e2e-w2-log wrc
  log "=== W2 无旗标→评审 stub 零追加 ==="
  mkrepo "$R" w2
  rm -rf "$R/.review-loop" # 预清 init 旗标：真「无旗标」前提
  WLOG="$L"; WENV=(STUB_WORK_NOCOMMIT=1); mkwstub "$L"
  wrc=0; wrap_run "$R" run "no-op work" 2>"$L/wrapper-stderr.txt" || wrc=$?
  assert "W2a 退码=工作 run 退码（0）" test "$wrc" -eq 0
  assert "W2b 评审 stub 零调用" bash -c "! test -f $L/review-prompt-1.txt && ! test -f $L/count"
  assert "W2c 无消费痕迹" bash -c "! ls $R/.review-loop/.commit-flag* >/dev/null 2>&1"
  rm -rf "$R"
}

w3() {
  local R=/tmp/rl-e2e-w3 L=/tmp/rl-e2e-w3-log wrc
  log "=== W3 陈旧旗标（mtime 回拨）→不消费 ==="
  mkrepo "$R" w3
  rm -rf "$R/.review-loop"; mkdir -p "$R/.review-loop"
  { git -C "$R" rev-parse HEAD; echo "origin: wrap-stale-probe"; } > "$R/.review-loop/.commit-flag"
  touch -d '1 hour ago' "$R/.review-loop/.commit-flag" # 回拨：确保落 mtime 门（隔离测陈旧分支）
  WLOG="$L"; WENV=(STUB_WORK_NOCOMMIT=1); mkwstub "$L"
  wrc=0; wrap_run "$R" run "e2e work" 2>"$L/wrapper-stderr.txt" || wrc=$?
  assert "W3a 陈旧旗标原样保留（不消费）" bash -c "grep -aq 'wrap-stale-probe' $R/.review-loop/.commit-flag && ! ls $R/.review-loop/.commit-flag.claimed-* >/dev/null 2>&1"
  assert "W3b 评审 stub 零调用" bash -c "! test -f $L/review-prompt-1.txt"
  assert "W3c stderr 记录 stale 跳过" grep -aq 'stale' "$L/wrapper-stderr.txt"
  rm -rf "$R"
}

w4() {
  local R=/tmp/rl-e2e-w4 L=/tmp/rl-e2e-w4-log wrc
  log "=== W4 异源旗标（origin=他会话）→不消费+stderr 记录 ==="
  mkrepo "$R" w4
  rm -rf "$R/.review-loop"; mkdir -p "$R/.review-loop"
  { git -C "$R" rev-parse HEAD; echo "origin: other-session-x"; } > "$R/.review-loop/.commit-flag"
  touch -d '+5 minutes' "$R/.review-loop/.commit-flag" # 未来时刻锚定：确保过 mtime 门，隔离测 origin 门
  WLOG="$L"; WENV=(STUB_WORK_NOCOMMIT=1); mkwstub "$L"
  wrc=0; wrap_run "$R" run "e2e work" 2>"$L/wrapper-stderr.txt" || wrc=$?
  assert "W4a 异源旗标原样保留（不消费）" bash -c "grep -aq 'other-session-x' $R/.review-loop/.commit-flag && ! ls $R/.review-loop/.commit-flag.claimed-* >/dev/null 2>&1"
  assert "W4b 评审 stub 零调用" bash -c "! test -f $L/review-prompt-1.txt"
  assert "W4c stderr 记录 origin mismatch" grep -aq 'origin mismatch' "$L/wrapper-stderr.txt"
  rm -rf "$R"
}

w5() {
  local R=/tmp/rl-e2e-w5 LA=/tmp/rl-e2e-w5a-log LB=/tmp/rl-e2e-w5b-log wrc
  log "=== W5 评审超时/非零→退码=工作 run 退码（不污染）==="
  mkrepo "$R" w5
  rm -f "$R/.review-loop/.commit-flag" # 清 init 旗标：净仓入口态（同 W1；b 轮旗标已被 a 轮消费，hook 在 b 轮提交时自建）
  # a：评审超时（TIMEOUT=1s + stub sleep 5 → TERM），工作 run 退码 3
  WLOG="$LA"; WENV=(STUB_WORK_RC=3 REVIEW_LOOP_TIMEOUT=1 STUB_REVIEW_SLEEP=5); mkwstub "$LA"
  wrc=0; wrap_run "$R" run "timeout probe" 2>"$LA/wrapper-stderr.txt" || wrc=$?
  assert "W5a 超时被有界终止且退码仍=工作 run 退码 3" test "$wrc" -eq 3
  assert "W5b 评审确已追加（超时前已收到 prompt）" test -f "$LA/review-prompt-1.txt"
  assert "W5c stderr 记录非阻塞超时（rc=124）" grep -aq 'rc=124' "$LA/wrapper-stderr.txt"
  # b：评审非零（stub 退 7），工作 run 退码 5
  WLOG="$LB"; WENV=(STUB_WORK_RC=5 STUB_REVIEW_RC=7); mkwstub "$LB"
  wrc=0; wrap_run "$R" run "nonzero probe" 2>"$LB/wrapper-stderr.txt" || wrc=$?
  assert "W5d 评审非零不影响退码（=工作 run 退码 5）" test "$wrc" -eq 5
  assert "W5e stderr 记录评审非零（rc=7）" grep -aq 'rc=7' "$LB/wrapper-stderr.txt"
  rm -rf "$R"
}

w6() {
  local R=/tmp/rl-e2e-w6 L=/tmp/rl-e2e-w6-log wrc
  log "=== W6 REVIEW_LOOP_EVIDENCE_DIR 重定向（相对路径解析为绝对）==="
  mkrepo "$R" w6
  rm -f "$R/.review-loop/.commit-flag" # 清 init 旗标：净仓入口态（同 W1）
  WLOG="$L"; WENV=(REVIEW_LOOP_EVIDENCE_DIR=ev-rel); mkwstub "$L" # 相对路径：验证包装器解析为绝对路径
  wrc=0; wrap_run "$R" run "evidence probe" 2>"$L/wrapper-stderr.txt" || wrc=$?
  assert "W6a 评审已追加" test -f "$L/review-prompt-1.txt"
  assert "W6b prompt 含相对 env 解析后的绝对路径" grep -aqF "$R/ev-rel" "$L/review-prompt-1.txt"
  assert "W6c 证据目录已由包装器建好" test -d "$R/ev-rel"
  rm -rf "$R"
}

w7() {
  local R=/tmp/rl-e2e-w7 L=/tmp/rl-e2e-w7-log wrc
  log "=== W7 防递归：REVIEW_LOOP_HEADLESS=1→纯透传不追加 ==="
  mkrepo "$R" w7
  WLOG="$L"; WENV=(REVIEW_LOOP_HEADLESS=1); mkwstub "$L" # 工作 stub 正常提交（落真实旗标）
  wrc=0; wrap_run "$R" run "headless probe" 2>"$L/wrapper-stderr.txt" || wrc=$?
  assert "W7a 透传退码=工作 run 退码（0）" test "$wrc" -eq 0
  assert "W7b 旗标原样保留（透传不扫描不消费）" test -f "$R/.review-loop/.commit-flag"
  assert "W7c 评审 stub 零调用" bash -c "! test -f $L/review-prompt-1.txt"
  rm -rf "$R"
}

w8() {
  local R=/tmp/rl-e2e-w8 L=/tmp/rl-e2e-w8-log wrc
  log "=== W8 空旗标（旧 touch 式）→删除跳过 ==="
  mkrepo "$R" w8
  rm -rf "$R/.review-loop"; mkdir -p "$R/.review-loop"
  : > "$R/.review-loop/.commit-flag"
  WLOG="$L"; WENV=(STUB_WORK_NOCOMMIT=1); mkwstub "$L"
  wrc=0; wrap_run "$R" run "empty flag probe" 2>"$L/wrapper-stderr.txt" || wrc=$?
  assert "W8a 空旗标已删除（非 claimed 改名）" bash -c "! ls $R/.review-loop/.commit-flag* >/dev/null 2>&1"
  assert "W8b 评审 stub 零调用" bash -c "! test -f $L/review-prompt-1.txt"
  assert "W8c stderr 记录空旗标处置" grep -aq 'empty legacy flag' "$L/wrapper-stderr.txt"
  rm -rf "$R"
}


log "review-loop 信号重设计 e2e — $TS（S1/S5 合并执行）"
[ -n "$RLCFG" ] && log "config 沙箱: $RLCFG（全局副本剥 mcp/plugins；场景 serve 不继承 agora 等 MCP 面）"
for s in $SEL; do
  case "$s" in W*) "w${s#W}" ;; *) "s${s#S}" ;; esac
done
cat "$LOG" 2>/dev/null | tail -40
log "==== 结果: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
