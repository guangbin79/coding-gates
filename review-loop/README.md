# review-loop (standalone artifact)

Self-contained review-loop: trigger plugin + post-commit hook + `/review-loop` command + knowledge module + e2e, all in this directory.

## Usage
- `install.sh install` — wire machine-level symlinks (plugin + command file)
- `install.sh enroll <repo>` — enable in a repo: `core.hooksPath` → this artifact's hooks + create `.review-loop/` marker
- `install.sh unenroll <repo>` — disable: unset `core.hooksPath` (only if artifact-managed) + remove marker
- `install.sh audit` — list enrolled repos on this machine (finds `.review-loop`)
## Headless wrapper (run-with-review.sh)
For non-interactive `opencode run` callers without their own orchestration (CI bots, auto-fix pipelines):

- Invocation: `run-with-review.sh run <flags> <message>` — passes argv through to `opencode "$@"`, then appends one bounded review run.
- Env knobs: `REVIEW_LOOP_TIMEOUT` (seconds, default 1800), `REVIEW_LOOP_EVIDENCE_DIR` (evidence dir, resolved to an absolute path, default `<repo-root>/.review-loop/`), `REVIEW_LOOP_HEADLESS=1` (pure passthrough, recursion guard).
- Attribution: the wrapper tags the work run with `REVIEW_LOOP_WRAP_ID`; the post-commit hook stamps it into the flag's origin line, and the wrapper only consumes flags it owns (mtime ≥ start AND origin match) — at-most-once via rename-claim.
- Exit code: always the work run's exit code; review timeout/failure is non-blocking (logged to stderr).
- Not applicable: integrations with their own review orchestration (cross-branch ranges, temp worktrees, push control — see module "headless lane" 分工判据) keep direct prompt invocation of `/review-loop`.

## Repo hygiene
Add `.review-loop/` to each enrolled repo's `.gitignore` — the state dir is machine-local and must never be committed.
