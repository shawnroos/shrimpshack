# Spinoff: spinoff v0.9.0 — kickoff + handoff-refs fixes, ghostty backend, split target

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal

Ship spinoff v0.9.0: two real bug fixes (the kickoff never fires; handoff doc
references dangle) plus two features (a third launcher backend for **ghostty** via
AppleScript, and a **split** target that opens in the current tab instead of a new one).

## Why now / context

Shawn hit both bugs repeatedly in daily use:

1. *"The first message in the new spinoff session is not being entered into the chat —
   the session starts empty and I'm having to tell the agent to read the handoff."*
2. *"Agents are continually telling me the docs being referenced in the handoff are
   not there."*

Both were diagnosed at runtime in the originating session — see below. **These are
findings, not hypotheses.** Don't re-derive them; do re-verify cheaply before building.

## Key decisions already made

- **Fix 1 root cause (VERIFIED).** `spinoff.sh:461` calls `herdr agent send <pane> <text>`.
  **That subcommand no longer exists in herdr 0.7.5.** Confirmed against `herdr agent --help`:
  the verbs are `list get read send-keys prompt rename focus wait attach start explain`.
  The call is wrapped in `>/dev/null 2>&1`, so it fails silently; line 462 then fires a bare
  `Enter` into an empty prompt → empty session.
- **Fix 1 direction.** Replace with `herdr agent prompt <target> <text> --wait --until idle
  --timeout <ms>`, which submits directly. This collapses the stage→Enter→retry dance
  (lines 461–473) into one call and makes the "EXACTLY ONE submit" invariant *structural*
  rather than hand-maintained. Delete the `"Read docs/handoff.md"` screen-scrape retry guard —
  `--wait` supersedes it.
- **Stop swallowing stderr.** `>/dev/null 2>&1` is *why* a removed subcommand went unnoticed.
  A non-zero exit must set `KICKOFF_OK=0` and surface. This is the real lesson, not the one-liner.
- **RULED OUT for fix 1:** the readiness markers. `shift+tab to cycle` still appears in live
  Claude panes (checked directly), so `launcher_wait_ready_herdr` is fine. Don't touch it.
- **Fix 2 root cause.** NOT gitignore. `spinoff.sh:749-767` already copies the whole `docs/`
  tree with `find`+`cp`, so git status is irrelevant to it — and `docs/` isn't even ignored in
  Slate web-app (checked). The actual bug: the handoff is authored from the ORIGIN session and
  cites docs at ORIGIN paths, but (a) the copy is scoped to `$REPO_ROOT/docs` only, so any
  referenced doc outside that dir is never carried, (b) references are never rewritten to
  worktree-relative paths, and (c) nothing verifies references resolve before reporting success.
- **Fix 2 direction.** Invert it: derive the copy set FROM the handoff's own references — parse
  paths out of the handoff, resolve against origin, copy into the worktree, rewrite each
  reference to its worktree path, then **gate on "every referenced path resolves."** A dangling
  reference must fail loudly, not silently. Keep the existing `docs/` sweep as a cheap superset.
- **Update 0 — the seam already exists.** `resolve_launcher()` + 7 neutral verbs
  (`new_tab`, `new_workspace`, `find_left_pane`, `launch_agent`, `wait_ready`, `send_kickoff`,
  `open_viewer`) dispatch on `$LAUNCHER`. cmux + herdr implemented, `none` is the fallback.
  ghostty is a third backend implementing the same verbs. **Research the API before coding** —
  there's a `ghostty-applescript` skill on this machine; consult it.
- **Update 1 — split target.** Same behavior as `--target tab` but splits the current tab.
  Needs a new verb (`launcher_new_split`) + a `--target split` value + a command surface.
- **Sequencing.** Fix 1 first and alone: until the kickoff fires, nothing downstream is
  observable end-to-end (including whether fix 2 worked), and it rewrites the exact region
  Update 0 must reimplement. Then Fix 2 ∥ ghostty research (disjoint — handoff/filesystem vs
  read-only research). Then the ghostty backend. Then split last (needs ghostty to exist, or
  it ships 2-of-3).

## Open questions / not yet decided

- **Can ghostty reach parity at all?** Ghostty's AppleScript support is thin — largely
  `System Events` keystroke driving, not a real scripting dictionary. If it can't return a
  tab/pane identifier, `wait_ready` and `send_kickoff` can't work the way cmux/herdr do, and
  the backend may land as "opens a briefed tab, best-effort" rather than full parity.
  **Decide this in research, before building on it, and tell Shawn.**
- Split + ghostty is the hardest combination: cmux and herdr split natively and return a pane
  id; a ghostty split is a keystroke with no handle back. May need a different readiness strategy.
- Does `--target split` deserve its own command (`/start-split`) or just a flag on `/start`?
- Version: 0.8.3 → 0.9.0 assumed. Confirm before the release commit.

## Starting point

- `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` — 930 lines, heavily commented with
  prior-decision rationale. **Preserve that commenting style; do not strip the "why" comments.**
  - `:38` `resolve_launcher`  ·  `:52-58` the neutral verb dispatchers
  - `:405` `launcher_wait_ready_herdr`  ·  `:451` `launcher_send_kickoff_herdr` ← **fix 1 here**
  - `:749` docs carry-over  ·  `:769` dotfile allowlist ← **fix 2 here**
- Tests to keep green and extend: `skills/spinoff/scripts/spinoff.bats`,
  `kickoff-gate.test.sh`, `smoke.sh`.
- `plugins/spinoff/SKILL.md` + `commands/*.md` need updating for any new target/backend.
- **Add a regression test that fails if the script invokes a herdr subcommand absent from
  `herdr agent --help`.** That is the test that would have caught this bug.

## Known traps (from memory + this session)

- `~/.claude/plugins/cache/shrimpshack/spinoff/<ver>/` is a CACHE — plugin updates overwrite it.
  Source of truth is `~/projects/shrimpshack/plugins/spinoff`. (The originating session applied a
  temporary one-line `agent prompt` patch to the CACHE so this very spinoff could launch — it is
  throwaway; do the real fix in the repo.)
- Memory `reference_herdr_stage_command_pane_send_text` documents the removed `agent send` and is
  **STALE** — update it as part of this work.
- `/tmp/spinoff-handoff.md` is a SHARED path; concurrent spinoffs clobber it
  (memory `spinoff_handoff_shared_tmp_collision`). This handoff was written to a
  session-isolated path instead. Consider making the script default to that.
- herdr env does not propagate into background agents
  (`reference_spinoff_bg_agent_loses_herdr_env`, `feedback_spinoff_bg_agent_herdr_env_propagation`).
- `timeout` (coreutil) does not exist on this box; `cp`/`mv` are aliased `-i` interactively.
- `/ce-plan`, `/ce-doc-review`, `/ce-code-review` were NOT loading in the originating session —
  compound-engineering 3.21.0 registered zero skills after a reload. Check `/plugin` before
  relying on the CE review loop.

## Recommended next step

`/ce-plan`. Scope and approach are settled — two root causes are verified with file:line, the
sequencing is decided, and the only genuine unknown (ghostty's automation surface) is a bounded
research task rather than an open design question. That's a plan, not a brainstorm.

**Caveat:** confirm `/ce-plan` actually loads first (see traps). If compound-engineering is still
dark, plan directly and don't block on it.

## Source session

Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/6c8d4340-4938-4d59-8719-f6a1cf76eecf.jsonl`
Resume:     `cd /Users/shawnroos && claude -r 6c8d4340-4938-4d59-8719-f6a1cf76eecf`
