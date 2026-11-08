#!/usr/bin/env bash
# install_sandbox.sh — install.sh 离线自测：沙箱 HOME=mktemp，
# 断言双目标部署落点/幂等重跑/异源守卫，passed=N failed=M，FAIL 非零退出。
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
passed=0 failed=0

pass() { passed=$((passed + 1)); }
fail() { failed=$((failed + 1)); echo "FAIL: $*"; }

# points_into_repo <路径>：readlink -f 后落在本仓内
points_into_repo() {
  local cur
  cur="$(readlink -f "$1" 2>/dev/null)" || return 1
  case "$cur" in "$REPO"|"$REPO"/*) return 0 ;; esac
  return 1
}

SBX="$(mktemp -d)"
SBX2="$(mktemp -d)"
trap 'rm -rf "$SBX" "$SBX2"' EXIT

# ---- 1. req-gate 沙箱部署：退出 0，三 symlink 存在且落在本仓 ----
if HOME="$SBX" bash "$REPO/install.sh" req-gate >/dev/null 2>&1; then
  pass
else
  fail "req-gate install 退出 0"
fi
for f in \
  "$SBX/.config/opencode/plugins/req-gate-enforcer.ts" \
  "$SBX/.config/opencode/commands/req-gate.md" \
  "$SBX/.local/bin/req-check"; do
  if points_into_repo "$f"; then pass; else fail "req-gate symlink 落在本仓: $f"; fi
done

# ---- 2. req-gate 幂等重跑 ----
if HOME="$SBX" bash "$REPO/install.sh" req-gate >/dev/null 2>&1; then
  pass
else
  fail "req-gate 幂等重跑退出 0"
fi

# ---- 3. req-gate 异源守卫：预置异源目标 → 退出 1 且输出含拒绝覆盖 ----
# 先摘本仓链接再落异源文件——直接 echo > 会沿 symlink 写穿污染仓内源
mkdir -p "$SBX/.config/opencode/plugins"
rm -f "$SBX/.config/opencode/plugins/req-gate-enforcer.ts"
echo foreign > "$SBX/.config/opencode/plugins/req-gate-enforcer.ts"
out="$(HOME="$SBX" bash "$REPO/install.sh" req-gate 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '拒绝覆盖'; then
  pass
else
  fail "req-gate 异源目标拒绝覆盖 (rc=$rc)"
fi

# ---- 4. review-loop 同款三查（部署 2 symlink）----
if HOME="$SBX2" bash "$REPO/install.sh" review-loop >/dev/null 2>&1; then
  pass
else
  fail "review-loop install 退出 0"
fi
for f in \
  "$SBX2/.config/opencode/plugins/review-loop-trigger.ts" \
  "$SBX2/.config/opencode/commands/review-loop.md"; do
  if points_into_repo "$f"; then pass; else fail "review-loop symlink 落在本仓: $f"; fi
done
if HOME="$SBX2" bash "$REPO/install.sh" review-loop >/dev/null 2>&1; then
  pass
else
  fail "review-loop 幂等重跑退出 0"
fi
mkdir -p "$SBX2/.config/opencode/plugins"
rm -f "$SBX2/.config/opencode/plugins/review-loop-trigger.ts"
echo foreign > "$SBX2/.config/opencode/plugins/review-loop-trigger.ts"
out="$(HOME="$SBX2" bash "$REPO/install.sh" review-loop 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '拒绝覆盖'; then
  pass
else
  fail "review-loop 异源目标拒绝覆盖 (rc=$rc)"
fi

echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]
