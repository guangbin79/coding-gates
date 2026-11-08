// review-loop-trigger.ts — OpenCode V2 plugin: on session.execution.succeeded,
// nudge the agent to run /review-loop when the session just made product edits
// in a repo (debt semantics superseded 2026-10-17 — operative gates in the
// policy block below).
// Policy 2026-10-17 (user ruling): the debt gate is NO LONGER commit-based —
//   debt = this session[+direct children] made product edits (edit/write observed,
//   timestamped) AFTER its last review-loop (anchor: newest mtime among evidence
//   files `*-<sid8>.md` and the `.injected-<sid>` marker under `${dir}/.review-loop/`).
//   HEAD≠.last-reviewed / .commit-flag are demoted to scope-range carriers (flag
//   consumption & at-most-once semantics unchanged); the 2026-10-16 authority gate
//   is removed (tautological: a debt root necessarily has equiv edits now).
//   Additionally an idle-persistence gate: completion no longer evaluates
//   immediately — gates run only after the session has stayed idle ≥10s
//   (REVIEW_LOOP_IDLE_MIN_S; a newer completion re-arms the timer, so rapid
//   turn-taking never fires).
//
// V2 PORT (2026-10-17): rewritten for the OpenCode 2 plugin API — plain-object
//   default export { id, setup(ctx) } (no @opencode/plugin bare import, see
//   below), hooks via ctx.tool.hook("execute.after"), completion via
//   ctx.event.subscribe() watching session.execution.succeeded (V1's
//   session.idle event no longer exists; V2 events carry payloads under
//   .data, not .properties — probe-verified on 2.0.32), sessions via
//   ctx.session.get/context/prompt (session record reads location.directory,
//   no V1 client wrapper). All V1-only compatibility shims removed.
//
// BUILTIN-ONLY IMPORTS (hard requirement, tightened 2026-09-28):
// ① bare imports (@opencode/*) stay forbidden — this file is symlinked into
//   ~/.config/opencode/plugins/, but its realpath resolves under the dotfiles
//   worktree where no node_modules exists — only node:* builtins resolve there.
//   V2 plain-object export verified equivalent to Plugin.define on 2.0.32.
// ② ALL subprocess/file work goes through node:child_process (execFile,
//   piped) and node:fs — console calls are TTY-direct: all logging (debug +
//   error) appends to plugin-debug.log, never the TTY.
//
// Kill switch: REVIEW_LOOP_OFF=1 makes setup register nothing (plugin inert).
// Uninstall = delete the symlink, or just set REVIEW_LOOP_OFF=1.
//
// REVIEW_LOOP_DEBUG=1: every gate evaluation appends one line to
// ${dir}/.review-loop/plugin-debug.log (directory bootstrapped with
// mkdir -p before the write, so pre-injection gate lines land too).
// Negative assertions read this log: file exists, injection lines = 0.
// W2 水平触发（2026-10-04）：.injected-<sid> 从「存在即永拒」降级为 mtime 冷却（默认 600s，
// REVIEW_LOOP_COOLDOWN_S 可缩短，e2e 用）；欠债门（2026-10-17 时间轴化）＝本会话[+直接子会话]
// 在最后一次 review-loop 后有产品编辑——commit 状态（HEAD≠.last-reviewed / flag）不再构成欠债，
// 仅为 scope 范围携带者（flag 照旧 rename-claim 消费）；scope 用 .last-reviewed..HEAD。
// A 跨会话认领（2026-10-08 15:05 事故修复）：仓级 scope-claim 防 parallel 会话对同一 root 的
//   误注入/误消费——注入前他人新鲜认领（<TTL）→ claim-skip 跳过；认领者每 idle 刷新
//   claimed_at（活性近似）；本会话 rename-claim 消费 .commit-flag 时释放认领，TTL 过期可接管。

import { execFile } from "node:child_process"
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

// 工件自定位（D6 锁步，2026-11-08 提取改单级）：插件文件 realpath 上一级 = 工件根
//（本仓布局 <repo>/review-loop/，module|hooks 与插件同级）；dotfiles 旧布局该派生仍 miss
//（.agent/opencode/ 下无工件）→ existsSync 失败照走 HOME 主仓回退，live 行为不变。
const artifactModule = (() => {
  try {
    const derived = join(dirname(realpathSync(fileURLToPath(import.meta.url))), "module/review-loop.md");
    if (existsSync(derived)) return derived; // 派生根缺工件（live 指旧布局/他仓）→ 回退 HOME 主仓
  } catch {
    /* 派生失败同样回退 */
  }
  return join(homedir(), ".dotfiles/.agent/review-loop/module/review-loop.md");
})();

// W2 水平触发：marker 冷却窗（毫秒）——mtime 距今 < 窗 → 跳过（防 idle 风暴）；过期视为已冷却，
// 欠债门重新裁决，同会话新欠债（新编辑，2026-10-17 时间轴）可再注入，治本「每会话一次」漏触发。
// REVIEW_LOOP_COOLDOWN_S 仅供 e2e/演练缩短窗口；非数字/负数回退默认 600s。
const COOLDOWN_MS = (() => {
  const n = Number.parseInt(process.env.REVIEW_LOOP_COOLDOWN_S ?? "", 10);
  return Number.isSafeInteger(n) && n >= 0 ? n * 1000 : 600_000;
})();

// 空闲门（2026-10-17 用户裁定）：回合完成不立即评估——空闲持续 ≥IDLE_MIN_MS 才跑闸门
// 管线；更近的完成取消并重挂计时（回合间隙的瞬时完成永不触发）。=0 即恢复旧即时语义。
// REVIEW_LOOP_IDLE_MIN_S 仅供 e2e/演练缩短窗口；非数字/负数回退默认 10s。
const IDLE_MIN_MS = (() => {
  const n = Number.parseInt(process.env.REVIEW_LOOP_IDLE_MIN_S ?? "", 10);
  return Number.isSafeInteger(n) && n >= 0 ? n * 1000 : 10_000;
})();

// A 跨会话认领 TTL：40min=2× 典型评审回合——认领者静默超时视同弃权，可被他 会话接管；
// 活性近似：认领者存活期间每次 idle 刷新 claimed_at，活跃评审回合不会中途失守。
const SCOPE_CLAIM_TTL_MS = 40 * 60 * 1000;

// 纯规划者判定（V2 形态）：V1 扫 user 消息的 info.agent——V2 user 消息不带 agent，
// agent 落在 assistant 消息顶层与会话记录 s.agent 上；两处任一命中即 defer。
const PLANISH = /prometheus|plan builder|plan consultant|plan critic|plan mode|^plan$/i;

const reviewPrompt = (scopes) =>
  `Work finished with unreviewed changes. Review scope: ${scopes.join("; ")}. Run the /review-loop command now (knowledge module: ${artifactModule}). Hard rule: residue and origin(report-only) items are REPORT-ONLY — never write, backfill, or fix them without explicit user confirmation first (precedent: 2026-10-08 mis-skip incident, residue illegally landed and caused deletions).`;

// T3④：归属判定缓存（插件进程生命周期内持久）——sid -> parentID|null（parentID 不可变）。
// 无键=未查或上次查询失败（失败态不缓存，下次 idle 重试）；null=顶层会话（确定非子，可缓存）。
const childOf = new Map();

// T5③：容器内存上限——超 max 淘汰最早插入项（FIFO；Map/Set 均保持插入序）。
// 会话资格内存（productEdits/editPaths/delegators）不做 delete-on-inject：W2 水平触发的再注入
//（新编辑产生新欠债，2026-10-17 时间轴）依赖旧资格内存存活，注入即删必漏触发。
const capFifo = (c, max = 4096) => {
  if (c.size > max) c.delete(c.keys().next().value);
};

export default {
  id: "review-loop-trigger",
  setup(ctx) {
    if (process.env.REVIEW_LOOP_OFF === "1") return;

    const productEdits = new Set();
    const editPaths = new Map(); // sessionID -> Map<absolute path of product edit, last-edit ts ms>（仓根解析源＋欠债门时间轴）
    const injected = new Set();
    const delegators = new Set(); // 委派工作流：父会话派了 task 即有评审资格（ocr#9）
    const claimedRootsBySid = new Map(); // sessionID -> string[]（mv 后待清理的 claimed flag 位点，O(1) 复用不重解析 roots）
    const scopeClaimsBySid = new Map(); // sessionID -> Set<root>（A：本实例写入的活认领，idle 顶刷新活性）
    let probed = false; // first completion logs measured field names
    const dbgDirs = new Map(); // sessionID -> dir（每会话独立槽位：早期门调试行不再落错会话日志）
    const idleTimers = new Map(); // sessionID -> pending Timeout（空闲门：更近完成取消重挂）

    const dbg = (dir, line) => {
      if (process.env.REVIEW_LOOP_DEBUG !== "1") return;
      const d = dir;
      if (!d) return; // no dir known yet (pre-session.get gates / arg-probe paths)
      try {
        mkdirSync(`${d}/.review-loop`, { recursive: true });
        appendFileSync(`${d}/.review-loop/plugin-debug.log`, `${line}\n`);
      } catch {
        // debug logging is best-effort, never blocks gating
      }
    };
    // 错误日志：无条件落盘（错误本身例外于 debug 门），绝不写 TTY
    const logErr = (dir, line) => {
      const d = dir;
      if (!d) return;
      try {
        mkdirSync(`${d}/.review-loop`, { recursive: true });
        appendFileSync(`${d}/.review-loop/plugin-debug.log`, `[${new Date().toISOString()}] error ${line}\n`);
      } catch {
        // error logging is best-effort
      }
    };

    // piped git：execFile 默认捕获 stdout/stderr，绝不触 TTY。
    // 失败（非零退出/无法启动/挂起 10s 被 SIGKILL 超时）resolve null，由调用方决定跳过语义。
    // B3④ timeout 可观测：SIGKILL 超时先落一行 dbg 再返回 null（-C 目标仓即 dbg 目录；
    // 无 -C 无槽位时 dbg 自然 no-op），跳过语义零变化。
    const gitQuiet = (args) =>
      new Promise((resolve) => {
        // err 单次重试（400ms，仅限 index.lock 类瞬时锁竞争）：opencode 自身 git（snapshot/
        // watcher）与本插件的 git 偶发锁竞态→瞬时 null 曾把「有欠债」误判成 no debt
        // （ag-8128ba S13 实证）；永久错误（非仓 128 等）不重试不 delay。超时（SIGKILL）
        // 不重试（10s×2 已足够异常）。重试落 dbg 可诊断。
        const once = (retry) => {
          execFile("git", args, { maxBuffer: 32 * 1024 * 1024, timeout: 10_000, killSignal: "SIGKILL" }, (err, stdout) => {
            const killed = !!err && (err.signal === "SIGKILL" || err.killed);
            if (killed) dbg(args[0] === "-C" ? args[1] : null, `git timeout ${args.slice(0, 3).join(" ")}`);
            const transient = !!err && /index\.lock|unable to create/i.test(String(err.message ?? ""));
            if (err && retry && transient && !killed) {
              dbg(args[0] === "-C" ? args[1] : null, `git transient lock race — retry once ${args.slice(0, 3).join(" ")}`);
              setTimeout(() => once(false), 400);
              return;
            }
            resolve(err ? null : String(stdout ?? ""));
          });
        };
        once(true);
      });

    // 同形字符折叠（ag-8128ba S4 实证）：模型偶发把路径中的拉丁字母发成西里尔/希腊同形字符
    // （.omо——о=U+043E）→ isOmoPath 被绕过 → omo 噪声计入产品欠债 → 误注入。仅折叠用于噪声
    // 判定（isOmoPath 全部调用点：工具观测过滤＋porcelain 脏文件归属），不改动观测/落盘路径。
    // 未映射西里尔/希腊字母剔除（它们不构成拉丁匹配目标，剔除防跨段拼接误配）。
    const HOMOGLYPH_LATIN = {
      "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i",
      "ѕ": "s", "ј": "j", "ԁ": "d", "ɡ": "g", "һ": "h", "м": "m", "т": "t", "ѡ": "w",
      "ӏ": "l",
      "ο": "o", "α": "a", "ε": "e", "ρ": "p", "ι": "i", "κ": "k", "χ": "x", "ν": "v",
    };
    const foldHomoglyphs = (s) =>
      s
        .normalize("NFKC") // 全宽拉丁→ASCII
        .toLowerCase()
        .replace(/[\u0250-\u02ff\u0370-\u03ff\u0400-\u052f]/g, (c) => HOMOGLYPH_LATIN[c] ?? "");
    const isOmoPath = (p) => {
      const n = foldHomoglyphs(String(p).replace(/\\/g, "/"));
      return (
        n === ".omo" || n.startsWith(".omo/") || n.includes("/.omo/") ||
        n === ".review-loop" || n.startsWith(".review-loop/") || n.includes("/.review-loop/") ||
        // gt-12c3（2026-10-21 NPU 会话）：经验写入非产品编辑，误计致 dotfiles 根入 scope 空转自催
        n === ".agent-experiences" || n.startsWith(".agent-experiences/") || n.includes("/.agent-experiences/")
      );
    };

    const argPath = (v, depth) => {
      if (depth > 4 || v === null || v === undefined) return "";
      if (typeof v === "string") {
        if (/^[a-z][a-z0-9+.-]*:\/\//i.test(v)) return ""; // URLs are not paths
        if (/\s/.test(v) && !/\.[A-Za-z0-9]{1,8}$/.test(v)) return ""; // prose lacks a file extension; "src/my file.ts" survives
        return v.includes("/") ? v : "";
      }
      if (Array.isArray(v)) {
        for (const x of v) {
          const p = argPath(x, depth + 1);
          if (p) return p;
        }
        return "";
      }
      if (typeof v === "object") {
        for (const k of Object.keys(v)) {
          if (/content|text|prompt|instruction/i.test(k)) continue; // write 工具键序 {content,filePath}，长文本先于路径键，含 "/" 的正文不得当路径
          const p = argPath(v[k], depth + 1);
          if (p) return p;
        }
      }
      return "";
    };

    // V2 ctx.session.prompt：admission 即返回（inbox 收纳≠回合完成），等价 V1 promptAsync 语义。
    // M2（终闸评审）：V1 promptAsync(body.agent="build") 强制评审回合以 build 执行体运行——
    // V2 prompt 无 per-submission agent 字段（openapi 实证），等价物是先 switchAgent 再 prompt。
    // 已知漂移：切换为持久（会话此后保持 build），不随回合结束还原；对非 build 会话这是可见变化。
    const inject = async (id, scopes) => {
      try {
        await ctx.session.switchAgent({ sessionID: id, agent: "build" });
        await ctx.session.prompt({
          sessionID: id,
          text: reviewPrompt(scopes && scopes.length ? scopes : ["workspace (scope auto-detect)"]),
        });
        return true;
      } catch (e) {
        logErr(dbgDirs.get(id), `inject failed: ${e?.message}`);
        return false;
      }
    };

    // ---- 仓根解析与工作树信号 ----
    // git 探测走 gitQuiet（piped execFile）：非仓路径退出 128 → resolve null → 视同非仓。
    const repoRootCache = new Map(); // T5⑦ dirname -> root 缓存（同仓重复编辑路径免重复 rev-parse；仅缓存成功，非仓不缓存防 git init 前误判）
    const repoRootOf = async (p) => {
      if (typeof p !== "string" || !p.startsWith("/")) return ""; // 相对路径无法定仓，交由会话目录回退
      const d = p.slice(0, p.lastIndexOf("/")) || "/";
      if (repoRootCache.has(d)) return repoRootCache.get(d);
      const out = await gitQuiet(["-C", d, "rev-parse", "--show-toplevel"]);
      if (out === null) return ""; // 非仓路径：rev-parse 退出 128
      const root = out.trim();
      if (!(root && root.startsWith("/"))) return "";
      repoRootCache.set(d, root);
      capFifo(repoRootCache, 256); // T5⑦ 上限 256
      return root;
    };
    // T5④：porcelain 行解析私有助手——rename ` -> ` 取目标、quotepath 去引号，两调用方共用一份实现。
    const porcelainPath = (l) => {
      let path = l.slice(3);
      const arrow = path.lastIndexOf(" -> "); // renames: judge by destination
      if (arrow !== -1) path = path.slice(arrow + 4);
      if (path.startsWith('"') && path.endsWith('"')) path = path.slice(1, -1); // core.quotepath
      return path;
    };
    const porcelainDirty = (st) =>
      st
        .split("\n")
        .some((l) => l.trim() !== "" && !isOmoPath(porcelainPath(l))); // .omo 噪声不得维持「脏」判定（e2e D2）
    // T3①：porcelainDirty 的姊妹函数——共用 porcelainPath 解析 + .omo 排除，
    // 返回非 .omo 脏文件的仓相对路径列表（porcelainDirty 保持布尔语义不动）。
    const porcelainFiles = (st) =>
      st
        .split("\n")
        .filter((l) => l.trim() !== "")
        .map(porcelainPath)
        .filter((path) => !isOmoPath(path));
    const commitFlagged = (root) => existsSync(`${root}/.review-loop/.commit-flag`);
    // flag 两行格式（2026-09-28 T2）：首行 40hex 起点，次行 `origin: <sid|external>`。
    // 旧单行格式（仅 SHA）继续可解析：origin=null
    const flagStart = (root) => {
      try {
        const raw = readFileSync(`${root}/.review-loop/.commit-flag`, "utf-8");
        const lines = raw.split("\n").map((l) => l.trim()).filter(Boolean);
        // {40,64} 兼容 SHA-256（裁决 P3-14）
        if (!lines[0] || !/^[0-9a-f]{40,64}$/.test(lines[0])) return { start: "", origin: null };
        const om = /^origin: (\S+)$/.exec(lines[1] || "");
        return { start: lines[0], origin: om ? om[1] : null };
      } catch {
        return { start: "", origin: null };
      }
    };

    // W2 水平触发：.last-reviewed 锚读取——评审环每轮完成写当前 HEAD（40hex），是下一轮范围
    // 起点与欠债状态比较基线。缺失/不可读/非 40hex → ""（欠债退回 dirty/flag 信号，scope 退回
    // flag 范围/脏树表述，即规格「无锚点文件则全史/脏树」）。
    const lastReviewedOf = (root) => {
      try {
        const v = readFileSync(`${root}/.review-loop/.last-reviewed`, "utf-8").trim();
        // {40,64} 兼容 SHA-256（裁决 P3-14）
        return /^[0-9a-f]{40,64}$/.test(v) ? v : "";
      } catch {
        return "";
      }
    };

    // 欠债门时间轴锚（2026-10-17）：「最后一次 review-loop」＝候选目录集合（会话目录 dir ＋各
    // 欠债根 root——命令按<项目根>落 marker/证据，dir≠仓根拓扑下会话目录侧恒扑空，根侧兜住；
    // 终闸评审 medium 修正）下本会话证据文件 `*-<sid8>.md`（命令第 5 步逐轮写入）与
    // `.injected-<sid>` 标记（插件注入落 dir 侧/手动环第 1 步 touch 落项目根侧）的 mtime 最大值。
    // 缺失 → 0（从未评审：任何编辑即欠债）。
    const lastReviewTsOf = (sid, dirs) => {
      let ts = 0;
      const suffix = `-${String(sid).slice(0, 8)}.md`;
      for (const d of dirs) {
        const rld = `${d}/.review-loop`;
        try {
          ts = Math.max(ts, statSync(`${rld}/.injected-${sid}`).mtimeMs);
        } catch {
          /* 无标记 → 未评审或未注入，evidence 兜底 */
        }
        try {
          for (const f of readdirSync(rld)) {
            if (!f.endsWith(suffix)) continue;
            try {
              ts = Math.max(ts, statSync(join(rld, f)).mtimeMs);
            } catch {
              /* 竞态删除：跳过该文件 */
            }
          }
        } catch {
          /* 无 .review-loop 目录 → 无证据 */
        }
      }
      return ts;
    };

    // A 跨会话认领（2026-10-08 15:05 事故）：仓级 scope-claim——<root>/.review-loop/.scope-claim.json
    // {root, sessionID, claimed_at(ms)}，tmp+rename 原子写。读失败/坏 JSON → null（fail-open，
    // 退化为无认领旧语义）；写/释失败均不阻断注入门（安全方向=行为退回修复前）。
    const scopeClaimPath = (root) => `${root}/.review-loop/.scope-claim.json`;
    const readScopeClaim = (root) => {
      try {
        const c = JSON.parse(readFileSync(scopeClaimPath(root), "utf-8"));
        return c && typeof c === "object" ? c : null;
      } catch {
        return null;
      }
    };
    const writeScopeClaim = (root, sid) => {
      try {
        mkdirSync(`${root}/.review-loop`, { recursive: true });
        const tmp = `${root}/.review-loop/.scope-claim.tmp-${sid}`; // sid 后缀防跨进程 tmp 互踩
        writeFileSync(tmp, JSON.stringify({ root, sessionID: sid, claimed_at: Date.now() }));
        renameSync(tmp, scopeClaimPath(root));
        return true;
      } catch {
        return false;
      }
    };
    // 释放=内存集撤出+文件删除（仅当文件仍属本会话；被接管/丢失时只清内存）。失败由 TTL 兜底。
    const releaseScopeClaim = (root, sid) => {
      const held = scopeClaimsBySid.get(sid);
      if (held) {
        held.delete(root);
        if (!held.size) scopeClaimsBySid.delete(sid);
      }
      const c = readScopeClaim(root);
      if (c && c.sessionID === sid) {
        try {
          rmSync(scopeClaimPath(root), { force: true });
        } catch {
          /* best-effort：释放失败由 TTL 过期兜底接管 */
        }
      }
    };

    // T3④ Oracle N1：delegator 路径的精确归属——仅 parentID===id 的直接子会话计入等价集；
    // 查询失败/孙辈/会话缺失一律排除 → 对应脏文件落 residue(review-only)（安全方向）。
    // 天花板：孙辈嵌套（子会话再派 task）不自动归因，须评审时人工确认。
    // 缓存策略：childOf 模块级，parentID 不可变故成功后永久缓存；查询失败不缓存失败态
    // （返回 undefined），下次 idle 自动重试。
    const childOfOrFetch = async (sid) => {
      if (childOf.has(sid)) return childOf.get(sid);
      try {
        const s = await ctx.session.get({ sessionID: sid }); // V2：直接返回 SessionInfo（无 .data 包装）
        if (!s) return undefined; // 会话记录缺失视同失败：不缓存，下轮重试
        const pid = s.parentID ?? null;
        childOf.set(sid, pid);
        capFifo(childOf); // T5③ FIFO 上限
        return pid;
      } catch {
        return undefined;
      }
    };
    // T3③：commit-flag origin 标注——他会话/external/缺失（unknown）时只上报（report-only，
    // 未经用户确认归属不得修改）；origin===本会话 id（本会话自己的提交触发）不加段。
    const originPart = (origin, sid) =>
      origin === sid ? "" : ` | origin: ${origin ?? "unknown"} (report-only)`;
    // T3②：editPaths 路径 → root 仓相对路径归一。工具 args 实测均为绝对路径；仅当以
    // `${root}/` 为前缀时截取仓相对参与匹配；相对路径/跨仓路径不匹配 → 落 residue（安全方向）。
    const relToRoot = (p, root) => {
      const n = String(p);
      return n.startsWith(`${root}/`) ? n.slice(root.length + 1) : "";
    };
    // T3②：scope 内文件列表防膨胀——超 5 个截断为首 5 + 计数
    const fmtFiles = (files) =>
      files.length <= 5 ? files.join(",") : `${files.slice(0, 5).join(",")} +${files.length - 5} more`;

    // ---- 直入仓自动配钩 ensureHooks（A 路径）----
    // 边界语义：我开会话的仓 = 应可审的仓（直入拓扑自动配钩）；跨库路径由 cross-project-worker 协议覆盖（T1）；
    // 仅当 hooksPath 为空时动作（幂等，不覆盖自有钩子，如 husky）。绝对路径免拷贝。
    // 历史教训：子进程一律 gitQuiet（piped execFile）——永不抛 ShellError；
    // fire-and-forget，绝不阻塞或炸插件加载；catch 崩溃落 ~/.review-loop 回退。
    const ensureHooks = async () => {
      try {
        let hooksDir = join(dirname(realpathSync(fileURLToPath(import.meta.url))), "hooks"); // 提取改单级：本仓与插件同级；旧布局 miss→下行回退兜底
        if (!existsSync(hooksDir)) hooksDir = join(homedir(), ".dotfiles/.agent/review-loop/hooks"); // 派生根缺 hooks → 回退 HOME 主仓
        const root = await repoRootOf(`${process.cwd()}/x`); // 补 /x：repoRootOf 按父段探仓
        if (!root) return; // 非仓 cwd 不动作（init 时无会话目录可落日志）
        const cur = (await gitQuiet(["-C", root, "config", "core.hooksPath"])) ?? "";
        if (cur.trim()) return dbg(root, `ensureHooks already-set hooksPath=${cur.trim()} skip`);
        const r = await gitQuiet(["-C", root, "config", "core.hooksPath", hooksDir]);
        if (r === null) return logErr(root, "ensureHooks config write failed");
        dbg(root, `ensureHooks configured core.hooksPath=${hooksDir}`);
      } catch (e) {
        // init 时 dbgDirs 尚无槽位，logErr(undefined) 命中空目录守卫是保证 no-op——崩溃必须落会话无关回退目录；
        // homedir() 跨平台且无 $HOME 环境时也有兜底；logErr 自行补 /.review-loop/
        logErr(homedir(), `ensureHooks crashed: ${e && e.message ? e.message : e}`); // 任何异常不得传出
      }
    };

    // 空闲门（2026-10-17 用户裁定）：回合完成只挂计时——空闲持续 ≥IDLE_MIN_MS 才跑闸门
    // 管线（evaluateIdle）；更近的完成取消重挂（回合间隙永不触发）。
    const evaluateIdle = async (id) => {
      // claimed-flag 清理（T2 C7）：上轮 mv 留下的 .commit-flag.claimed-<sid> 就地删除。
      // 位于 injected.has 门之前；异常必须自吞——逸出到外层 catch 会 injected.delete 误解封已注入会话
      for (const cr of claimedRootsBySid.get(id) || []) {
        try {
          rmSync(`${cr}/.review-loop/.commit-flag.claimed-${id}`, { force: true });
        } catch {
          /* 清理失败静默：残留仅占盘，不影响 gating 语义 */
        }
      }
      claimedRootsBySid.delete(id);
      // A 活性刷新：本会话持有的活认领每次 idle 顶刷新 claimed_at——评审回合内持续 idle 维持
      // 新鲜（回合可长于 TTL），他 会话 claim-skip 防线不失守；文件侧已非本会话（被接管/删除）
      // → 仅撤出内存集停止续期。位于 injected.has 门之前：marker 冷却期内的 idle 同样续期。
      for (const root of [...(scopeClaimsBySid.get(id) || [])]) {
        const c = readScopeClaim(root);
        if (c && c.sessionID === id) writeScopeClaim(root, id);
        else releaseScopeClaim(root, id);
      }
      try {
        if (injected.has(id)) {
          dbg(dbgDirs.get(id), `gate=injected.has BLOCK id=${id}`);
          return;
        }
        injected.add(id); // claim BEFORE first await — concurrent idles must not double-inject (TOCTOU)
        const s = await ctx.session.get({ sessionID: id }); // V2：直接返回 SessionInfo（无 .data 包装）
        if (s?.parentID) {
          injected.delete(id); // release placeholder
          dbg(s?.location?.directory || s?.directory, `gate=parentID BLOCK (subagent) id=${id}`);
          return;
        }
        // V2 会话形状漂移（2026-10-19 实证 v2.0.32）：location.directory 取空但平铺 directory
        // 在（s7b 探针输出实测）——`||` 回退（location.directory 空串非 nullish，?? 不回退——00:3x 修正）；旧版无平铺时前者仍生效。
        const dir = s?.location?.directory || s?.directory || "";
        if (!dir) {
          injected.delete(id); // release placeholder like every other gate
          return; // session record unavailable — nothing to anchor gates on
        }
        dbgDirs.set(id, dir);
        capFifo(dbgDirs, 1024); // B3① 每会话容器中唯一无界者：FIFO 上限 1024

        // W2 水平触发：marker 语义「存在即永拒」→「mtime 冷却」——窗内跳过，过期视为已冷却，
        // 放行到后续欠债门重新裁决。fail-open：不可读（ENOENT 等）视同无标记 → -1 → 不冷却。
        let markerAgeMs = -1;
        try {
          markerAgeMs = Date.now() - statSync(`${dir}/.review-loop/.injected-${id}`).mtimeMs;
          if (markerAgeMs < 0) markerAgeMs = 0; // 时钟回拨/未来 mtime 按刚注入处理（裁决 P3-10）
        } catch {
          /* 无标记或不可读 → 不冷却 */
        }
        if (markerAgeMs >= 0 && markerAgeMs < COOLDOWN_MS) {
          injected.delete(id); // release placeholder
          dbg(dir, `gate=marker BLOCK (cooldown ${Math.round(markerAgeMs / 1000)}s/${COOLDOWN_MS / 1000}s) id=${id}`);
          return;
        }
        // 委派工作流——父会话派了子代理即有评审资格（ocr#9）
        if (!productEdits.has(id) && !delegators.has(id)) {
          injected.delete(id); // release placeholder
          dbg(dir, `gate=edits BLOCK id=${id}`);
          return;
        }
        // 最近 5 条消息（V2：context() 返回扁平消息数组，取尾部 5 条与 V1 limit:5 对齐）。
        // n2（终闸评审）：拉取点保持在 edits 门之后（V1 顺序），未过门不花这次读取。
        let msgs = [];
        try {
          const all = await ctx.session.context({ sessionID: id });
          msgs = Array.isArray(all) ? all.slice(-5) : [];
        } catch (e) {
          // m2（终闸评审）：V1 在此 fail 中止整轮，V2 退化 msgs=[] 仅影响 planish 探测——
          // 落一行 debug 便于事后归因（注入方向较 V1 略宽，靠 s.agent 兜底）。
          dbg(dir, `context read failed; planish degrades to session.agent only: ${e?.message}`);
        }

        if (process.env.REVIEW_LOOP_DEBUG === "1" && !probed) {
          probed = true;
          dbg(dir, `session fields (measured): ${Object.keys(s || {}).join(",")}`);
          dbg(
            dir,
            `message fields (measured): ${msgs[0] ? Object.keys(msgs[0]).join(",") : "(empty)"}`,
          );
        }
        // 仅纯规划者 defer——实现会话（Atlas/Sisyphus/build）正常触发。
        // V2 判定：会话 agent ＋ 最近 assistant 消息的顶层 agent（V2 user 消息不带 agent）。
        // m1 已知窗口：planner 证据仅存于 user 侧且 s.agent 为空/assistant 无 agent 的会话不再被识别
        //（review-loop 侧=误 nudge 骚扰面；req-gate 侧=fail-close，模型可自写记录解门）。
        const planish =
          PLANISH.test(String(s?.agent || "")) ||
          msgs.some((m) => m?.type === "assistant" && PLANISH.test(String(m?.agent || "")));
        if (planish) {
          injected.delete(id); // release placeholder
          dbg(dir, `gate=planish BLOCK id=${id}`);
          return;
        }
        try {
          const b = JSON.parse(readFileSync(`${dir}/.omo/boulder.json`, "utf-8") || "{}");
          const active = Object.values(b.works || {}).some((w) => w && w.status === "active");
          if (active) {
            injected.delete(id); // defer 临时：解占位，boulder work 完成后下一轮 idle 重新裁决
            dbg(dir, `gate=boulder BLOCK (start-work owns review via F-wave) id=${id}`);
            return;
          }
        } catch {
          /* 无 boulder 或解析失败 → 不 defer（fail-open） */
        }
        // 欠债门（2026-10-17 时间轴化）：欠债＝等价集在 lastReviewTs 之后有产品编辑；
        // commit 状态（HEAD≠.last-reviewed、.commit-flag）降级为 scope 范围携带者。
        // 仓根从编辑路径解析，会话目录仓作回退。考古结论（draft F1-F4）：roots 仅取本会话
        // editPaths 是历史沉淀而非设计决策——跨项目修改按规矩全由 task 子会话完成，旧口径
        // 漏掉全部此类编辑。现扩为等价集 editPaths；孙辈仍排除（childOfOrFetch===id 不变）。
        // roots: Map<root, provenance>——'equiv'=等价集编辑来源｜'session'=会话目录仓；
        // 同根双来源冲突 'session' 优先（cwd 在仓内的会话自身 editPaths 同指该仓，
        // S7a/S7b report-only 断言依赖此）。
        // T3④：等价集——非 delegator（productEdits 门）仅本会话自身；delegator 门（本会话无
        // editPaths，靠派 task 取得触发资格）扩为 {id ∪ 直接子会话}，子会话编辑精确归因。
        const equivSids = [id];
        if (delegators.has(id)) {
          for (const sid of editPaths.keys()) {
            if (sid !== id && (await childOfOrFetch(sid)) === id) equivSids.push(sid);
          }
        }
        const roots = new Map(); // root -> provenance 'equiv' | 'session'
        const rootMaxEditTs = new Map(); // root -> 等价集最新编辑时间戳（欠债门时间轴；'session' cwd 回退根不经此门）
        for (const sid of equivSids) {
          for (const [p, ts] of editPaths.get(sid) || []) {
            const r = await repoRootOf(p);
            if (!r) continue;
            roots.set(r, "equiv");
            if (ts > (rootMaxEditTs.get(r) ?? 0)) rootMaxEditTs.set(r, ts);
          }
        }
        // cwd 回退资格门（2026-10-08 误投实证）：回退仅在等价集存在 ≥1 个产品编辑时成立——
        // delegator 会话自身+全部直接子会话零产品编辑（纯规划咨询）时，cwd 在仓内不构成注入资格，
        // 外部欠债不得归入（V2 planish 按会话/assistant agent 判定，行为门保留）。
        const hasEquivEdits = equivSids.some((sid) => (editPaths.get(sid) || []).size > 0);
        const sessionRoot = await repoRootOf(`${dir}/x`); // dir 本身作路径探仓
        if (sessionRoot && hasEquivEdits) {
          roots.set(sessionRoot, "session"); // Map.set 覆盖同根 'equiv'：'session' 胜
        } else if (sessionRoot) {
          dbg(dir, `gate=cwd-fallback BLOCK (planish=${planish} hasEquivEdits=${hasEquivEdits}) id=${id}`);
        }
        let workSignal = false;
        const flaggedRoots = [];
        const scopes = [];
        const debtRoots = []; // A：进入注入判定的工作根（待注入 root=认领对象）
        const lastReviewTs = lastReviewTsOf(id, [dir, ...roots.keys()]); // 空闲门评估期读取：会话目录＋各根双扫（命令按项目根落证据，终闸 medium 修正）
        for (const root of roots.keys()) {
          const st = await gitQuiet(["-C", root, "status", "--porcelain"]);
          if (st === null) continue; // TOCTOU：rev-parse 验证后仓被删/失联——该根按无欠债跳过，不炸 handler
          // 欠债判定（2026-10-17 用户裁定）：本会话[+直接子会话]在最后一次 review-loop 之后
          // 是否编辑过本仓——commit 状态不再构成欠债（headDebt/flag 降级为范围携带者）。
          const editDebt = (rootMaxEditTs.get(root) ?? 0) > lastReviewTs;
          if (!editDebt) continue; // 本根无欠债（仓内有新提交但非本会话新编辑＝外来信号，不催）
          workSignal = true;
          debtRoots.push(root);
          const dirty = porcelainDirty(st);
          const anchor = lastReviewedOf(root);
          const headOut = await gitQuiet(["-C", root, "rev-parse", "HEAD"]);
          const head = headOut === null ? "" : headOut.trim();
          const headDebt = anchor !== "" && head !== "" && anchor !== head;
          const flagged = commitFlagged(root);
          const f = flagged ? flagStart(root) : { start: "", origin: null };
          if (flagged) flaggedRoots.push({ root, origin: f.origin }); // 消费位点登记（scope 携带者，兼容不变）
          const parts = [];
          if (headDebt) parts.push(`${anchor}..HEAD`); // 锚点差分：评审范围主载体（非欠债门）
          else if (f.start) {
            // 2026-10-18 孤儿旗标守卫：amend/rebase 把旗上起点改写成孤儿号（实证：本仓绿态收尾
            // amend 后注入范围起点=被弃 d1031a5，靠 reflog 存活碰巧解析）——merge-base 可达性双检
            // （可解析∧HEAD 祖先）不过即弃用范围、落下方兜底；旗本体消费与 origin 归属不变。
            const anc = await gitQuiet(["-C", root, "merge-base", "--is-ancestor", f.start, "HEAD"]);
            if (anc !== null) parts.push(`${f.start}..HEAD`); // flag 范围（消费对象）
            else dbg(dir, `flag-start orphan (not HEAD ancestor, amend/rebase?): root=${root} start=${f.start.slice(0, 8)} — range dropped`);
          }
          if (dirty) {
            // T3②：脏文件二分。等价集（本会话[+直接子会话]的 editPaths 归一到本 root 仓相对）
            // ∩ 本 root 脏文件 = session-edited / delegated(child-observed)；其余 = residue。
            // residue(review-only) 语义：未经会话 edit/write 工具观察到的改动——可能是 bash
            // 途径的本会话改动或他会话遗留：上报，未经用户确认归属不得修改（confirm-before-fix）。
            parts.push("dirty tree");
            const dirtyFiles = porcelainFiles(st);
            const dirtySet = new Set(dirtyFiles);
            const ownRel = new Set();
            for (const sid of equivSids) {
              for (const p of (editPaths.get(sid) || []).keys()) { // Map 迭代产出 [k,v] 条目——必 .keys()，直迭代会把条目数组当路径（S8d/e 回归根因）
                const rel = relToRoot(p, root);
                if (rel && dirtySet.has(rel)) ownRel.add(rel);
              }
            }
            const sessionEdited = dirtyFiles.filter((x) => ownRel.has(x));
            const residue = dirtyFiles.filter((x) => !ownRel.has(x));
            if (sessionEdited.length) {
              parts.push(
                delegators.has(id)
                  ? `delegated(child-observed, fix-authoritative): ${fmtFiles(sessionEdited)}`
                  : `session-edited: ${fmtFiles(sessionEdited)}`,
              );
            }
            if (residue.length) parts.push(`residue(review-only): ${fmtFiles(residue)}`);
          }
          if (!parts.length) parts.push("session-edited since last review"); // 编辑已全部提交但无锚无旗标（钩子缺失且从未评审）
          let scope = `${root} (${parts.join(" | ")})`;
          // D2/F10/F15：'equiv'（有会话编辑观察）→ 观察级归属胜出、权威可修，不加 origin 段；
          // 'session'（cwd 回退根，无会话编辑证据）→ 维持 origin 字符串规则不变。
          if (flagged && roots.get(root) !== "equiv") scope += originPart(f.origin, id);
          scopes.push(scope);
        }
        if (!workSignal) {
          injected.delete(id); // release placeholder
          dbg(dir, `gate=worktree BLOCK (no debt: no equiv edits after last review) id=${id} roots=${[...roots.keys()].join(",") || "-"}`);
          return;
        }
        // A 注入前认领检查：他人新鲜认领（claimed_at 距今 < TTL 且 sessionID≠本会话）→ 跳过注入
        // （claim-skip 落 plugin-debug，含双方 sid 与 root）；不写 marker、不动 flag——认领释放/
        // TTL 过期后欠债门自然重试（接管兜底）。本会话旧认领不拦（下方写入时刷新）。
        const claimBlockers = [];
        for (const root of debtRoots) {
          const c = readScopeClaim(root);
          if (
            c && c.sessionID && c.sessionID !== id &&
            typeof c.claimed_at === "number" && Date.now() - c.claimed_at < SCOPE_CLAIM_TTL_MS
          ) {
            claimBlockers.push({ sid: c.sessionID, root, ageMs: Math.max(0, Date.now() - c.claimed_at) });
          }
        }
        if (claimBlockers.length) {
          injected.delete(id); // 同其他门：释放占位，待认领失效后重试
          for (const b of claimBlockers) {
            dbg(dir, `gate=scope-claim BLOCK (claim-skip) id=${id} claimed-by=${b.sid} root=${b.root} age=${Math.round(b.ageMs / 1000)}s/${SCOPE_CLAIM_TTL_MS / 60000}min`);
          }
          return;
        }
        // A 认领写入：每个待注入 root 写/刷本会话认领（先于 inject 调用，封闭与并行实例的判定窗）
        for (const root of debtRoots) {
          if (writeScopeClaim(root, id)) {
            if (!scopeClaimsBySid.has(id)) scopeClaimsBySid.set(id, new Set());
            scopeClaimsBySid.get(id).add(root);
          }
        }
        // C4 纯审计（gt-f23e94 R3 后置）：审计写移到欠债判定之后——仅判定有债、注入即将发生时
        // 才落盘；无债评估零落盘（此前写在欠债判定之前，冷却一过每评估必写，无罪也留痕，且实证
        // 与并发目录删除相撞）。① 纯审计工件：任何场景均不作为归属数据源——归属只认内存
        // editPaths；② 覆写（>）不追加防无限增长；③ 失败仅影响审计，完全静默，不影响任何门控。
        try {
          mkdirSync(`${dir}/.review-loop`, { recursive: true });
          writeFileSync(
            `${dir}/.review-loop/session-edits.json`,
            JSON.stringify({ sessionID: id, edited: [...(editPaths.get(id) || []).keys()], ts: new Date().toISOString() }),
          );
        } catch {
          /* audit-only write: failure is silent, gating unaffected */
        }
        dbg(dir, `gates PASS id=${id} — injecting (scope: ${scopes.join("; ") || "-"})`);
        const ok = await inject(id, scopes);
        if (ok) {
          let markerOk = false;
          try {
            mkdirSync(`${dir}/.review-loop`, { recursive: true });
            writeFileSync(`${dir}/.review-loop/.injected-${id}`, ""); // touch 等价
            markerOk = true;
          } catch {
            logErr(dir, "marker write failed; in-process seal only");
            // accepted edge: restart before marker write could re-inject once
          }
          // 消费 commit-flag（C7 原子化）：注入即「已提示评审」；rename 替代 rm 防并发双消费，
          // claimed 位点暂存，下一轮 idle 顶部清理。rename 失败（ENOENT 被抢）静默
          for (const { root } of flaggedRoots) {
            try {
              renameSync(`${root}/.review-loop/.commit-flag`, `${root}/.review-loop/.commit-flag.claimed-${id}`);
              claimedRootsBySid.set(id, [...(claimedRootsBySid.get(id) || []), root]);
              releaseScopeClaim(root, id); // A 释放：消费即认领使命完成（TTL 兜底他 会话接管）
            } catch {
              /* best-effort：rename 失败最多多触发一次，marker 仍封口本会话 */
            }
          }
          // W2 水平触发：marker 落盘成功才释放进程内占位——同会话后续 idle 改由 mtime 冷却封口；
          // marker 写失败时占位保留（进程内封口兜底）。以写入结果布尔判定而非 existsSync——
          // 再注入路径上旧 marker 必在场，existsSync 无法区分新写与陈旧（ocr O1）。
          if (markerOk) injected.delete(id);
          dbg(dir, `injected OK id=${id}`);
        } else {
          injected.delete(id); // release placeholder — next idle retries naturally; success is sealed by the persistent marker
          for (const root of debtRoots) releaseScopeClaim(root, id); // 注入失败不得持/续 40min scope 认领——释放，下轮重判
          dbg(dir, `inject FAILED, placeholder released id=${id}`);
        }
      } catch (e) {
        injected.delete(id); // error path releases the placeholder (no-op if not held) — a session must never be permanently sealed
        logErr(dbgDirs.get(id), `handler error: ${e?.message}`);
      }
    };

    // V2 工具观测：execute.after 的 event.input 直接携带工具 args（probe 实证
    // {tool,sessionID,agent,messageID,id,input,status,result}），V1 的 args-key 探测层保留。
    ctx.tool.hook("execute.after", (event) => {
      const tool = String(event?.tool || "").toLowerCase();
      if (!event?.sessionID) return; // n1（终闸评审）：task 分支同样不得收编 undefined 键
      if (tool === "task" || tool === "subagent") { // v2.0.32 drift: delegation tool renamed task→subagent (e2e S8 DB 实证)
        delegators.add(event.sessionID); // 委派观察：父会话派生子代理改代码（e2e ocr#9）
        capFifo(delegators); // T5③ FIFO 上限
      }
      if (tool !== "edit" && tool !== "write") return;
      if (!event?.sessionID) return;
      const a = event?.input && typeof event.input === "object" ? event.input : {};
      const p =
        ["filePath", "file_path", "path"].map((k) => a[k]).find((v) => typeof v === "string" && v) ||
        argPath(a, 0);
      if (!p) return;
      if (isOmoPath(p)) return;
      const absp = p.startsWith("/") ? p : resolve(p); // v2.0.32 drift: edit/write may pass cwd-relative path (e2e S10 实证)——server cwd 解析（standalone=TUI cwd）
      // 失败的写入不计产品编辑（ag-8128ba S4 实证：模型路径噪音→write 失败→editPaths 记录
      // 幻影路径→假欠债/假资格误注入）；execute.after 落定后成功写入文件必已存在。
      if (!existsSync(absp)) return;
      // plan/evidence files are not product edits — .review-loop/（评审环自身工件）、.omo、
      // .agent-experiences 子树已在上方 isOmoPath 一律排除（R1；gt-f23e94 测试钉死）
      const sid = event.sessionID;
      productEdits.add(sid); // delegated subagent edits stay with the child session — plan neg-c verified semantics; known gap, manual /review-loop covers it
      capFifo(productEdits); // T5③ FIFO 上限
      if (!editPaths.has(sid)) editPaths.set(sid, new Map());
      capFifo(editPaths); // T5③ FIFO 上限
      const inner = editPaths.get(sid);
      // B3② 外层 capFifo 只淘汰整会话，单会话 Map 在其生命周期内仍可无界增长——插入位加界：
      // 已在场路径仅刷新时间戳（欠债门时间轴），不计新增。
      if (inner.size >= 512 && !inner.has(absp)) dbg(dbgDirs.get(sid), `editPaths inner-map cap 512 hit — skip ${absp}`);
      else inner.set(absp, Date.now());
    });

    // V2 事件：session.execution.succeeded ＝ V1 session.idle 的完成信号（V1 事件名已不存在，
    // probe 实证 V2 事件载荷在 .data）。空闲门计时语义不变：更近的完成取消重挂。
    // m3 已知缺口（终闸评审）：V2 openapi 仅此一种 execution 终态事件，失败/中断的执行不触发
    // 空闲门——欠债不丢（下轮成功执行重评），但 nudge 可能缺席到下一次成功。
    const controller = new AbortController();
    void (async () => {
      // M3（终闸评审）：循环意外退出不得静默失能——退避重订阅（1s→2s→…→30s 封顶），
      // 退出/崩溃均落 logErr（homedir 回退目录，此时 dbgDirs 可能无槽位）；abort 即净退出。
      let backoffMs = 1_000;
      while (!controller.signal.aborted) {
        try {
          for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
            backoffMs = 1_000; // 健康流：重置退避
            if (event?.type !== "session.execution.succeeded") continue;
            const id = event?.data?.sessionID;
            if (!id) continue;
            const prev = idleTimers.get(id);
            if (prev) clearTimeout(prev);
            const t = setTimeout(() => {
              idleTimers.delete(id);
              evaluateIdle(id).catch((e) => logErr(dbgDirs.get(id), `deferred eval crashed: ${e && e.message ? e.message : e}`));
            }, IDLE_MIN_MS);
            if (t && typeof t.unref === "function") t.unref(); // pending timer 不阻进程退出
            idleTimers.set(id, t);
          }
          if (controller.signal.aborted) return; // 净退出（cleanup abort）
          logErr(homedir(), `event loop ended unexpectedly; resubscribing in ${backoffMs}ms`);
        } catch (e) {
          if (controller.signal.aborted) return; // abort 引发的迭代器抛出＝净退出
          logErr(homedir(), `event loop crashed: ${e && e.message ? e.message : e}; resubscribing in ${backoffMs}ms`);
        }
        await new Promise((r) => setTimeout(r, backoffMs));
        backoffMs = Math.min(backoffMs * 2, 30_000);
      }
    })();

    ensureHooks(); // fire-and-forget

    return () => {
      controller.abort();
      for (const t of idleTimers.values()) {
        if (t) clearTimeout(t);
      }
      idleTimers.clear();
    };
  },
};
