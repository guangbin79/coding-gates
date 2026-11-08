#!/usr/bin/env bash
# run-with-review.sh — headless opencode run 包装器：工作 run 退出后追加一次有界 review-loop
# 规范入口与判据：module/review-loop.md「headless lane（包装器路径）」
# 调用形态：run-with-review.sh run <flags> <message>（argv 透传 opencode "$@"，不重复拼接 run）
# 设计：进程级编排替代插件注入——绕开 headless 进程退出即丢注入的已知竞速；插件零改动
set -u

tag="[run-with-review]"

# 防递归第一重：检测到上层 headless 编排（本包装器追加的评审 run 即注入此变量）→ 纯透传
if [ "${REVIEW_LOOP_HEADLESS:-0}" = "1" ]; then
  exec opencode "$@"
fi

wrap_id="wrap-$$-$(date +%s)"
start_epoch=$(date +%s)

# 工作 run：stdin/stdout/stderr 直连；不以 set -e 围住，显式捕原退出码
REVIEW_LOOP_WRAP_ID="$wrap_id" opencode "$@"
rc=$?

# 仓根解析（失败退回 cwd）；仅本仓范围，不跨多仓扫描
root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"
flag="$root/.review-loop/.commit-flag"

if [ -f "$flag" ]; then
  if [ ! -s "$flag" ]; then
    # 空旗标＝旧 touch 式残留（模块排障处方 #1）：删除跳过，下次提交重建带范围版
    rm -f "$flag"
    echo "$tag empty legacy flag removed, skip review append" >&2
    exit "$rc"
  fi
  # 双门（防跨会话盗窃）：mtime ≥ 本包装器启动时刻 且 origin 归属本实例
  flag_epoch=$(stat -c %Y "$flag" 2>/dev/null || echo 0)
  origin_line=$(sed -n '2p' "$flag")
  flag_origin="${origin_line#origin: }"
  if [ "$flag_epoch" -lt "$start_epoch" ]; then
    echo "$tag stale flag (mtime < wrapper start), skip — 由交互会话 W2 水平触发兜底" >&2
  elif [ "$flag_origin" != "$wrap_id" ]; then
    echo "$tag flag origin mismatch (origin: ${flag_origin:-<missing>}), skip — 由交互会话 W2 水平触发兜底" >&2
  else
    start_sha=$(sed -n '1p' "$flag")
    # 消费＝rename-claim（POSIX 原子，at-most-once；claimed 残留由 groom TTL 兜底）
    claimed="$flag.claimed-$$-$(date +%s)"
    if mv "$flag" "$claimed" 2>/dev/null; then
      # 证据目录由包装器解析为绝对路径并内嵌 prompt（默认 <root>/.review-loop/）
      ev_dir_abs=$(realpath -m "${REVIEW_LOOP_EVIDENCE_DIR:-$root/.review-loop/}")
      mkdir -p "$ev_dir_abs"
      prompt="执行 /review-loop 评审-修复循环，四要素：①必须真正执行 /review-loop 命令本身；②评审范围显式固定为 ${start_sha}..HEAD，禁止用 .review-loop/.last-reviewed 推导范围；③评审证据文件一律写入 ${ev_dir_abs}/ 目录（已解析绝对路径）；④发现的问题按 /review-loop 命令自身的 Trivial 边界与推送纪律修复，禁止 push/merge。"
      # 防递归第二重：评审 run 环境注入 REVIEW_LOOP_HEADLESS=1；有界执行（TERM 后 5s KILL），超时/非零非阻塞
      REVIEW_LOOP_HEADLESS=1 timeout -k 5 "${REVIEW_LOOP_TIMEOUT:-1800}" opencode run "$prompt"
      rrc=$?
      [ "$rrc" -ne 0 ] && echo "$tag review run rc=$rrc (non-blocking, work rc preserved)" >&2
    else
      echo "$tag rename-claim lost race, flag taken by another consumer" >&2
    fi
  fi
fi

# 以工作 run 原退出码退出，评审附加不污染退码
exit "$rc"
