#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PLUGINS_DIR="$HOME/.config/opencode/plugins"
COMMANDS_DIR="$HOME/.config/opencode/commands"

cmd_install() {
  mkdir -p "$PLUGINS_DIR"
  ln -sfn "$HOME/.dotfiles/.agent/opencode/plugins/review-loop-trigger.ts" "$PLUGINS_DIR/review-loop-trigger.ts"  # 裁定 2026-10-11：canonical mounts 源（钉主仓，worktree 会移除）
  if [ -L "$COMMANDS_DIR" ]; then
    echo "skip command symlink: $COMMANDS_DIR is a shared directory symlink -> $(readlink "$COMMANDS_DIR")"
  else
    mkdir -p "$COMMANDS_DIR"
    ln -sfn "$ROOT/command/review-loop.md" "$COMMANDS_DIR/review-loop.md"
  fi
  echo "installed: machine symlinks -> $ROOT"
}

cmd_enroll() {
  local repo="$1" xl excl
  git -C "$repo" config core.hooksPath "$ROOT/hooks"
  excl="$(git -C "$repo" rev-parse --git-path info/exclude)"; case "$excl" in /*) ;; *) excl="$repo/$excl";; esac  # 兼容 linked worktree/submodule（.git 为文件）：走 commondir 共享 exclude
  mkdir -p "$repo/.review-loop" "$(dirname "$excl")"
  if grep -qxF '.review-loop/' "$excl" 2>/dev/null; then xl='exclude .review-loop/ already present';
  else
    [ -n "$(tail -c1 "$excl" 2>/dev/null)" ] && printf '\n' >>"$excl" || true  # 存量文件无尾换行时先补行首，防拼接
    printf '.review-loop/\n' >>"$excl"; xl='exclude .review-loop/ appended'
  fi
  echo "enrolled: $repo (hooksPath=$ROOT/hooks, marker=$repo/.review-loop, $xl)"
}

cmd_unenroll() {
  local repo="$1"
  local cur
  cur="$(git -C "$repo" config core.hooksPath || true)"
  if [ "$cur" = "$ROOT/hooks" ]; then
    git -C "$repo" config --unset core.hooksPath
  else
    echo "keep hooksPath (${cur:-<unset>}): not managed by this artifact"
  fi
  rm -rf "$repo/.review-loop"
  # F2: 对称回收 enroll 写入的 exclude 行（精确整行匹配 .review-loop/，不动其他行；文件可能不存在→容错跳过）
  local excl xl
  excl="$(git -C "$repo" rev-parse --git-path info/exclude 2>/dev/null || true)"; case "$excl" in /*) ;; *) excl="${excl:+$repo/$excl}";; esac
  if [ -n "$excl" ] && [ -f "$excl" ] && grep -qxF '.review-loop/' "$excl"; then
    # ocr 轮3-4: commondir 共享 exclude——仅当无其它仍 enrolled 的兄弟 worktree 时才移除，防一并解除其忽略
    local siblings=0 wt
    while IFS= read -r wt; do
      if [ "$wt" != "$repo" ] && [ -d "$wt/.review-loop" ]; then siblings=$((siblings+1)); fi
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
    if [ "$siblings" -gt 0 ]; then
      xl="exclude .review-loop/ kept ($siblings sibling worktree(s) still enrolled)"
    else
      # ocr C1: grep -v 全部行被滤除时 rc=1（文件仅含该行）为期望态非错误；仅 rc≥2 视为失败，防「未删却报 removed」
      local grc=0
      grep -vxF -- '.review-loop/' "$excl" >"$excl.unenroll.tmp" || grc=$?
      if [ "$grc" -le 1 ]; then mv "$excl.unenroll.tmp" "$excl"; xl='exclude .review-loop/ removed'
      else rm -f "$excl.unenroll.tmp"; xl='exclude .review-loop/ removal failed (grep rc='$grc')'; fi
    fi
  else
    xl='exclude .review-loop/ not present'
  fi
  echo "unenrolled: $repo ($xl)"
}

cmd_audit() {
  find "$HOME" /HXAppPlatform -maxdepth 3 -name .review-loop 2>/dev/null || true
}

case "${1:-}" in
  install)  cmd_install ;;
  enroll)   cmd_enroll "${2:?usage: install.sh enroll <repo>}" ;;
  unenroll) cmd_unenroll "${2:?usage: install.sh unenroll <repo>}" ;;
  audit)    cmd_audit ;;
  *) echo "usage: install.sh install|enroll <repo>|unenroll <repo>|audit" >&2; exit 1 ;;
esac
