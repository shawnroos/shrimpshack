---
name: spinoff
description: >-
  Command-invoked only (via /start-session, /start-split, /start-workspace, or the
  /start alias) — do NOT trigger this skill from conversational phrasing on your own.
  It forks the current thread of work into its own place: takes the topic/plan/idea
  just discussed and moves it into a fresh git worktree with a new, already-briefed
  Claude session, so this session stays focused and the new one picks up the context.
  Branches a worktree (from current HEAD or develop), writes a handoff doc linking
  back to this session's transcript, carries over recent plan/brainstorm docs, and
  boots a briefed Claude — in a new tab on the current workspace (/start-session),
  beside the pane you're in (/start-split), or in a brand-new two-pane workspace with
  the handoff alongside (/start-workspace) — using whichever launcher backend is live
  (herdr, cmux or ghostty, auto-detected). The mechanical work runs in a background
  agent so it doesn't consume this session's context. Only run when the user
  explicitly invokes one of the commands — if they merely describe wanting to fork
  work, suggest the command rather than acting.
---

# Spinoff

**Invoked only via `/start-session`, `/start-split`, `/start-workspace`, or the
`/start` alias.**
This skill has real side effects (creates a worktree, opens a tab or workspace,
launches a Claude session) so it runs only on those explicit commands — never
auto-triggered from how the user happens to phrase something. If the user
describes wanting to fork work but hasn't run a command, point them to one rather
than doing the spinoff.

Turn "what we just figured out" into its own parallel workstream: a fresh
worktree + a fresh Claude session, with a handoff doc that lets the new session
pick up exactly where this one left off.

This exists because the most expensive thing lost between sessions is *context* —
the why, the dead-ends, the decisions. A spinoff that just makes a branch loses
all of that. So the heart of this skill is writing a genuinely useful handoff,
not the mechanical git/terminal plumbing (which the bundled script handles).

## Three commands, one skill

| Command | Where the new Claude lands |
| --- | --- |
| `/start-session` (and the `/start` alias) | A new **tab** on the current workspace's left agent pane — `--target tab`. |
| `/start-split` | **Beside the pane you're in**, in the current tab — `--target split`, plus `--split-direction right|left` (default right). |
| `/start-workspace` | A **brand-new workspace**: briefed Claude on the left, the handoff markdown rendered alongside on the right — `--target workspace`. |

All three run the same `spinoff.sh`; they differ only in the `--target` they pass
(and, for split, the direction and the originating surface).

## Three backends: herdr, cmux or ghostty (auto-detected)

The launch is driven through a backend the script picks at run time — **herdr**,
**cmux** or **ghostty** — so `/start` works in whichever terminal this session is
running in. You don't choose it; the script detects it. The `--launcher` flag
(`herdr | cmux | ghostty | auto`, default `auto`) forces a backend or leaves it to
detection:

- **`auto`** (default) — pick **herdr** when `HERDR_ENV=1` *and* the herdr server is
  live (a `herdr status server` probe — a stale `HERDR_ENV` never wins); else **cmux**
  when `CMUX_WORKSPACE_ID` is set and the cmux CLI resolves; else **ghostty** when
  Ghostty is the terminal *and* no multiplexer announced itself at all; else **none**
  (worktree + handoff still produced, plus a manual `cd … && claude` line). Landing on
  **none** is only a success when nothing announced a backend — if something did and
  the launch never happened, the run exits 4 or 5. Precedence is explicit:
  **herdr (live) > cmux > ghostty > none**.
- Ghostty is deliberately suppressed whenever `HERDR_ENV` or `CMUX_WORKSPACE_ID` is
  set, even if the multiplexer's own probe then fails. Those vars are both present
  inside herdr-running-in-ghostty, and a multiplexer that announced itself owns the
  session — opening a bare ghostty window would be the wrong recovery. That
  suppression is also the direct route to **exit 5**: an announced multiplexer whose
  probe fails has nowhere left to go. Remedy is starting its server, or
  `--launcher ghostty` when you actually want a bare window.
- **`--launcher herdr` / `cmux` / `ghostty`** — force that backend, but it's *still*
  probed; if the probe fails it falls back to auto-detection rather than hard-erroring.
  But the flag itself counts as announcing a backend, so if that fallback also lands on
  `none`, the run exits **4 or 5 rather than 0** — naming a backend and launching
  nothing is a failure however you named it. A forced backend whose probe *passes*
  launches and exits 0 as usual. This is the one place `ghostty` enters the loud path:
  being *in* a Ghostty window announces nothing (its env vars are set for every
  window), but typing `--launcher ghostty` is a deliberate request.

Where the backends differ, in the parts worth knowing:

- **Readiness.** On herdr it's a real blocking primitive (`agent wait --status idle`);
  on cmux it's a screen-scrape poll for the prompt glyph; on ghostty it's just the
  terminal's pid, because the AppleScript dictionary has no way to read a surface's
  contents.
- **Claude's startup prompts on a fresh worktree** — most notably "N new MCP servers
  found in this project". herdr and cmux read the screen and answer them, so the new
  session gets its MCP servers. **Ghostty can't**: with no screen-read verb it can't
  see a prompt, let alone answer one, so the session sits there until someone does —
  and may end up running without its MCP servers. The brief is unaffected either way
  (it rides the launch command).
- **Ghostty needs macOS Automation permission.** First use raises a system dialog;
  a denial has to be granted in System Settings → Privacy & Security → Automation
  before a launch works. The script names the remedy and stops retrying.
- **Ghostty's `tab` target lands in the front window**, not in some remembered one,
  and its `workspace` target is a new ghostty window.

Everything else (worktree, handoff, doc carry-over, the brief riding the launch, the
honest summary) is identical across backends.

## Exit codes and where the launcher binaries come from

**Read the exit code, not just the summary text.** A background agent relays this
script's outcome to Shawn, and a non-zero exit it doesn't recognise reaches him as an
unactionable "something went wrong" — which is the whole problem the resolver below
exists to remove. Every non-zero code here has a named cause and a named fix.

| Exit | Meaning | What to do |
| --- | --- | --- |
| `0` | Worktree, branch and handoff made, and either a briefed session launched or **nothing announced a multiplexer**. | Relay normally. `launcher: none` at exit 0 means nothing announced a backend — a legitimate worktree-only spinoff. Give Shawn the manual `cd … && claude` line. A `launcher: none` that came from a backend that *did* announce itself never reaches exit 0; it is 4 or 5. |
| `1` | `die` — a precondition failed (no repo resolves, `git worktree add` refused, a bad `--label`). The message names it. | Surface the message verbatim; fix the input and re-run. |
| `2` | Unknown argument. | A skill bug. Fix the invocation. |
| `3` | A session **launched but was not briefed** — the launch itself failed partway. | Worktree survives. Relay the recovery line the script prints and brief the tab by hand. |
| `4` | The environment **announced a backend** (`HERDR_ENV=1` or `CMUX_WORKSPACE_ID`) whose **binary could not be resolved** — nothing launched. | Worktree survives. The `⚠` names the binary, every path searched, and the override. Set `HERDR_BIN` / `CMUX_BIN`, then re-run **with a new `--name`** — the worktree and branch already exist, so re-running the same name dies at exit 1. |
| `5` | The environment **announced a backend whose binary was fine**, but the backend **wouldn't take the launch** (herdr's server isn't running) — nothing launched. | Worktree survives. Start the backend's server (`herdr status server` shows it), then re-run **with a new `--name`** — the worktree and branch already exist, so re-running the same name dies at exit 1. Or use the manual line the script prints. Don't reach for `HERDR_BIN` here: the binary was never the problem. |

Codes 3, 4 and 5 are mutually exclusive by construction. 3 means a backend resolved
and the launch broke, so a launcher was in play. 4 and 5 both mean no launch happened
at all, and they split on whether the binary resolved: 4 is a resolution failure, 5 is
a live backend refusing. If you see 4 or 5, nothing was launched and the fix is named
in the `⚠` — relay it verbatim rather than paraphrasing it as "something went wrong".

Every launcher binary is resolved to an **absolute path** first — `$*_BIN` override,
then `PATH`, then `$SPINOFF_BIN_PATHS`, then the tool's own install location. This
matters because the script runs from a **background agent**, whose shell does not
inherit the login shell's `PATH`: `herdr` was installed and live, `command -v herdr`
still came back empty, and the run silently skipped the launch at exit 0.

**The main session resolves the binary and passes it down (Step 4).** You have a working
`PATH`; the background agent does not. So the override is not a break-glass knob — it is
the normal path, and the fallbacks below are the safety net for when it is absent. This
is the difference between knowing where `herdr` is and guessing: the candidate list only
covers Homebrew-shaped installs, while resolving here also covers cargo, nix, `~/bin`,
and a dev build, because it asks the shell that actually has them.

| Variable | Effect |
| --- | --- |
| `HERDR_BIN` | Absolute path to `herdr`. Wins outright; if it's set and isn't an executable file, resolution fails there rather than quietly running a different binary. |
| `CMUX_BIN` | Same, for `cmux` (otherwise found on `PATH` or in `/Applications/cmux.app/Contents/Resources/bin/cmux`). |
| `OSASCRIPT_BIN` | Same, for the ghostty backend's `osascript` (default `/usr/bin/osascript`). |
| `SPINOFF_BIN_PATHS` | Colon-separated install directories searched after `PATH`. Default `/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin`. |

An unresolvable `osascript` is **never** an exit-4 failure: Ghostty's environment
variables are passive terminal identity, not a request to launch, and `osascript`
doesn't exist off macOS at all.

## The context model: synthesis here, mechanics in the background

Only **handoff synthesis** needs this conversation, so it stays in the main
session. Everything mechanical — running the script, watching ~40 lines of step
output, waiting until the new Claude has drawn its prompt (a herdr blocking wait, a
cmux screen-scrape poll, or a ghostty pid check) — is noise the main
session never needs to keep. So after you
synthesize the handoff and get the branch base, you **dispatch a background agent
to run the script** and report back a short summary. The verbose output lives in
the background agent's context; the main session stays light.

## The workflow at a glance

1. **Synthesize the handoff** (you do this in the main session — it's the part
   only you can do well).
2. **Confirm the branch base** with Shawn (one quick question — must happen here,
   in the main session, because the background agent can't prompt him).
3. **Resolve this session's transcript + cwd** so the resume link is correct.
4. **Dispatch a background agent** to run `spinoff.sh` with the resolved args.
5. **Relay** the agent's summary (branch, worktree, tab/split/workspace, link).

## Step 1 — Synthesize the handoff (do this first, before any commands)

The new Claude wakes up blind. Your job is to brief it like you'd brief a
teammate taking over: what we're doing, why, what's decided, what's still open,
and where to look. Write this to a temp file you'll pass to the script.

Draft a markdown handoff with these sections (skip any that genuinely don't
apply — don't pad):

```markdown
# Spinoff: <short title of this workstream>

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal
<1–3 sentences: what this batch of work is meant to achieve.>

## Why now / context
<What in the current conversation prompted spinning this off. The motivating
problem, not just the task.>

## Key decisions already made
<Bulleted. Each decision + the one-line reason. This is the highest-value
section — it's what's most expensive to rediscover.>

## Open questions / not yet decided
<What the new session will need to resolve. Be honest about unknowns.>

## Starting point
<Where to look first: files, tickets, the carried-over docs. Concrete paths.>

## Recommended next step
<Your read on where this work should enter the compound-engineering flow:
`/ce-brainstorm` if scope/approach is still ambiguous, `/ce-plan` if it's clear
enough to plan, or a more specific CE command if one fits — with a one-line
reason grounded in the goal + open questions above. The new session validates
this against what it reads rather than taking it on faith; it's a strong starting
suggestion, not a directive.>

## Source session
<The script fills this in — leave a placeholder line `<!-- SESSION -->`.>
```

Write it to `/tmp/spinoff-handoff.md`. Keep it tight and real — a handoff
that reads like genuine working notes beats a padded template every time.

Write it as **directional intent**, not a spec: convey enough information,
direction, and author intent for the new session to *start*, with the code and
tests as the source of truth — not a definitive blueprint to execute literally.
That's why the template opens with the directional banner above. If you omit the
banner, `spinoff.sh` injects it when it finalizes the handoff (idempotently — it
won't double up), so the stance is carried even for a workspace viewer or a human
reader who never sees the launch brief. Don't over-rotate into "treat this as
unreliable": the decisions and facts are still worth trusting — the stance is
orient-and-validate.

## How decisions get made in this skill (engaged agent, escalate on low confidence)

You resolve the spinoff's three knobs — **which repo**, **which base**, **which
workspace** — from a rubric, acting autonomously when you're confident and only
asking Shawn (`AskUserQuestion`) when you genuinely can't tell. The script keeps
deterministic backstops (a helpful failure when no repo resolves, a stale-base
warning), but those are the safety net, not the decision-maker. **All resolution
and any question must happen here, in the main session** — the background agent
that runs the script can't prompt, so a decision deferred to it is a decision lost.

## Step 2 — Resolve the repo and the base

**Repo** — the script roots the worktree in a git repo. The originating `/start`
session's cwd is often *not* inside the target repo (e.g. you're in `~`), so
resolve the intended repo and pass it as `--repo <path>`:
- *Repo rubric:* derive it from the work under discussion / the carried-over
  plan-brainstorm docs / `--session-cwd` when that cwd is itself a git repo. If
  one repo is clearly the subject, pass `--repo` for it. If it's genuinely
  ambiguous, ask (`AskUserQuestion`). When the originating cwd already *is* the
  target repo, `--repo` is optional (the script falls back to cwd).

**Base** — **default to a fresh `origin` base**, not local HEAD. A stale local
`main` silently reproduces old state (this is a real failure mode), so prefer
`--base origin/<default-branch>` (the script fetches it fresh):
- *Base rubric:* resolve the default branch with
  `git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@'`
  (fall back to `main`), and pass `--base origin/<that>`. Deviate only with a clear
  reason — e.g. Shawn explicitly wants the in-progress local HEAD carried in, in
  which case omit `--base` (the script defaults to current HEAD). If unsure which
  base is intended, ask.

One light confirmation is fine; don't belabor it. The script's stale-base warning
backstops a local base that turns out to be behind its remote.

## Step 3 — Resolve this session's transcript + cwd

The handoff's "resume where you left off" link must point at **this** session.
The script can auto-discover it, but auto-discovery from inside a background
agent can resolve to the *agent's own* transcript and silently break the link —
so resolve it here in the main session and pass it explicitly.

```bash
# Newest transcript for this session's project dir (project key = cwd, / -> -):
SESSION_CWD="$(pwd)"
PROJ_KEY="$(echo "$SESSION_CWD" | sed 's#/#-#g')"
TRANSCRIPT="$(ls -t "$HOME/.claude/projects/$PROJ_KEY"/*.jsonl 2>/dev/null | head -1)"
```

Prefer `CLAUDE_TRANSCRIPT_PATH` / `CLAUDE_SESSION_ID` when they're set. You'll
pass `--session-transcript "$TRANSCRIPT"` and `--session-cwd "$SESSION_CWD"` to
the script. If you can't resolve a transcript *and you're not passing `--repo`*,
omitting the flags is acceptable — the script falls back to its own discovery;
just note the link may be approximate.

**When you pass `--repo`, these flags are load-bearing — always pass them
(absolute).** Under `--repo` the script's own discovery looks inside the *target*
repo, but the originating session lives outside it, so the fallback would point
the resume link at the wrong project. Resolve the transcript + cwd here and pass
them explicitly whenever `--repo` is set.

## Step 3.5 — Confirm the target workspace (when it differs)

A `--target tab` or `--target split` spinoff opens in the **current** workspace or
window (herdr, cmux or ghostty). Usually that's right — but if the workspace you're in is anchored on a *different*
repo than the one you're forking (`--repo`), the new tab would land somewhere
surprising. Catch that here, before dispatch (the background agent can't ask):

- Determine the current workspace's anchor repo and compare it to the resolved
  `--repo`. **Same repo → proceed silently.** **Different repo, or you can't
  determine it → confirm with Shawn (`AskUserQuestion`)** before launching — this
  is the low-confidence case, so don't proceed silently.
- *How to read the current workspace's repo (execution-time detail):* the current
  workspace is `CMUX_WORKSPACE_ID` (cmux) or `HERDR_WORKSPACE_ID` (herdr); read its
  primary terminal pane's cwd and run `git -C <cwd> rev-parse --show-toplevel`. On
  ghostty there is no workspace to query — use this session's own cwd. If the
  backend doesn't expose the cwd cleanly, treat the repo as *undetectable* →
  confirm (the fail-safe above). Don't block the common same-workspace path on a
  perfect query.
- This is moot for `--target workspace` (a brand-new workspace is the intent).

## Step 4 — Dispatch a background agent to run the script

Pick `--name` from the workstream's topic (kebab-case, e.g. `crop-snapping`,
`ai-audio-defaults`). It becomes both the worktree dir name and the branch
suffix. Pick `--target` from the command: `tab` for `/start-session` (or
`/start`), `split` for `/start-split`, `workspace` for `/start-workspace`.

Also pass `--label` — the **short display name** for the new tab/split/workspace.
It should capture both the **workspace** (where this forked from) and the **work**,
at a glance, e.g. `slate·crop-snap` or `auto·recipes`. Keep it short (~24 chars):
a short workspace token (usually the repo, abbreviated if long) + a `·`/`/`/`:`
separator + a tight form of the work. If you omit `--label`, the script defaults
to `<repo-basename>/<name>`, which is correct but often longer than ideal — prefer
passing a curated short one.

**For `--target split`, you MUST also pass `--from-surface <id>` — resolved here, in
the main session.** The script splits off *that* surface, and it can't read it from
the environment: the background agent running the script no longer holds the
originating pane's env, so without `--from-surface` the script warns and opens a tab
instead of a split. Resolve it before dispatch, per backend:

| Backend | What to pass | How to get it |
| --- | --- | --- |
| herdr | the pane id | `$HERDR_PANE_ID` from this session's env |
| cmux | the surface ref | `$CMUX_SURFACE_ID` from this session's env |
| ghostty | a terminal UUID **or its tty** | `$(tty)` — run it in this session |

On ghostty, do **not** pass `$GHOSTTY_SURFACE_ID`. It's a hex pointer that matches
neither a terminal's id nor its tty, so the split fails to find a surface and falls
back to a tab. Pass `$(tty)` (e.g. `/dev/ttys004`).

Pass `--split-direction left` only when the user asked for the left side; the default
is right.

**Resolve the launcher binary here too, in the main session, and pass it as
`HERDR_BIN` / `CMUX_BIN`.** Same reason as `--from-surface`: this session has a working
`PATH` and the background agent does not, so the one place that can answer "where is
`herdr`?" is *here*. Run the lookup for whichever backend the environment announced:

| Announced by | Resolve | Pass |
| --- | --- | --- |
| `HERDR_ENV=1` | `command -v herdr` | `HERDR_BIN=<that absolute path>` |
| `CMUX_WORKSPACE_ID` | `command -v cmux` | `CMUX_BIN=<that absolute path>` |

Rules that keep this honest:

- **Omit the variable when the lookup finds nothing.** Do not pass a guess, a
  directory, or a path you did not just verify. An absent variable falls through to the
  script's own resolution; a *wrong* one is worse than none, because the script honors a
  set override outright rather than second-guessing it (that is what makes the override
  trustworthy).
- **Resolving both when both are present is fine** — the script uses whichever backend
  `--launcher` selects.
- **This does not replace the script's resolution.** The script still resolves
  independently, so a run dispatched some other way, or one where this lookup came back
  empty, still works. Passing it down just means the common case stops depending on
  whatever `PATH` the agent happened to inherit.
- **Exit 4 becomes a real signal.** With the binary passed down, exit 4 no longer means
  "the agent had a thin `PATH`" — it means the binary genuinely is not installed, or the
  path you passed is not an executable file. Relay it as such.

**You MUST run the script through a background `Agent` (`run_in_background: true`) —
never inline in this session.** This is not optional and not a "trivial bash
command" exception: `spinoff.sh` prints ~40 lines of step output and polls the
terminal while it waits for the new Claude's prompt, and that noise is exactly what
this skill exists to keep OUT of the main session (synthesis here, mechanics in the
background — see "The context model" above). Running it inline defeats the whole
design. So: after Steps 1–3.5 are resolved here, hand the finished args to a
background agent and let it run the command; do not execute `spinoff.sh` yourself.

**NEVER hand-roll the launch with `herdr`/`cmux`/`osascript` commands.** Do not run
`herdr tab create`, `herdr agent start`, `herdr pane run`, `herdr workspace create`,
`cmux new-surface`, `cmux send`, an `osascript` against Ghostty, or any other
terminal command yourself — not to "place the tab", not to launch Claude, not to
deliver the brief. `spinoff.sh`
owns ALL of that and does it deterministically: it resolves the session's live
workspace, creates one correctly-placed named surface, and launches Claude with the
brief already attached. Hand-walking those steps is exactly what produces the wrong
workspace and split-pane bugs — the script exists so the sequence is deterministic,
not improvised. Your only mechanical job is to invoke the script (via the bg agent);
if the script does the wrong thing, FIX THE SCRIPT, don't work around it by hand.

Dispatch that **background agent** (`Agent` with `run_in_background: true`) whose
entire job is to run the one command below and report back. The agent must NOT
re-synthesize anything or do extra work — it runs the script, waits, and returns
the summary fields.

```bash
# Env prefix, not flags: these are the same overrides documented in "Binary resolution"
# above. Include a line ONLY for a path you resolved in this session and verified is
# non-empty — omit the line entirely otherwise.
HERDR_BIN="<absolute path from `command -v herdr` here>" \
CMUX_BIN="<absolute path from `command -v cmux` here>" \
bash "${CLAUDE_PLUGIN_ROOT}/skills/spinoff/scripts/spinoff.sh" \
  --name "<kebab-feature-name>" \
  --label "<short workspace·work label>" \
  --handoff /tmp/spinoff-handoff.md \
  --target <tab|workspace|split> \
  --session-transcript "<resolved transcript path>" \
  --session-cwd "<resolved cwd>" \
  --repo "<resolved target repo path>" \      # when the originating cwd isn't inside it
  --base "origin/<default-branch>" \           # fresh base (Step 2); omit only to carry local HEAD
  [--from-surface "<originating pane/surface id>"] \  # REQUIRED for --target split (see above)
  [--split-direction right|left] \                   # --target split only; default right
  [--branch-prefix feature] \    # default: feature/
  [--launcher auto]              # default: auto (herdr-live > cmux > ghostty > none);
                                 # force with herdr|cmux|ghostty
```

`--launcher` almost never needs setting — `auto` picks the right backend (see
*Three backends* above). Force one only for a reason, e.g. to reproduce a cmux launch
while herdr is also live, or `ghostty` to open a plain ghostty window from inside a
multiplexer (auto-detection suppresses ghostty there on purpose).

Tell the background agent to return: the branch, the worktree path, the launcher
backend + tab/split/workspace + agent pane ref, and the source-session resume line —
i.e. the contents of the script's summary block **and its exit code**, plus any `⚠`
lines. Ask for the block by position, not by its header: a failed run's header reads
`⚠ Spinoff INCOMPLETE`, so an agent told to return "the `✓ Spinoff complete` block"
has nothing to return on exactly the runs that matter most.

The script is safe to read top-to-bottom; it prints each step. What it does, in
order:
1. Resolves the repo root and the worktree path (`<repo>/worktrees/<name>` —
   this repo's nested convention).
2. Creates the worktree on a new branch (`<prefix>/<name>`) from the chosen base.
3. Runs an optional per-repo bootstrap if `SPINOFF_BOOTSTRAP_CMD` is set
   (e.g. `pnpm build-config:stage`). Non-fatal; skipped if unset.
4. Writes the handoff to `<worktree>/docs/handoff.md`, substituting the resolved
   session transcript + `claude -r <uuid>` resume one-liner into `<!-- SESSION -->`.
5. Copies recent `docs/` plan/brainstorm/notes files (modified in the last ~6h)
   into the new worktree's `docs/`.
6. Writes the brief to a per-run file in the worktree (`.spinoff-brief`) and
   **launches a briefed Claude** via the auto-detected backend (herdr, cmux or
   ghostty — see *Three backends*), per `--target`. The brief is `claude`'s
   positional prompt at launch, read from that file — so a successful launch *is* a
   successful briefing, and there's no separate step that types it in afterwards.
   The brief says: read `docs/handoff.md`, treat it as directional (author intent and
   a starting point, with the code/tests as the source of truth, not a spec to
   execute literally), get oriented, then recommend the next compound-engineering
   step — `/ce-brainstorm` vs `/ce-plan` vs a more specific CE command — and wait for
   direction. The new surface is named with `--label`, not the bare `--name`.
   - `tab` — a new agent tab/surface in the current workspace, in the worktree.
     (cmux adds a surface to the left agent pane; herdr starts the agent directly in
     the worktree; ghostty opens a tab in its front window.)
   - `split` — a new pane beside `--from-surface`, in the current tab, on the side
     `--split-direction` names. cmux and ghostty split left natively; herdr splits
     right and then swaps for a left split. The new pane is created unfocused, so
     you stay where you are until the launch succeeds. With no `--from-surface`, the
     script warns and opens a `tab` instead.
   - `workspace` — a new workspace (a new window on ghostty) rooted at the worktree,
     briefed `claude` on the left, then a right pane rendering `docs/handoff.md`
     alongside (cmux uses its live-reload markdown viewer; herdr and ghostty have no
     native viewer, so they render it statically with a pager — best-effort either way).
7. Waits until the new Claude has drawn — a **herdr** blocking wait
   (`agent wait --status idle`), the **cmux** screen-scrape poll, or the **ghostty**
   pid check. This is no longer a briefing gate (the brief already went with the
   launch); what it buys is answering the startup prompts a fresh worktree path
   raises, chiefly the MCP-servers one. On ghostty there's no way to read the screen,
   so those prompts are left for you and the session may start without its MCP
   servers. A session that never draws is reported as a warning, not a failure.

## Step 5 — Relay

Once the background agent reports back, tell Shawn concisely: branch name,
worktree path, whether a tab, a split, or a new workspace was opened, that a briefed Claude
is running there, and that the handoff links back to this session. He then
continues in the new surface.

## When the script can't do something

- **Nothing announced a backend** (detection resolves to `none` because no
  `HERDR_ENV=1`, no `CMUX_WORKSPACE_ID`, and not a plain Ghostty session): the script
  still creates the worktree + handoff and prints the manual `cd <worktree> && claude`
  command, so the spinoff isn't lost — only the surface automation is skipped.
  **Exit 0.** Tell Shawn. This is the only `launcher: none` that is a success.
- **A backend announced itself but wouldn't take the launch** (`HERDR_ENV=1` and the
  binary resolves, but the herdr server isn't running): **exit 5**, not a skip. This
  used to be lumped in with the case above and exit 0, which made a dead server
  indistinguishable from a plain terminal. The `⚠` names the backend, the announcing
  variable, and the remedy — start the server, not fix a path. Note `HERDR_ENV=0` is
  *not* this case: an announcement that is switched off announces nothing, so it stays
  a silent exit 0. Ghostty is deliberately not used as the recovery for either.
- **An announced backend whose binary can't be found** (`HERDR_ENV=1` or
  `CMUX_WORKSPACE_ID` set, but `herdr`/`cmux` doesn't resolve): a different outcome
  from the one above, and deliberately not silent. The summary block says
  `⚠ Spinoff INCOMPLETE`, the `⚠` names the binary, the paths searched and the
  override that fixes it, and the run **exits 4**. Worktree, branch and handoff are
  intact. Because Step 4 already passes the binary down from this session, this now
  means the binary genuinely isn't installed — or the path passed wasn't an executable
  file — not that the agent inherited a thin `PATH`. Check your own `command -v herdr`
  before relaying `HERDR_BIN` as the fix, and don't report "done".
- **macOS blocked Ghostty automation** (Apple event error -1743): the script names
  the fix — System Settings → Privacy & Security → Automation, allow this app to
  control Ghostty — and stops retrying, because macOS remembers a denial. The
  worktree + handoff still exist. Relay the fix.
- **`--target split` with no `--from-surface`**: the script warns and opens a tab
  instead. That's a skill bug, not a user problem — resolve the surface in the main
  session (Step 4) and pass it.
- **`--from-surface` matches no live surface**: the script says which handle failed,
  shows what a working one looks like, and opens a tab. On ghostty this is almost
  always `GHOSTTY_SURFACE_ID` passed where a tty was needed.
- **No repo resolves**: if neither `--repo` nor the cwd lands in a git repo, the
  script fails with a message naming `--repo` — resolve the target repo (Step 2)
  and pass it, don't paper over it.
- **Dirty index blocks worktree add**: the script reports the git error verbatim.
  Surface it.
- **Ambiguous left pane** (tab target, e.g. a single-pane workspace): the script
  falls back to adding the surface to the focused pane and notes it. Usually fine.
- **Can't parse the new workspace/surface ref** (workspace target): the script
  prints the raw backend output and degrades gracefully — the worktree
  + handoff still exist. Surface the warning and the manual launch command.
- **Right-pane handoff viewer fails** (workspace target): the briefed Claude is
  still launched on the left; only the markdown viewer is missing. Non-fatal.

## Notes on conventions (why the script does what it does)

- Worktree path `<repo>/worktrees/<name>` matches how this repo already nests
  worktrees; don't relocate to `~/projects/<repo>/worktrees` for repos that nest.
- Branch prefixes follow Shawn's convention: `feature/` (default), `task/`,
  `bugfix/`, `hotfix/`. Pass `--branch-prefix` to override.
- The session link is a **local transcript path + resume one-liner**, never an
  upload — recoverable offline, and the resume command is given as an absolute
  `cd … && claude -r <uuid>`.
- Don't `git add -A` anywhere; the script never stages broadly.
