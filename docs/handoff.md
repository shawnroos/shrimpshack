# Spinoff: fix spinoff.sh doc-carry gaps + kickoff truncation

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal
Two independent, agent-reported defects in the spinoff launcher
(`plugins/spinoff/skills/spinoff/scripts/spinoff.sh`):

1. **Docs aren't carried into the new worktree** — the "recent docs" filter reports
   `docs: 0 carried` and the new worktree's handoff references files that aren't there.
2. **The kickoff prompt sent to the launched Claude is cut off** — it's too long for a
   single terminal paste, so the briefed session receives a truncated instruction.

## Why now / context
Both surfaced live during real spinoffs this session. #1 stranded a briefed session whose
handoff pointed at a "U5 assessment" + parent plan that were never copied in — so the
receiving agent couldn't read its own referenced source. #2 means the carefully-worded
"treat the handoff as directional" kickoff is arriving chopped, defeating its purpose.

## The two defects, grounded in code

### Defect 1 — doc-carry misses uncommitted + stale + oddly-named files
`spinoff.sh:235-247`:
```sh
if [ -d "$REPO_ROOT/docs" ]; then
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    [ "$base" = "handoff.md" ] && continue
    cp "$f" "$WORKTREE/docs/$base" 2>/dev/null && CARRIED=$((CARRIED+1))
  done < <(find "$REPO_ROOT/docs" -maxdepth 1 -type f -mmin -360 \
            \( -iname '*plan*' -o -iname '*brainstorm*' -o -iname '*requirement*' -o -iname '*notes*' \) \
            -print0 2>/dev/null)
fi
```
Three compounding filters drop real content:
- **`-mmin -360`** — only files modified in the last 6h. The agent report explicitly hit
  this: "the U5 assessment and the parent plan … are uncommitted in this worktree and now
  >6h old." Stale-but-relevant docs vanish.
- **name patterns** (`*plan*|*brainstorm*|*requirement*|*notes*`) — anything named
  differently (an assessment, a spec, a diagram) is skipped.
- **`-maxdepth 1`** — nested docs (`docs/plans/…`, `docs/assessments/…`) are skipped even
  though handoffs routinely reference `docs/plans/....md`.

Also note the deeper reason files "aren't there": **a git worktree only materializes
COMMITTED content.** Uncommitted/gitignored files in the source repo (`.env`, work-in-progress
docs) simply don't exist in the fresh worktree unless explicitly copied.

**Requested change (from Shawn):** copy the **entire `docs/` folder** into the new worktree,
**plus any dotfiles including `.env` files**, so the briefed session can actually read what
its handoff points at and run against real config.

Design considerations to validate as you build:
- Copy the full `docs/` tree recursively (preserve subdirs), not just top-level name-matched
  files. Skip re-copying `handoff.md` (the script writes that itself at `docs/handoff.md`).
- Dotfiles: carry root-level dotfiles/`.env*` from `$REPO_ROOT` into `$WORKTREE`. Decide the
  scope deliberately — `.env`, `.env.*`, `.envrc` are the clear wins; be cautious about
  blindly copying every dotfile (`.git` must NOT be touched; `.DS_Store` etc. are noise).
  A safe allowlist (`.env`, `.env.*`, `.envrc`, `.tool-versions`, `.nvmrc`) is probably
  better than a blanket `cp .[^.]*`. Confirm the intent with the code/tests.
- **Don't clobber**: if a worktree file already exists (committed), prefer not to overwrite
  it with an older source copy — or at least be intentional about precedence.
- **Security footnote worth a line in the handoff:** copying `.env` into a worktree spreads
  secrets to another on-disk location. It's what was asked for and it's local-only, but note
  it; don't, e.g., ever commit the carried `.env` (ensure worktree `.gitignore` still covers it).
- Update the `step "carried docs: N …"` message + the final `docs: $CARRIED carried` summary
  (`spinoff.sh:247,386`) to reflect the new, broader carry (maybe split docs vs dotfiles counts).

### Defect 2 — kickoff prompt truncated on send
`spinoff.sh:255` defines `KICKOFF` as a ~1080-char single-line string; `spinoff.sh:279`
sends it in one shot: `"$CMUX" send --surface … "$KICKOFF"`. A paste that long overruns the
Claude TUI input line, so the launched session gets a cut-off instruction. (There's already a
resubmit-guard at `285-289` matching `*"Read docs/handoff.md"*`, but that only re-sends Enter —
it doesn't fix truncation of the body.)

**Requested change (from Shawn):** the spin-off prompt is being cut off — shorten it.

The clean fix (validate against the code): the long "treat the handoff as directional…" prose
**already lives verbatim in every handoff** (see the block quote at the top of this file and
`spinoff.sh:203-233` handoff assembly). So the kickoff doesn't need to restate it — collapse
`KICKOFF` to a short pointer, e.g.:
> "Read docs/handoff.md — it's the brief for this worktree (treat it as directional: orient
> and validate against the code, don't execute literally). Get oriented, then recommend the
> next compound-engineering step (/ce-brainstorm if ambiguous, /ce-plan if clear) with a
> one-line rationale, and wait for my direction."

Alternatives to weigh: write the full kickoff to `docs/kickoff.md` in the worktree and point
at it; or chunk the send. The pointer-collapse is simplest and keeps the directional framing
where it's authoritative (the handoff). Keep the resubmit-guard's match string in sync with
whatever the new first line is (`spinoff.sh:286`).

## Key decisions already made
- Fix both in the canonical script `plugins/spinoff/skills/spinoff/scripts/spinoff.sh`. The
  installed skill at `~/.claude/skills/cmux-spinoff/` is the publish target — don't hand-edit
  it; it's regenerated on publish.
- Shrimpshack `main` is in sync with `origin/main` at branch time — base is current HEAD.
- Carry the **whole** `docs/` tree + `.env`/dotfiles (allowlist), not a widened name filter.

## Open questions / not yet decided
- Exact dotfile allowlist vs blanket copy — pick the conservative allowlist unless there's a
  reason for more.
- Overwrite precedence when a carried file already exists in the worktree.
- Whether to also carry `docs/` from nested plan dirs by default (likely yes — recursive).
- Is there an eval harness under `~/.claude/skills/cmux-spinoff/evals/` worth extending with a
  case for "referenced doc exists in worktree" and "kickoff length ≤ safe paste width"?

## Starting point
- **Read first:** `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` — doc-carry block
  `235-247`, `KICKOFF` def `255`, send site `279`, resubmit-guard `285-289`, summary line `386`.
- Handoff assembly (where the directional prose is authoritative): `203-233`.
- Skill spec: `plugins/spinoff/skills/spinoff/SKILL.md` (and installed mirror
  `~/.claude/skills/cmux-spinoff/SKILL.md`).
- Evals: `~/.claude/skills/cmux-spinoff/evals/`.
- After changing, re-publish so `~/.claude/skills/cmux-spinoff/` picks up the new script
  (shrimpshack marketplace publish workflow — bump version; publish is version-gated).

## Recommended next step
`/ce-plan`. Both defects are well-scoped with the fix shape already identified (recursive
docs-copy + dotfile allowlist; collapse KICKOFF to a pointer), but it's a multi-part change to
a launch-critical script with real edge cases (overwrite precedence, secret-spread, resubmit
guard sync, publish/version bump), so it warrants a short structured plan rather than a
straight edit. Validate the fix shapes against the code before writing the plan.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/dde8ee69-bcee-40bd-a003-27e56020f197.jsonl`
Resume:     `cd /Users/shawnroos/projects/shrimpshack && claude -r dde8ee69-bcee-40bd-a003-27e56020f197`
