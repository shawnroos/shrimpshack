# Spinoff: make spinoff root- and workspace-aware (always worktree from the *right* repo)

## Goal
Teach the spinoff plugin to resolve **which repo** a new worktree should root in —
rather than assuming the originating session's cwd is already inside the target git
repo. Two facets: (1) **repo-root awareness** so worktrees always branch from the
right repo (and a fresh base), and (2) **workspace awareness** so a new tab defaults
to the same cmux workspace it was forked from. Add a little pre-flight "prep" so the
common failure modes can't happen silently.

## Why now / context
This session ran **three** `/start` spinoffs back-to-back, and every one hit the same
wall: the originating session's cwd is `/Users/shawnroos`, which is **not a git repo**.
`spinoff.sh:53` does `REPO_ROOT="$(git rev-parse --show-toplevel)" || die "not inside
a git repo"` — so the script would have died. We worked around it each time by having
the dispatched background agent **manually `cd` into the target source repo first**
(`cd ~/projects/reflect && bash spinoff.sh …`). That hand-`cd` workaround IS the gap
to close: the script should know, or be told, the intended repo.

Second, recurring root problem: the target repos kept being **stale**. `~/projects/
shrimpshack` local `main` is 6 commits behind `origin/main` (HEAD `aa0b2d6` vs
`77cad7c`) and still carries the *old* `plugins/cmux-spinoff/` layout; the renamed
`plugins/spinoff/` only exists on `origin/main`. So "the right root" isn't only the
right *directory* — it's the right *base ref* (fresh, not a stale local branch). We
hand-corrected the base to `origin/main` twice this session.

## Key decisions already made / grounding
- **Don't re-solve the worktree-vs-main-tree case.** `spinoff.sh:54-61` already walks
  from a linked worktree back to the MAIN working tree so worktrees nest under the
  primary repo. That part is correct — leave it.
- **The gap is *upstream* of line 53**: deciding which repo when cwd isn't in one.
  The `/start` main session that calls the script **already knows** the target repo
  (it's reasoning about the work) — the cleanest lever may be: SKILL.md instructs the
  main session to resolve + pass the repo explicitly (e.g. a new `--repo <path>` flag),
  and the script `cd`s / uses `git -C "$REPO"` instead of relying on cwd.
- **Branch base = `origin/main`, NOT local HEAD.** Local `main` is 6 behind and stale;
  branching off local HEAD reproduces the old layout. (This is why the usual
  "branch off current HEAD" recommendation is inverted for this repo right now.)
- **Concurrent work on the same file.** `feature/session-naming` (worktree
  `~/projects/shrimpshack/worktrees/session-naming`, `1a87867`) is an in-flight spinoff
  that ALSO edits `spinoff.sh` (adding `claude --name`). Expect a merge with it; keep
  edits localized and rebase on `origin/main` before landing. (There's also an
  unrelated `bugfix/detector-misfire-fix` worktree — ignore it.)

## Open questions / not yet decided (the design space)
1. **Where does repo-awareness live?** Options, likely combined:
   - (a) **Caller passes it** — new `--repo <path>` flag; SKILL.md Step 4 resolves the
     repo in the main session (it has the context) and passes it. Most deterministic.
   - (b) **Script infers from the cmux workspace** — read the primary/agent pane's cwd
     of the current workspace and use *that* repo. This is the "workspace awareness"
     half; needs a cmux query for the workspace's panes + their cwds.
   - (c) **Prompt / fail loud** with a helpful message when it can't resolve, instead
     of `die "not inside a git repo"`.
2. **Freshness prep:** should the script (or SKILL.md) check whether the chosen base is
   behind its remote and `git fetch` / warn before `worktree add`? We hit stale-base
   twice — some guard seems warranted. How aggressive (auto-fetch vs warn-only)?
3. **"Default to the same workspace"** — is the current `--target tab` (opens on the
   current workspace's left agent pane) already enough, or does the user want active
   detection that the new tab's repo == the workspace's repo? Clarify the intended
   behavior with the workspace as the anchor.
4. Interaction with `--session-cwd`: the script already takes the originating cwd for
   the resume link — could the *repo* be derived from there too when it IS a git repo?

## Starting point (concrete)
- Source repo: `~/projects/shrimpshack` (origin `shawnroos/shrimpshack`). **Branch from
  `origin/main` (`77cad7c`)** — local `main` is stale.
- Plugin path on origin/main: `plugins/spinoff/` (the renamed layout). The script:
  `plugins/spinoff/skills/spinoff/scripts/spinoff.sh`.
  - Repo/root resolution to change: **lines 52-65** (esp. `53` die-on-no-repo, `56-61`
    main-tree walk, `65` `WORKTREE="$MAIN_ROOT/worktrees/$NAME"`).
  - Flag parsing block (~line 22-40) — where a new `--repo` would be added.
  - `git -C "$MAIN_ROOT" worktree add …` at ~line 97 — already uses `git -C`, so
    threading an explicit root through is mostly mechanical.
- Procedure doc: `plugins/spinoff/skills/spinoff/SKILL.md` — Step 4 (arg selection) and
  Step 3 (transcript/cwd resolution) are where caller-side "prep" instructions go.
- Live cmux query for workspace panes/cwds: see the `cmux` skill (topology/surfaces).
- Concurrent worktree to coordinate with: `feature/session-naming`.

## Recommended next step
`/ce-brainstorm` — the *intent* is clear but the *mechanism* is a genuine design choice
(caller `--repo` flag vs cmux-workspace inference vs both, and how much freshness prep
to bake in). A short brainstorm to pick the lever, then `/ce-plan`. If you'd rather
skip ahead: the (a)+`--repo`+SKILL.md-prep path is the lowest-risk MVP and could go
straight to `/ce-plan`. Validate against the actual script before committing.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/dde8ee69-bcee-40bd-a003-27e56020f197.jsonl`
Resume:     `cd /Users/shawnroos && claude -r dde8ee69-bcee-40bd-a003-27e56020f197`
