# Spinoff: spinoff — launcher binary resolution is PATH-fragile and the failure message lies

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal

Make `spinoff.sh` resolve its launcher binaries (`herdr`, `cmux`) robustly instead of
depending on the caller's `PATH`, and make the fallback message tell the truth about
*which* of two very different failures occurred. Live bug in shipped **v0.9.0**.

## Why now / context

A `/start` spinoff ran, created the branch + worktree + handoff correctly, and then
**silently skipped the launch**, reporting:

```
▸ not inside cmux/herdr (or the CLI is missing) — skipping launch automation
```

Exit code `0`. Zero `⚠` lines. It read as a clean run that simply wasn't in a
multiplexer — but the session *was* inside a live herdr, and `HERDR_ENV=1` had been
exported into the background agent explicitly.

**The worst part: it's non-deterministic.** An earlier spinoff the same hour, from the
same session with the identical export block, resolved `herdr` and launched fine. Same
command, different outcome, depending on what `PATH` the background agent happened to
inherit.

## Key decisions already made

- **Root cause (VERIFIED).** `spinoff.sh:1027` (v0.9.0; `:581` in 0.8.3):
  ```bash
  HERDR="$(command -v herdr 2>/dev/null)"
  ```
  `herdr` lives at `/opt/homebrew/bin/herdr`. If that dir isn't on `PATH`, `HERDR` is
  empty → `_herdr_probe()` (`:43`) short-circuits on `[ -n "${HERDR:-}" ]` → 
  `resolve_launcher()` falls through to `LAUNCHER=none`.
- **Proven both directions, not inferred:**
  - `env -i PATH=/usr/bin:/bin … command -v herdr` → not found
  - `env -i PATH=/opt/homebrew/bin:/usr/bin:/bin …` → `/opt/homebrew/bin/herdr`,
    `status: running`, `version: 0.7.5`
- **v0.9.0 does NOT fix this.** Confirmed against `origin/main` — still the bare
  `command -v herdr` at `:1027`, and `grep` finds no PATH guard anywhere in the script.
- **The message conflates two unrelated conditions**, and that's arguably the worse bug:
  - *"not in a multiplexer"* → correct, benign, silent fallback is right.
  - *"multiplexer env says we ARE in one, but the binary isn't findable"* → a **broken
    environment**. That deserves a loud `⚠`, not a silent degrade to `none`.
  `HERDR_ENV=1` with no resolvable `herdr` is never a legitimate steady state.
- **Direction.** Two parts, both needed:
  1. **Resolve robustly** — honor an explicit override (`HERDR_BIN` / `CMUX_BIN`), then
     `command -v`, then a small list of known install locations (`/opt/homebrew/bin`,
     `/usr/local/bin`, `~/.local/bin`). Don't just prepend to `PATH` blindly; resolve to
     an absolute path and use it.
  2. **Split the diagnostics** — when the env indicates a backend but its binary can't be
     resolved, emit a `⚠` naming the binary and where it looked, and make the exit code
     reflect an incomplete launch. Silence + exit 0 is what let this look like success.
- **Applies to BOTH backends.** `_cmux_probe()` has the same shape (`[ -n "${CMUX:-}" ]`);
  fix them symmetrically. Ghostty (new in v0.9.0) likely has the same exposure — check it.
- **The deeper lesson worth encoding:** background agents do NOT inherit the login shell's
  `PATH`. Any script the plugin expects to run from a subagent must resolve its tools
  absolutely rather than assume an interactive-shell environment.

## Open questions / not yet decided

- Should an unresolvable-but-expected backend be **fatal** (non-zero exit, no worktree
  churn) or **degrade loudly** (worktree + handoff still produced, `⚠`, non-zero exit)?
  Leaning: degrade loudly with a non-zero exit — the worktree is still valuable, but the
  run must not report success.
- Is `HERDR_BIN`/`CMUX_BIN` the right override name, or should it read herdr's own
  conventions? (`HERDR_SOCKET_PATH` etc. already exist — match that family.)
- Does the same fragility affect other tools the script shells out to (`git`, `glow`,
  `bat`, `python3`)? `glow`/`bat` are already best-effort, but worth an audit pass.
- Should there be a `--launcher-bin <path>` flag for testing, or is env enough?

## Starting point

- `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` (v0.9.0 on `origin/main`):
  - `:43` `_herdr_probe` / `_cmux_probe` — the `[ -n "${HERDR:-}" ]` short-circuit
  - `:1027` `HERDR="$(command -v herdr 2>/dev/null)"` — the actual resolution
  - `resolve_launcher()` — where the fallthrough to `none` happens and where the
    misleading message originates
- Tests: `skills/spinoff/scripts/spinoff.bats`, `kickoff-gate.test.sh`, `smoke.sh`.
  **Add a case that runs `resolve_launcher` under a stripped `PATH` with `HERDR_ENV=1`
  set** and asserts a loud failure rather than a silent `none`. That is the test that
  would have caught this.
- The script is heavily commented with prior-decision rationale — preserve that style,
  and note that the existing comment at `:30` ("a stale `HERDR_ENV=1` must not win — R8")
  shows the *opposite* case was already considered. This is its mirror image: a live
  `HERDR_ENV=1` that loses to an unfindable binary. Worth calling out in the comment.

## Known traps

- Source of truth is `~/projects/shrimpshack/plugins/spinoff`. The copy under
  `~/.claude/plugins/cache/shrimpshack/spinoff/<ver>/` is a CACHE that plugin updates
  overwrite. (The originating session hand-patched the 0.8.3 cache for an unrelated
  kickoff bug — that patch is throwaway and irrelevant here.)
- **This very spinoff had to work around the bug it is fixing** — the dispatching agent
  exported `PATH=/opt/homebrew/bin:…` explicitly so the launch would succeed. Don't
  mistake that workaround for the fix.
- Reproducing needs a deliberately stripped `PATH`; it will not reproduce from an
  interactive shell where homebrew is already on `PATH`.
- `/ce-plan`, `/ce-doc-review`, `/ce-code-review` were NOT loading in the originating
  session — compound-engineering 3.21.0 registered zero skills after `/reload-plugins`.
  Check `/plugin` before relying on the CE loop.
- Related memories: [[reference_spinoff_bg_agent_loses_herdr_env]],
  [[feedback_spinoff_bg_agent_herdr_env_propagation]] — this is the same family
  (background-agent environment is not the main session's environment), but a distinct
  failure: those are about *env vars*, this is about the *binary path*.

## Recommended next step

`/ce-plan`. The root cause is verified with file:line and reproduced both directions,
and the design has two clear parts (robust resolution + honest diagnostics). The open
questions are implementation choices, not scope questions — that's a plan, not a
brainstorm. It's a small, well-bounded fix; don't over-orchestrate it.

## Source session

Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/6c8d4340-4938-4d59-8719-f6a1cf76eecf.jsonl`
Resume:     `cd /Users/shawnroos && claude -r 6c8d4340-4938-4d59-8719-f6a1cf76eecf`
