#!/usr/bin/env bash
# install.sh — coding-gates 开发闸安装器：./install.sh req-gate | review-loop
# 双目标以 symlink 部署插件/命令/CLI 进 ~/.config/opencode 与 ~/.local/bin。
# 守卫纪律：目标已存在且 readlink -f 后不指向本仓 → 拒绝覆盖 exit 1；
# 指向本仓或不存在 → 幂等建链。
set -euo pipefail

usage() {
  echo "usage: ./install.sh req-gate | review-loop" >&2
  exit 1
}

[ $# -eq 1 ] || usage

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGINS="$HOME/.config/opencode/plugins"
COMMANDS="$HOME/.config/opencode/commands"
BIN="$HOME/.local/bin"

# link <链接落点> <仓内源>：守卫＋幂等建链
link() {
  local dest="$1" src="$2" cur
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    cur="$(readlink -f "$dest")"
    case "$cur" in
      "$REPO"|"$REPO"/*) ;;
      *)
        echo "拒绝覆盖：$dest（指向 $cur）。接管请确认后手工处理或删除后重跑" >&2
        exit 1
        ;;
    esac
  fi
  ln -sfn "$src" "$dest"
}

case "$1" in
  req-gate)
    link "$PLUGINS/req-gate-enforcer.ts" "$REPO/req-gate/req-gate-enforcer.ts"
    link "$COMMANDS/req-gate.md" "$REPO/req-gate/command.md"
    link "$BIN/req-check" "$REPO/req-gate/req-check"
    ;;
  review-loop)
    # hooks 不部署：插件启动自检 ensureHooks 幂等自动配 core.hooksPath
    link "$PLUGINS/review-loop-trigger.ts" "$REPO/review-loop/review-loop-trigger.ts"
    link "$COMMANDS/review-loop.md" "$REPO/review-loop/command/review-loop.md"
    ;;
  *) usage ;;
esac
