# Spinoff: spinoff's herdr backend can't survive the mandated background agent

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal

Make `/spinoff:start-session` and `/spinoff:start-split` actually launch a herdr
session when herdr is live. Right now the skill's two hard rules contradict each
other, and the failure is silent.

## Why now / context

Reported symptom: a spinoff run lands on `launcher: none`, prints the manual
`cd … && claude` line, and **exits 0 with no `⚠`** — so it reads as success. It
was initially taken for a flaky run. It is not; it looks like a design conflict.

The conflict, in the skill's own words:

- SKILL.md: *"You MUST run the script through a background `Agent`
  (`run_in_background: true`) — never inline in this session. This is not optional."*
- `spinoff.sh:232` and `:237`: the herdr branch is gated on the **environment
  variable** `HERDR_ENV = 1`.

```sh
232  [ "${HERDR_ENV:-}" = 1 ] \
233    && _record_loud herdr "${HERDR:-}" 'HERDR_ENV=1' HERDR_BIN "${HERDR_REJECTED:-}"
237  if   [ "${HERDR_ENV:-}" = 1 ] && _herdr_probe;          then LAUNCHER=herdr
```

`HERDR_ENV` is set by herdr when it spawns the session. It is **not** a flag and
the skill has no documented way to pass it down. The skill *did* anticipate the
`PATH` half of this problem — Step 4 tells the main session to resolve `herdr` and
pass `HERDR_BIN` down, precisely because "the background agent's shell does not
inherit the login shell's `PATH`". But `HERDR_BIN` only survives the binary
lookup. It does nothing for the `HERDR_ENV=1` gate on line 237, which is what
actually selects the backend. Same class of bug, only half-fixed.

There is a second env dependency further down, `spinoff.sh:521`:

```sh
521  if [ -n "${HERDR_PANE_ID:-}" ]; then
522    ws="$("$HERDR" pane get "$HERDR_PANE_ID" …)"
```

`HERDR_PANE_ID` is how the script resolves the *live* workspace (deliberately
preferred over the stale `HERDR_WORKSPACE_ID`). Also env-only, also not passable.
So even if the gate on 237 were forced open, workspace resolution would degrade.

**The nastiest part is what happens next, and it may not be `none`.** Line 250
only suppresses the ghostty backend when `HERDR_ENV` is *empty*:

```sh
250  elif [ -z "${HERDR_ENV:-}" ] && [ -z "${CMUX_WORKSPACE_ID:-}" ] \
251       && { … [ "${TERM_PROGRAM:-}" = ghostty ] … } && _ghostty_probe;  then LAUNCHER=ghostty
```

That suppression exists because herdr runs *inside* ghostty here (both sets of
vars are present in a real session). If the background agent loses `HERDR_ENV`
but keeps `TERM_PROGRAM=ghostty`, the guard on 250 inverts from protection into a
trigger and the script opens a **bare ghostty window beside the user's herdr
layout** — exactly the outcome the comment on 243–244 says it must never do. So
depending on what the agent's shell inherits, the bug is either a silent `none`
or a stray window. Establish which before designing the fix.

## Key decisions already made

- **Fix the script, not the skill's workaround.** SKILL.md is explicit: *"if the
  script does the wrong thing, FIX THE SCRIPT, don't work around it by hand."*
  Do not solve this by telling the skill to run inline — the background-agent rule
  exists to keep ~40 lines of step output and a readiness poll out of the main
  session, and that reason is still good.
- **The main session is the only place that can answer "what backend owns this
  session".** That is already the established pattern for `HERDR_BIN` and
  `--from-surface`; extending it to the announcement itself is consistent with the
  design rather than a new idea.
- **A silent wrong answer is the real defect.** The skill's own exit-code table
  treats `launcher: none` at exit 0 as *legitimate* (a worktree-only spinoff). That
  is correct when nothing announced a backend — and wrong when a backend announced
  itself and got lost in transit. Whatever the fix, that case must become loud. The
  script already has the machinery: `_record_loud` / `$LOUD_*` drive the `⚠` and
  exit 4, and its comment on 200–205 names this exact bug class ("the same
  lying-message defect this change exists to remove").

## Open questions / not yet decided

1. **What does a background agent's shell actually inherit?** This is the whole
   premise and it has NOT been measured. The main session's Bash tool *does* see
   `HERDR_ENV=1` (verified). A subagent may share that process env — in which case
   the herdr path works and the reported failure has a different cause. **Measure
   before designing anything.** Cheapest probe: a background agent that runs
   `env | grep -E 'HERDR|CMUX|GHOSTTY|TERM_PROGRAM'` and reports back.
2. If the env *is* lost — how to pass the announcement? Options, roughly in
   ascending invasiveness: an env prefix on the dispatch command (same shape as
   `HERDR_BIN`, needs no script change but does need `HERDR_ENV` + `HERDR_PANE_ID`
   documented as passable); explicit `--launcher-announce` / `--from-pane` flags;
   or having the script detect a live herdr session from the server rather than
   from env vars at all. The last is the most robust and the biggest change.
3. Does `--launcher herdr` already work around this today? Line 221 forces the
   probe and skips the env-keyed detection — so a forced launcher may reach herdr
   without `HERDR_ENV`. If so it is a usable stopgap, but workspace resolution
   (521) still degrades to the frozen/absent `HERDR_WORKSPACE_ID`. Check what it
   actually produces before recommending it.
4. Is `/spinoff:start-workspace` affected the same way? It takes the same
   `resolve_launcher` path, so probably yes — confirm rather than assume.
5. Does the cmux path have the identical hole? Line 238 gates on
   `CMUX_WORKSPACE_ID`, also env-only. If cmux works in practice, the difference
   is evidence about what agents inherit — worth knowing either way.

## Starting point

- `~/projects/shrimpshack/plugins/spinoff/skills/spinoff/scripts/spinoff.sh`
  - `resolve_launcher()` — lines 219–255. The gate (232, 237), the ghostty
    suppression (250–252), the `none` fallback (253).
  - `_record_loud()` — lines 206–213, plus the design note at 196–205.
  - Workspace resolution from a live pane — lines 511–547.
  - Binary resolution + the `HERDR_BIN` override — lines 1219–1221.
- `~/projects/shrimpshack/plugins/spinoff/skills/spinoff/SKILL.md` — the
  "You MUST run the script through a background `Agent`" rule in Step 4, the
  binary-resolution table, and the exit-code table (which needs revisiting if
  "announced but lost in transit" becomes a new loud case).
- Repo is at `plugins/spinoff` version **0.9.1** — the same version currently
  installed in the plugin cache.

**Do not forget the plugin cache.** Merging a fix in `~/projects/shrimpshack`
does not fix the live behavior: Claude Code runs the *installed* copy under
`~/.claude/plugins/cache/shrimpshack/spinoff/<version>/`. The fix only takes
effect after the plugin version is bumped and the cache re-installs. Plan the
version bump as part of the change, and verify against the cached path, not the
source tree.

## Verification note

This spinoff run is itself the experiment. It was dispatched exactly as SKILL.md
mandates — background agent, `HERDR_BIN=/opt/homebrew/bin/herdr` passed down,
`--target tab`, herdr live and probed from the main session. Whatever launcher it
reports is a real data point for open question 1:

- reports `herdr` → the premise is wrong; the agent inherits the env, and the
  original `launcher: none` had some other cause worth chasing.
- reports `none` → premise confirmed; the announcement is lost in transit.
- reports `ghostty` (a bare window appeared) → premise confirmed *and* the
  line-250 inversion above is real, which is the more urgent of the two.

Read the dispatch result before touching code.

## Recommended next step

`/ce-brainstorm`. The defect is well localized but the *fix* is not: option 2
above spans "add an env prefix to a doc" through "stop keying detection off env
vars entirely", and that choice needs a shape before it needs a plan. Run the
measurement in open question 1 first — it may collapse the whole problem — then
brainstorm the passing mechanism.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/1e90b332-cb44-41ea-8b7c-186fff0104fb.jsonl`
Resume:     `cd /Users/shawnroos && claude -r 1e90b332-cb44-41ea-8b7c-186fff0104fb`
