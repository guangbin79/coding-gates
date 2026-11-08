# coding-gates

[![made for opencode v2](https://img.shields.io/badge/made%20for-opencode%20v2-6e7bff.svg)](https://opencode.ai)

[English](README.md) | [简体中文](README.zh-CN.md)

Two development quality gates for [opencode](https://opencode.ai) v2 as a standalone product repo — **req-gate** (the entry gate) and **review-loop** (the exit loop). Extracted from [guangbin79/dotfiles](https://github.com/guangbin79/dotfiles): symlink-deployed plugins with builtin-only imports (`node:*` only), plus their companion commands, hooks, CLI and tests.

> **Super Agent pillars**: this repo is the quality supervision gate pillar (req-gate entry gate + review-loop exit loop). The other two: [opencode-agora](https://github.com/guangbin79/opencode-agora) (dispatch Router) · [silicon-memory](https://github.com/guangbin79/silicon-memory) (memory/state separation). Together they form the super agent implementation.

## Quick Start

Prerequisites: [opencode](https://opencode.ai) v2, `bash`, `git`.

```bash
git clone https://github.com/guangbin79/coding-gates.git
cd coding-gates
./install.sh req-gate      # deploys 3 symlinks
./install.sh review-loop   # deploys 2 symlinks
```

No args or a bad arg prints usage and exits non-zero. Guard discipline: a target that already exists and does **not** resolve (via `readlink -f`) into this repo is refused with 「拒绝覆盖：<目标>（指向 <现状>）。接管请确认后手工处理或删除后重跑」 and exit 1 — your existing tooling is never clobbered. Targets pointing into this repo, or missing ones, are (re-)linked idempotently. Restart opencode (or reload plugins) after installing.

## The Two Gates

**req-gate — the entry gate.** An `execute.before` plugin: the session's first product edit/write is blocked until a requirement-gate record exists at `<TMPDIR||/tmp>/opencode/req-gate/<sessionID>.md` (out-of-repo, so worktrees stay clean). The record is your acceptance criteria, written before code: one of `PASS(trivial)` (≤1 file, ≤20 lines), `PASS` (executable acceptance list) or `ESCALATE`. Companions: the `req-check` CLI (cross-checks `docs/reqs/scratch.md` entries against `Req:` tags in code) and the `/req-gate` command.

**review-loop — the exit loop.** A completion plugin: when the session just made product edits after its last review, the next idle nudges the agent to run `/review-loop` — judge → review → fix → green gate → re-review → report. On startup `ensureHooks` idempotently configures `core.hooksPath` (only when unset) so post-commit stamping works without deploying hooks. Companions: post-commit/post-checkout/pre-push hooks, the `/review-loop` command, the knowledge module (`review-loop/module/review-loop.md`) and the e2e suite. The `.review-loop/.last-reviewed` anchor doubles as the open review contract that [opencode-agora](https://github.com/guangbin79/opencode-agora) checks at `done` and re-checks before merge.

## Deployment Targets

| Gate | Symlink | Repo source |
|---|---|---|
| req-gate | `~/.config/opencode/plugins/req-gate-enforcer.ts` | `req-gate/req-gate-enforcer.ts` |
| req-gate | `~/.config/opencode/commands/req-gate.md` | `req-gate/command.md` |
| req-gate | `~/.local/bin/req-check` | `req-gate/req-check` |
| review-loop | `~/.config/opencode/plugins/review-loop-trigger.ts` | `review-loop/review-loop-trigger.ts` |
| review-loop | `~/.config/opencode/commands/review-loop.md` | `review-loop/command/review-loop.md` |

Hooks are not deployed: the review-loop plugin self-configures `core.hooksPath` to its artifact root, which since the 2026-11-08 extraction resolves inside this repo (`review-loop/hooks`, beside the plugin). Legacy `review-loop/install.sh` (enroll/unenroll/audit helpers) now wires from this repo too.

## Verification

```bash
bash -n install.sh && bash tests/install_sandbox.sh
```

The sandbox test runs the installer under a throwaway `HOME` (mktemp) and asserts 11 checks: both gates deploy with symlinks resolving into the repo, re-runs are idempotent, and pre-set foreign targets are refused with exit 1. Live e2e is the operator's step: after deploying and restarting the opencode service, run `review-loop/e2e/review-loop-e2e.sh` (needs tmux + a live opencode serve).

## Configuration

| Env | Default | Description |
|-----|---------|-------------|
| `REQ_GATE_OFF` | off | `=1` makes req-gate inert (uninstall = delete the symlink) |
| `REQ_GATE_DEBUG` | off | `=1` appends gate decisions to the req-gate debug log |
| `REVIEW_LOOP_OFF` | off | `=1` makes review-loop inert |
| `REVIEW_LOOP_DEBUG` | off | `=1` logs every gate evaluation under `.review-loop/` |
| `REVIEW_LOOP_IDLE_MIN_S` | `10` | Idle seconds before completion gates run (e2e/dry-run knob) |
| `REVIEW_LOOP_COOLDOWN_S` | `600` | Marker cooldown window between injections (e2e/dry-run knob) |

## Safety Model

- **Symlink-only deployment** — the plugins keep builtin-only imports (`node:*` resolves through the runtime); copying them next to a plugin loader with bare imports hangs silently. Never convert the symlinks to copies.
- **Refuse-overwrite guard** — foreign files at deployment targets are never replaced; takeover is a manual, confirmed step.
- **Kill switches** — `REQ_GATE_OFF=1` / `REVIEW_LOOP_OFF=1` make each plugin inert without touching files.
- **State stays out of the repo** — req-gate records live under `TMPDIR`; `.review-loop/` is machine-local and gitignored.

## FAQ

**How do I update?** `git pull` and re-run `./install.sh <target>` — deployment is by symlink to this repo, so a pull is enough; the installer just refreshes links (idempotent).

**How do I uninstall?** Delete the five symlinks from the table above (and optionally `git config --unset core.hooksPath` in repos where it points into this checkout, plus the `.review-loop/` marker). Or set the two `*_OFF` switches for a soft disable.

**Does it still need dotfiles?** No. The 2026-11-08 extraction made the artifact root self-locating inside this repo; the `~/.dotfiles` fallback only remains for legacy dotfiles-era layouts.

**Platforms?** Linux (verified, the development environment). macOS should work (bash + coreutils + node only) but is not verified.
