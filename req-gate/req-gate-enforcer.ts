// req-gate-enforcer.ts — OpenCode V2 plugin: block the session's FIRST product
// edit/write until a requirement-gate record exists at
// <TMPDIR||/tmp>/opencode/req-gate/<sessionID>.md (out-of-repo since
// 2026-11-03, ag-97c988: in-repo state files dirtied worktrees and tripped
// done gates). Blocking works by throwing inside
// ctx.tool.hook("execute.before"); e2e first-case proof is owned by the
// orchestrator.
//
// V2 PORT (2026-10-17): rewritten for the OpenCode 2 plugin API — plain-object
//   default export { id, setup(ctx) } (no @opencode/plugin bare import, see
//   below), hook via ctx.tool.hook("execute.before"). The V1 payload carried
//   no args and forced a callID→ToolPart recovery scan over session messages;
//   V2 execute.before events carry {tool, sessionID, agent, messageID, id,
//   input} with the tool args directly on event.input (probe-verified on
//   2.0.32) — that recovery path is deleted. Session reads move to
//   ctx.session.get/context (V2: location.directory, no .data wrapper, user
//   messages carry no agent — planish now reads the session's agent plus the
//   top-level agent of recent assistant messages). All V1-only compatibility
//   shims removed.
//
// BUILTIN-ONLY IMPORTS (hard requirement, tightened 2026-09-28): bare imports
// (@opencode/*) stay forbidden — symlink realpath has no node_modules;
// node:* builtins resolve via the runtime (V2 plain-object export verified
// equivalent to Plugin.define on 2.0.32). ALL file checks go through node:fs;
// console.* writes the TTY directly: all logging appends to
// <TMPDIR||/tmp>/opencode/req-gate/gate-debug.log, never the TTY.
//
// Kill switch: REQ_GATE_OFF=1 makes setup register nothing (plugin inert).
// Uninstall = delete the symlink, or just set REQ_GATE_OFF=1.
//
// Known gap (same source as review-loop ⑨): edits made through raw shell
// (echo/sed/cat > file) bypass the edit/write tools entirely and are not
// gated here — the rule layer (AGENTS.md 需求门) is the backstop.
//
// REQ_GATE_DEBUG=1: gate decisions (PASS/BLOCK) append to
// <TMPDIR||/tmp>/opencode/req-gate/gate-debug.log; errors always append.

import { appendFileSync, existsSync, mkdirSync } from "node:fs"

// 纯规划者判定（V2 形态）：V1 扫 user 消息的 info.agent——V2 user 消息不带 agent，
// agent 落在 assistant 消息顶层与会话记录 s.agent 上；两处任一命中即免门。
const PLANISH = /prometheus|plan builder|plan consultant|plan critic|plan mode|^plan$/i

export default {
  id: "req-gate-enforcer",
  setup(ctx) {
    if (process.env.REQ_GATE_OFF === "1") return;

    const debug = process.env.REQ_GATE_DEBUG === "1";

    // 快检状态出仓（2026-11-03 ag-97c988）：记录与日志落 TMPDIR 兜底 /tmp（相对 TMPDIR
    // 视同未设——会锚回进程 CWD 把记录落回仓内），仓内零状态文件
    const tmpEnv = process.env.TMPDIR || "";
    const TMP_ROOT = (tmpEnv.startsWith("/") ? tmpEnv : "/tmp").replace(/\/+$/, "");
    const RECORD_DIR = `${TMP_ROOT}/opencode/req-gate`;

    const passedSessions = new Set();

    // gate 日志：debug 门控行 + 错误行无条件；一律落盘，绝不写 TTY
    const logF = (line) => {
      try {
        mkdirSync(RECORD_DIR, { recursive: true });
        appendFileSync(`${RECORD_DIR}/gate-debug.log`, `${line}\n`);
      } catch {
        // logging is best-effort, never blocks gating
      }
    };

    // Args come straight from event.input (V2): direct path keys first, then a
    // key-agnostic scan so it survives edit/write tool variants
    // (filePath / file_path / path / nested).
    // Gate-record dirs are exempt (chicken-and-egg: writing the record IS an
    // edit and must not be blocked by its own gate). The record dir is the
    // TMPDIR location above since 2026-11-03. ".omo" and the retired in-repo
    // ".req-gate" stay exempt so legacy records remain historical and
    // un-gated (pass lookup reads only the tmp path — a session resumed after
    // restart just re-writes its record once; legacy files stay archive-only).
    const isExemptPath = (p) => {
      // fold "."/".." first: a string like ".req-gate/../src/x.ts" resolves
      // outside the state dir on the fs side and must stay gated
      const fold = [];
      for (const s of String(p).replace(/\\/g, "/").split("/")) {
        if (s === "" || s === ".") continue;
        if (s === ".." && fold.length > 0 && fold[fold.length - 1] !== "..") fold.pop();
        else fold.push(s);
      }
      const n = fold.join("/");
      // tmp 记录目录只认绝对路径形态：折叠剥前导斜杠后绝对/相对同形，仓内相对路径
      // （TMPDIR=/tmp 时 tmp/opencode/req-gate/**）不得借前缀匹配逃闸
      const isAbs = String(p).replace(/\\/g, "/").startsWith("/");
      const rd = RECORD_DIR.replace(/^\/+/, ""); // 与 fold 输出同形（无前导斜杠）
      return (
        (isAbs && (n === rd || n.startsWith(rd + "/"))) ||
        n === ".omo" || n.startsWith(".omo/") || n.includes("/.omo/") ||
        n === ".req-gate" || n.startsWith(".req-gate/") || n.includes("/.req-gate/")
      );
    };

    const argPath = (v, depth) => {
      if (depth > 4 || v == null) return "";
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

    ctx.tool.hook("execute.before", async (event) => {
      let block = "";
      try {
        const tool = String(event?.tool || "").toLowerCase();
        if (tool !== "edit" && tool !== "write") return;
        const id = event?.sessionID;
        if (!id) return;
        if (passedSessions.has(id)) return;
        // V2: args ride on event.input directly — no callID→ToolPart recovery
        const a = event?.input && typeof event.input === "object" ? event.input : {};
        const p =
          ["filePath", "file_path", "path"].map((k) => a[k]).find((v) => typeof v === "string" && v) ||
          argPath(a, 0);
        if (!p || isExemptPath(p)) return;
        const s = await ctx.session.get({ sessionID: id }); // V2：直接返回 SessionInfo（无 .data 包装）
        if (s?.parentID) return; // delegated subagents inherit the parent's gate
        // 仅纯规划者 defer——实现会话（Atlas/Sisyphus/build）正常门控。
        // m1 已知窗口（终闸评审）：planner 证据仅存于 user 侧且 s.agent 为空/assistant 无 agent
        // 的会话不再被识别 → 误 BLOCK 为 fail-close 方向，模型可自写记录解门（安全向）。
        let planish = PLANISH.test(String(s?.agent || ""));
        if (!planish) {
          try {
            const all = await ctx.session.context({ sessionID: id });
            const msgs = Array.isArray(all) ? all.slice(-5) : [];
            planish = msgs.some(
              (m) => m?.type === "assistant" && PLANISH.test(String(m?.agent || "")),
            );
          } catch {
            /* 消息读取失败 → planish 退化为仅 session.agent，不放大放行面 */
          }
        }
        if (planish) return; // 纯规划者不交付产品代码，免需求门
        const record = `${RECORD_DIR}/${id}.md`;
        if (existsSync(record)) {
          passedSessions.add(id);
          if (debug) logF(`[${new Date().toISOString()}] PASS id=${id}`);
          return;
        }
        if (debug) logF(`[${new Date().toISOString()}] BLOCK id=${id} (no record)`);
        block =
          `[req-gate] 需求门未过：本会话首个产品编辑被拦。先做需求快检并把结论写入 ${record}（目录不存在先 mkdir -p），` +
          `三选一：①PASS(trivial):<一句话理由，仅≤1文件≤20行> ②PASS:<可执行验收标准清单> ` +
          `③ESCALATE:<分叉清单+推荐默认>并转 plan(ulw-plan)。手动入口 /req-gate。写完重试本编辑即放行。豁免开关 REQ_GATE_OFF=1`;
      } catch (e) {
        // probe/network/session-API errors must never mis-block a tool call
        logF(`[${new Date().toISOString()}] error gate evaluation failed, fail-open: ${e?.message}`);
        return;
      }
      if (block) throw new Error(block);
    });
  },
};
