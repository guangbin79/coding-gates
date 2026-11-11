#!/usr/bin/env bash
# req-gate-path-selftest.sh — req-gate-enforcer 快检状态目录自检（自 dotfiles 随源迁入；ag-27b4c2/ag-97c988）
# 断言：①插件可加载（bun import，default export id 正确）
#      ②豁免：.omo（legacy）、.req-gate（legacy 仓内）与 tmp 快检目录各形态写路径不触发闸
#      ③产品编辑：无记录 BLOCK（含穿越形态）→ 写 <TMPDIR>/opencode/req-gate/<sid>.md 后 PASS
#      ④源面：功能性仓内状态路径（${dir}/.omo、${dir}/.req-gate）不得残留；tmp 新路径就位
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/req-gate/req-gate-enforcer.ts"
command -v bun >/dev/null 2>&1 || { echo "req-gate-path-selftest: bun unavailable, abort"; exit 127; }
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/req-gate-selftest.XXXXXX")"
TMPROOT="${TMPDIR:-/tmp}"; TMPROOT="${TMPROOT%/}"
SID="ses_selftest$(date +%s)_$$" # 每次运行唯一 SID：免并发/残留互毒（记录落机器共享 tmp）
# trap 清场（路径须与 behavior.ts 写入的 "$SID.md" 一致）
trap 'rm -rf "$SCRATCH" "$TMPROOT/opencode/req-gate/$SID.md"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ① 加载
cat > "$SCRATCH/load.ts" <<EOF
const m = await import("$PLUGIN");
if (m.default?.id !== "req-gate-enforcer") { console.error("bad default export"); process.exit(1); }
EOF
if bun run "$SCRATCH/load.ts" >/dev/null 2>&1; then ok "插件可加载（bun import，default export）"; else bad "插件加载失败"; fi

# ②③ 行为：假 ctx 捕获 execute.before 回调，直接驱动三态
cat > "$SCRATCH/behavior.ts" <<EOF
import { mkdirSync, writeFileSync } from "node:fs";
const DIR = "$SCRATCH/repo";
const SID = "$SID";
const TMP = "$TMPROOT";
let cb: any = null;
const ctx: any = {
  tool: { hook: (ev: string, f: any) => { if (ev === "execute.before") cb = f; } },
  session: {
    get: async () => ({ agent: "", parentID: null, location: { directory: DIR } }),
    context: async () => [],
  },
};
const m = await import("$PLUGIN");
m.default.setup(ctx);
if (typeof cb !== "function") { console.error("execute.before hook not registered"); process.exit(1); }
const call = (p: string) => cb({ tool: "edit", sessionID: SID, input: { filePath: p } });
const exempt = [
  ".omo/x.md", ".omo/req-gate/legacy.md", "/abs/.omo/x.md",
  ".req-gate/x.md", ".req-gate/" + SID + ".md", "/abs/.req-gate/x.md", "/abs/./.req-gate/x.md",
  ".req-gate/sub/../" + SID + ".md", // 折叠必须保形：内部 .. 收敛回豁免目录，防自闸回归
  TMP + "/opencode/req-gate/" + SID + ".md", TMP + "/opencode/req-gate/x.md",
];
for (const p of exempt) {
  try { await call(p); } catch { console.error("exempt path gated: " + p); process.exit(2); }
}
// 无记录 → BLOCK（含穿越形态：字符串命中豁免段但解析后落在豁免目录外）
let blocked = false;
try { await call("src/a.ts"); } catch { blocked = true; }
let travBlocked = false;
try { await call(".req-gate/../src/a.ts"); } catch { travBlocked = true; }
let overBlocked = false;
try { await call("/abs/.req-gate/../../src/a.ts"); } catch { overBlocked = true; }
let bsBlocked = false;
try { await call(".req-gate\\..\\src\\a.ts"); } catch { bsBlocked = true; }
let tmpTravBlocked = false;
try { await call(TMP + "/opencode/req-gate/../src/a.ts"); } catch { tmpTravBlocked = true; }
let tmpRelBlocked = false;
try { await call(TMP.replace(/^\//, "") + "/opencode/req-gate/src/a.ts"); } catch { tmpRelBlocked = true; } // 仓内相对同形路径不得借 tmp 豁免逃闸
if (!blocked || !travBlocked || !overBlocked || !bsBlocked || !tmpTravBlocked || !tmpRelBlocked) { console.error("product edit not blocked without record (plain/traversal/overflow/backslash/tmp-traversal/tmp-relative)"); process.exit(3); }
// 写 tmp 快检记录 → PASS
mkdirSync(TMP + "/opencode/req-gate", { recursive: true });
writeFileSync(TMP + "/opencode/req-gate/" + SID + ".md", "record\n");
try { await call("src/a.ts"); } catch { console.error("still blocked with record"); process.exit(4); }
console.log("behavior-ok");
EOF
if out="$(bun run "$SCRATCH/behavior.ts" 2>&1)"; then
  ok "豁免三目录（.omo/.req-gate/tmp 快检目录）＋无记录 BLOCK→写 tmp 记录 PASS"
else
  bad "行为断言失败: $out"
fi

# ④ 源面：功能性仓内状态路径（.omo 与退役 .req-gate）不得残留
if grep -nE '\$\{dir\}/\.(omo|req-gate)|\.(omo|req-gate)/req-gate/' "$PLUGIN" >/dev/null 2>&1; then
  bad "插件源残留功能性仓内状态路径: $(grep -nE '\$\{dir\}/\.(omo|req-gate)|\.(omo|req-gate)/req-gate/' "$PLUGIN")"
else
  ok "插件源无功能性仓内状态路径残留（.omo/.req-gate 仅存豁免分支）"
fi
if grep -q 'TMPDIR' "$PLUGIN" && grep -q 'opencode/req-gate' "$PLUGIN" \
   && grep -q 'RECORD_DIR}/\${id}\.md' "$PLUGIN" && grep -q 'RECORD_DIR}/gate-debug\.log' "$PLUGIN"; then
  ok "tmp 快检路径 <TMPDIR>/opencode/req-gate/<sid>.md 与 gate-debug.log 就位"
else
  bad "tmp 新路径未就位"
fi

echo "----------------------------------------"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
