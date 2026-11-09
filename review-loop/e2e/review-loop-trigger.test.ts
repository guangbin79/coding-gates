// review-loop-trigger.test.ts — 欠债账本三断言冒烟（gt-f23e94 裁决产物随迁，ag-9901d0）：
// a. R1 .review-loop/ 子树工件写入不计产品编辑 → 不重振欠债、不注入、零落盘；
// b. R2+R3 证据 mtime 晚于编辑 → 欠债读假 → 无审计落盘、不注入；
// c. 评审后的真实新产品编辑 → 欠债读真 → 审计落盘＋注入路径保持既有行为。
// 源：dotfiles .agent/opencode/plugins/review-loop-trigger.test.ts（该残件已随 9d7f8bd 删除，
//     自 git 历史恢复后适配本仓 review-loop/review-loop-trigger.ts）。
// 适配：execute.after 观察成功落定的工具写入（文件必已存在，ag-8128ba existsSync 守卫）——
//     触发钩子前先落盘，与真实工具完成时序一致（源残件先钩后写，落旧插件时序）。
// 运行：cd 仓根 && bun review-loop/e2e/review-loop-trigger.test.ts（自建临时 git 仓，不触真实配置）
import { execFileSync } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { setTimeout as sleep } from "node:timers/promises"
import assert from "node:assert"

mkdirSync("/tmp/opencode", { recursive: true })
const root = mkdtempSync("/tmp/opencode/rlt-test-")
execFileSync("git", ["init", "-q", root]) // 欠债判定需仓根解析（rev-parse），夹具独立成仓
process.env.REVIEW_LOOP_COOLDOWN_S = "0"
process.env.REVIEW_LOOP_IDLE_MIN_S = "0" // =0 即恢复即时评估语义（免等 10s）
process.env.REVIEW_LOOP_DEBUG = "1" // 负例断言读 plugin-debug.log（插件约定）
delete process.env.REVIEW_LOOP_OFF
const origCwd = process.cwd()
process.chdir(root) // ensureHooks 的 core.hooksPath 只可能写进临时仓，绝不触真实仓

let pushEvent = () => {}
const hookFns = new Map()
const prompts = []
const { default: plugin } = await import("../review-loop-trigger.ts")

const cleanup = plugin.setup({
  session: {
    get: async () => ({ parentID: null, location: { directory: root } }),
    switchAgent: async () => ({}),
    prompt: async (p) => {
      prompts.push(p)
      return {}
    },
    context: async () => [],
  },
  event: {
    subscribe: async function* () {
      while (true) yield await new Promise((r) => (pushEvent = r))
    },
  },
  tool: {
    hook: (name, fn) => hookFns.set(name, fn),
  },
})

// execute.after＝成功落定后的观察面——先落盘再触发钩子（适配见文件头）
const edit = (sid, filePath) => {
  writeFileSync(filePath, "x")
  hookFns.get("execute.after")({ tool: "edit", sessionID: sid, input: { filePath } })
}
const writeVia = (sid, filePath) => {
  writeFileSync(filePath, "x")
  hookFns.get("execute.after")({ tool: "write", sessionID: sid, input: { filePath, content: "x" } })
}
const waitFor = async (cond, ms = 15_000) => {
  const deadline = Date.now() + ms
  while (!cond()) {
    if (Date.now() > deadline) return false
    await sleep(50)
  }
  return true
}
const complete = async (sid) => {
  pushEvent({ type: "session.execution.succeeded", data: { sessionID: sid } })
  // 评估落定同步：本会话决策行（gate=* BLOCK / gates PASS）落日志（e2e S13 同款教训：
  // 固定 sleep 掺负载抖动，git 子进程往返在忙机上可超预算）
  await waitFor(() => dbgLog().includes(`id=${sid}`))
}
const auditPath = join(root, ".review-loop/session-edits.json")
const dbgLog = () => {
  try {
    return readFileSync(join(root, ".review-loop/plugin-debug.log"), "utf-8")
  } catch {
    return ""
  }
}

await sleep(100) // 事件泵就位

try {
  // a. .review-loop/ 内工件写入不计产品编辑、不重振欠债：评审环自写工件（钩子观察面）单独出现，
  //    修复前会被记成产品编辑且 lastReviewTs=0 → 注入自催；修复后必须零注入、零落盘。
  const sidA = "ses_aaaaaaaa1"
  writeVia(sidA, join(root, ".review-loop/step1-ses_aaaa.md"))
  await complete(sidA)
  assert.strictEqual(prompts.length, 0, "review-loop artifact write must not create debt/inject")
  assert.ok(!existsSync(auditPath), "artifact-only evaluation must not write session-edits.json")
  assert.match(dbgLog(), /gate=edits BLOCK id=ses_aaaaaaaa1/)

  // b. 证据 mtime 晚于编辑 → 欠债读假：真实编辑在前、评审证据在后 → 不注入，且无债评估零落盘
  // （R3 钉死：成员门已过、冷却门已过，旧实现必在此写审计；现必须无审计落盘）。
  const sidB = "ses_bbbbbbbb2"
  edit(sidB, join(root, "lib.ts"))
  await sleep(50) // 文件 mtime 走 coarse clock（滞后细时钟约 1-4ms）——真实时隔保证证据 mtime 晚于 editTs
  writeFileSync(join(root, ".review-loop/step5-ses_bbbb.md"), "evidence\n")
  await complete(sidB)
  assert.strictEqual(prompts.length, 0, "evidence newer than edits must read debt-free")
  assert.ok(!existsSync(auditPath), "debt-free evaluation must not write audit (R3)")
  assert.match(dbgLog(), /gate=worktree BLOCK.*id=ses_bbbbbbbb2/)

  // c. 评审后的真实新产品编辑 → 欠债读真 → 审计落盘＋注入保持既有行为；混入的评审环工件
  //    不得进 audit.edited（R1 在审计面上的投影）。
  const sidC = "ses_cccccccc3"
  writeFileSync(join(root, ".review-loop/step5-ses_cccc.md"), "evidence\n")
  const past = new Date(Date.now() - 60_000)
  utimesSync(join(root, ".review-loop/step5-ses_cccc.md"), past, past) // 证据明确早于新编辑
  writeVia(sidC, join(root, ".review-loop/step6-ses_cccc.md")) // 评审环工件混入
  edit(sidC, join(root, "app.ts")) // 评审之后的真实产品编辑
  await complete(sidC)
  await waitFor(() => prompts.length >= 1 && existsSync(join(root, `.review-loop/.injected-${sidC}`))) // gates PASS 行先于 inject 完成——注入副作用各自到位再断言
  assert.strictEqual(prompts.length, 1, "real product edit after review must reinject exactly once")
  assert.strictEqual(prompts[0].sessionID, sidC)
  assert.ok(prompts[0].text.includes(root), "scope must carry the debt root")
  assert.match(prompts[0].text, /session-edited: app\.ts/)
  assert.ok(existsSync(join(root, `.review-loop/.injected-${sidC}`)), "marker must be touched (既有注入语义)")
  const audit = JSON.parse(readFileSync(auditPath, "utf-8"))
  assert.strictEqual(audit.sessionID, sidC)
  assert.deepStrictEqual(audit.edited, [join(root, "app.ts")], "audit must list only real product edits")
  assert.strictEqual((dbgLog().match(/gates PASS/g) || []).length, 1, "exactly one injection decision overall")

} finally {
  try {
    cleanup?.()
  } catch {
    /* noop */
  }
  process.chdir(origCwd)
  rmSync(root, { recursive: true, force: true }) // 断言失败也清夹具（终闸B册suggestion①：失败路径零残留）
}
console.log("review-loop-trigger ledger smoke: PASS")
