---
title: Tab Naming Convention - Plan
type: feat
date: 2026-08-16
deepened: 2026-08-16
topic: tab-naming-convention
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Tab Naming Convention - Plan

## Goal Capsule

**Objective.** Give every surface a spinoff opens — tab, split, workspace, and the Claude
session — one name shape, `Ticket: Title`, on all three launcher backends. Name the splits
that carry no name today, and make a missing ticket visible.

**Product authority.** Shawn owns the convention shape, the ticket policy, the degrade rule,
and the plugin scope. The Product Contract below is settled; planning does not reopen it.

**Stop conditions.** Stop and ask if naming a surface would require changing the `auto`
plugin, if a backend needs a new dependency, or if the ghostty title cannot be made to hold
after the session starts.

**Execution profile.** One plugin, one script, one skill doc, one test file. Verify against
the installed launcher CLIs, not against their documentation.

**Tail ownership.** Standard: branch, PR, review. Both version strings must be bumped or the
change ships to nobody.

**Product Contract preservation.** Restructured, no scope change. R7 split into R7 (apply the
label) and R12 (report what went unnamed) — the original R7 kept the apply intent, and the
reporting clause it also carried became its own requirement so a unit can cite it. R8 was
rewritten because research refuted half its premise: every backend can name every surface at the
verified versions, so the no-support branch is dormant — but the rejected-call branch it gained is
live everywhere. `Governs` links re-pointed accordingly.

---

## Product Contract

### Summary

Spinoff derives one label, `Ticket: Title`, and applies it to every surface it opens on
every backend. A ticket is preferred but never blocking: with no ticket the label is the bare
title, and that absence marks the work as untracked. Splits get named for the first time on
herdr and ghostty.

### Problem Frame

Splits carry no name on herdr or ghostty. A split opened beside its parent shows nothing
about what it holds, so the only way to identify it is to read its working directory.

Nothing on screen says whether work is tracked. A live census of this machine found 248
sessions across three naming shapes — `repo·work` (`slate·logo-ux`), `repo/work`
(`agents/dw-hook`), and auto-generated fallbacks (`shawnroos-55`, `shawnroos-9b`) — plus one
full sentence used as a name. None carries a ticket. Two pairs collide outright:
`slate·audio-tools` and `shrimp·spinoff-herdr` each name two different live sessions.
Scanning that list cannot answer "which of these is on the board?" or "which of these two is
the one I want?"

The naming plumbing is not the gap. `$LABEL` already reaches every backend call. What is
missing is a rule for deriving it, naming calls on the surfaces that go unnamed, and skill
guidance that teaches the new shape.

### Key Decisions

- **The convention is `Ticket: Title`.** (session-settled: user-directed — chosen over the
  incumbent `repo·work` shape: a ticket-bearing name links the surface to the board, and its
  absence is itself informative.) Governs R1, R2.

- **A ticket is preferred, never blocking.** (session-settled: user-directed — chosen over
  requiring a ticket: most spinoff work is personal-repo work with no ticket, so a hard
  requirement would be worked around rather than followed.) Governs R3, R4.

- **A backend that cannot name a surface does not name it.** (session-settled: user-directed
  — chosen over emulating names or degrading to a different shape: partial support reported
  honestly beats a fake name.) Governs R8, R12.

- **Scope is the spinoff plugin only.** (session-settled: user-directed — chosen over also
  converting the `auto` plugin, which builds its own workspace names on a separate path.)
  Governs R9.

### Requirements

**The name shape**

- R1. A surface name is `Ticket: Title` when a ticket is known — the ticket identifier, a
  colon, a space, then a short human title.
- R2. A surface name is the bare `Title` when no ticket is known. No placeholder, repo token,
  or other filler occupies the ticket slot, so a missing ticket shows as a missing prefix.

**Resolving the ticket**

- R3. The calling model resolves the ticket before dispatch and passes one finished label.
  The script performs no ticket lookup.
- R4. A ticket lookup that fails, errors, or is slow never blocks the spinoff. The run
  proceeds under R2.
- R5. When no ticket exists for work that warrants one, the model may create a Linear ticket
  and use it, subject to R6.
- R6. The model confirms with Shawn before it creates a ticket.

**Applying the name**

- R7. Every surface the spinoff opens carries the label: tab, split, workspace or window, and
  the Claude session.
- R14. The handoff viewer pane carries the fixed name `Handoff`, not the work label, so it is
  distinguishable at a glance from the session pane beside it.
- R8. A surface a backend cannot name — because the backend has no naming support, or because
  the naming call is rejected — is left unnamed. No substitute name is invented for it.
- R12. The run summary names any surface that went unnamed. The summary never reports a name
  the run did not set.
- R13. When the naming step finds that the briefed session no longer exists, the run reports
  the session as not briefed rather than as complete.
- R9. Only the spinoff plugin changes. The `auto` plugin keeps its own workspace naming.

**Keeping guidance and code together**

- R10. `plugins/spinoff/skills/spinoff/SKILL.md` teaches the `Ticket: Title` shape, replacing
  the `workspace·work` guidance at lines 305-322.
- R11. `plugins/spinoff/skills/spinoff/scripts/smoke.sh` covers the new derivation and the new
  naming calls, extending the existing cases.

### Key Flows

- F1. **Spinoff with a ticket.** **Trigger:** Shawn runs `/start-session` on work with a known
  ticket. The model composes `WEB-2757: Remove Logo` and passes it as `--label`. The script
  applies it to every surface it opens. **Covers R1, R3, R7.**

- F2. **Spinoff with no ticket.** **Trigger:** Shawn runs `/start-session` on personal-repo
  work. The model finds no ticket, and either Linear returns nothing or Shawn declines
  creation. The label is the bare title and the run proceeds at normal speed.
  **Covers R2, R4, R6.**

- F3. **A naming call fails.** **Trigger:** a backend rejects the rename. The script warns,
  continues, and lists the surface as unnamed in its summary. The worktree and the briefed
  session survive. **Covers R8, R12.**

### Acceptance Examples

- AE1. Ticket known. **Covers R1, R7.** Label is `WEB-2757: Remove Logo`. Tab, split,
  workspace, and session all read `WEB-2757: Remove Logo`.
- AE2. No ticket. **Covers R2.** Label is `Tab naming convention`. No `Ticket:` prefix and no
  repo token appears.
- AE3. Linear unreachable. **Covers R4.** The spinoff completes at normal speed and produces
  the AE2 result. Nothing is reported as a failure.
- AE4. Ticket creation declined. **Covers R6.** No ticket is created. The run produces the AE2
  result.
- AE5. Rename rejected by the backend. **Covers R8, R12.** The run warns, completes, and lists
  that surface as unnamed. `KICKOFF_OK` is unaffected.
- AE6. Label carries a colon and spaces. **Covers R1.** `herdr pane rename` stores
  `WEB-2757: Remove Logo` verbatim as one argument. It is not split into two positionals.

### Success Criteria

- Scanning a row of open surfaces answers "which work is this?" and "is it ticketed?" without
  reading any working directory.
- A failed rename never costs a worktree or a briefed session.

### Scope Boundaries

- The `auto` plugin keeps its own workspace naming (`auto-fanout-{slug}`, `auto-resume-{run}`).
  Its slug function strips colons and spaces, so adopting this shape there is separate work.
- Surfaces opened outside a spinoff are not renamed.
- No truncation rule. Nothing in the repo truncates a label today and the backends store long
  labels intact. Chrome elision is the chrome's behavior.
- No migration of surfaces already open.

#### Deferred to Follow-Up Work

- Removing the leading-dash guard at `spinoff.sh:1242`. It now guards `herdr pane rename`,
  whose label is a bare positional, so it stays until that call is proven safe without it.

### Sources / Research

- `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` — `launcher_*` dispatchers (309-315);
  cmux names at `launcher_launch_agent_cmux` (422); herdr `tab create --label` (603),
  `workspace create --label` (640); ghostty launch with no titling (1062-1129); ghostty
  AppleScript helpers `_ghostty_stage` (890-981), `_ghostty_run` (998-1027); focus-restore
  second-event precedent (1093-1098); leading-dash guard (1242); default label (1348);
  `claude --name` (1593, 1596).
- `plugins/spinoff/skills/spinoff/SKILL.md:305-322` — the guidance that produced the
  incumbent titles.
- `plugins/spinoff/skills/spinoff/scripts/smoke.sh:18-19` (kill-switch), `:23-32` (helpers),
  `:63-75` (label cases), `:207-218` (static-assertion precedent).
- `plugins/spinoff/skills/spinoff/scripts/cli-drift.test.sh:41` — extracts `"$HERDR" <word>
  <word>` calls and checks long flags against the installed CLI.
- `/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef` — `name` is `access="r"` on
  window, tab and terminal; `perform action` is the only title route.
- `docs/solutions/workflow-issues/test-count-subtraction-reconciliation-is-weaker-than-passing-parity.md`
  — a proxy check is not proof; read the value back.
- `docs/solutions/logic-errors/exporting-an-empty-credential-is-worse-than-exporting-none.md`
  — never set an empty value; test the absent case.
- `docs/solutions/best-practices/pgrep-pkill-by-shared-script-name-is-unsound-across-worktrees.md`
  — a name is a shared string; address surfaces by id, never by name.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The script stays a dumb carrier; no `--ticket` flag.** The model composes the whole
  label and passes `--label`. (session-settled: user-directed — chosen over adding `--ticket`
  parsing to the script: `spinoff.sh` is bash with no Linear access, and `BRANCH="$PREFIX/$NAME"`
  means the branch is created from `--name`, so branch-name ticket parsing is circular.)
  Instantiates the ticket-policy Key Decision; governed R-IDs R3, R4.

- KTD2. **Name a surface before launching into it where the surface pre-exists; after, where
  creation is the launch.** On cmux and herdr the surface exists before the session starts, so
  naming precedes the launch and never races the shell's own title writes. On ghostty no
  surface exists until the launch, so naming necessarily follows it and does race — survivable
  only because KTD3's route pins the title. Both calls still live in
  `launcher_launch_agent_<backend>`, the seam cmux already uses (`spinoff.sh:422`); a separate
  `launcher_name_surface` verb would need a fourth ghostty arm for the same effect. Note the
  ghostty function is entered holding the `ghostty:pending` sentinel (`:1055`) — the real
  terminal id arrives at `:1099`.

- KTD3. **Ghostty names surfaces through `perform action`, not property assignment.**
  `set_tab_title:` names the tab, `set_surface_title:` names a split, and both target a
  `terminal`. The `name` property is read-only. This route also pins the title against the
  shell's own OSC writes, so the running session does not overwrite it. The action string
  carries two colons under R1 (`set_tab_title:WEB-2757: Remove Logo`); verified live on
  Ghostty 1.3.2 that the parser splits on the first colon and the title survives whole.

- KTD4. **Set, read back the object that actually changed, then retry on a delay.**
  `perform action` returns `true` when it did nothing: measured on a terminal created ~1s
  earlier, where the title stayed `~`; the same call 2s later worked. Return values are not
  evidence. **Read-back object by scope, measured on Ghostty 1.3.2:** a tab-scope set changes
  the tab's and the window's `name` and leaves the terminal's at `~`, so tab scope reads the
  tab's `name` and split scope reads the terminal's. Reading the wrong one never matches, and
  would report a correctly-named tab as unnamed — inverting R12. Because the failure is
  timing, the retry waits before re-attempting rather than firing immediately; use the file's
  bounded-poll idiom (`spinoff.sh:614-618`), not a bare second call.

- KTD5. **A rejected rename warns and continues; a target-not-found does not.** A rename the
  backend rejects or ignores is cosmetic — warn, continue, never set `KICKOFF_OK=0`, following
  the pane-swap precedent at `spinoff.sh:697-700` rather than the silenced cmux rename at
  `:422`. But `error=surface-not-found` on ghostty means the handle that already set
  `KICKOFF_OK=1` (`:1116`) no longer resolves: the session died between launch and rename.
  That clears `KICKOFF_OK`, so the summary header reads INCOMPLETE and the run exits 3 like every
  other unbriefed-session path, instead of printing "Spinoff complete" for a session that is
  gone. The surface does not join the unnamed list — it is a liveness result, not a naming one.
  Governs R8, R12, R13.

- KTD6. **The no-ticket default is the de-kebabed `$NAME`, dropping the repo token.**
  `shrimpshack/tab-naming-convention` becomes `Tab naming convention`. (session-settled:
  user-approved — chosen over keeping a repo prefix: R2 reserves the pre-colon slot for a real
  ticket, and the cwd and workspace still carry the repo.) Governs R2.

- KTD7. **A label is never empty, so no call has to handle an empty one.** When de-kebabing
  yields nothing, fall back to the raw `$NAME`. The alternative — letting the label go empty
  and teaching each consumer to skip or omit — was rejected because it enumerates call shapes,
  and an enumeration leaks: a ghostty `set_tab_title:` with an empty argument is well-formed
  and pins a blank title, and `cmux rename-tab` has no operation left once its title is
  omitted. Eliminating the state closes the class; listing the shapes closes only the shapes
  listed. (session-settled: user-directed — chosen over per-consumer empty guards.)

- KTD8. **`UNNAMED_SURFACES` holds one human-readable surface descriptor per line**, each
  derived from `$LAUNCH_WHERE` plus the surface id. The format is stated here because U2, U3
  and U4 all append to it and U5 reads it — three producers with no declared shape would
  invent three. Hardcoding "split" would misreport a tab or workspace run.

### High-Level Technical Design

The model owns ticket resolution; the script owns application. One label crosses the boundary.

```
  model (SKILL.md)                    │  script (spinoff.sh)
  ────────────────────────────────────┼──────────────────────────────────
  ticket known?                       │
    ├─ yes → "WEB-2757: Remove Logo"  │
    ├─ no  → Linear lookup (optional) │
    │         ├─ hit    → use it      │
    │         ├─ miss   → offer to    │
    │         │            create (R6)│
    │         └─ error  → fall through│
    └─ none → "Remove Logo"           │
                    │                 │
                    └── --label ──────┼──▶ $LABEL
                                      │      ├─▶ workspace/window   (existing)
                                      │      ├─▶ tab                (existing; NEW on ghostty)
                                      │      ├─▶ split              (NEW on herdr + ghostty)
                                      │      └─▶ claude --name      (existing)
```

Per-surface naming support, verified live on 2026-08-16 against herdr 0.8.0, cmux from
`/Applications/cmux.app`, and Ghostty 1.3.2:

| Surface | cmux | herdr | ghostty |
| --- | --- | --- | --- |
| Tab | `rename-tab --title` (exists) | `tab create --label` (exists) | `perform action set_tab_title:` (**new**) |
| Split | `rename-tab --surface` (exists) | `pane rename` (**new**) | `perform action set_surface_title:` (**new**) |
| Workspace / window | `new-workspace --name` (exists) | `workspace create --label` (exists) | mirrors selected tab |
| Claude session | `claude --name` | `claude --name` | `claude --name` |

No backend lacks naming support at the verified versions, so R8's no-support branch is dormant
and fires only on a Ghostty older than 1.3.2, which U4 probes for. R8's rejected-call branch is
live on every backend at every version — F3 and AE5 exercise it, and U2, U3 and U4 all implement
it.

### Assumptions

- The calling model has Linear access at dispatch time. R4 covers the case where it does not.
- Ghostty releases older than 1.3.2 may not expose `set_tab_title` / `set_surface_title`.
  U4 probes the installed bundle rather than assuming.

Measured on 2026-08-16 against herdr 0.8.0, cmux from `/Applications/cmux.app`, and Ghostty
1.3.2 — these are findings, not assumptions:

- `herdr pane rename` and `cmux rename-tab` both exit non-zero on error, so the standard
  `if ! err="$(…)"` idiom catches a failed rename. An in-band `"error"` check is belt-and-braces.
- A ticketed label survives the herdr and ghostty boundaries: stored verbatim by
  `herdr pane rename`, and carried through the argv crossing into AppleScript and the
  `set_tab_title:` action-string parse onto a ghostty tab. The parser splits on the first colon.
  The `claude --name` boundary is not measured — see Open Questions.
- A tab-scope title lands on the tab's and the window's `name` and leaves the terminal's at `~`.
- A leading `-` is accepted as a positional by `herdr pane rename` — no flag misparse. The guard
  at `spinoff.sh:1242` protects nothing on the new call; U2 corrects its stale comment, and
  removal stays deferred (see Scope Boundaries).

### Open Questions

**Deferred to implementation** — none of these block starting.

- Does `claude --name` accept a colon unchanged in the resume picker, or normalize it? Spaces
  are confirmed to survive (live sessions carry multi-word names). AE1 asserts the session name
  reads verbatim, so a normalizing `--name` would weaken that one acceptance example without
  affecting any other surface.

### Risks & Dependencies

- **`cli-drift.test.sh` polices the new herdr call.** It greps `"$HERDR" <word> <word>` and
  checks long flags against the installed CLI, so `"$HERDR" pane rename …` is auto-checked.
  It cannot see a bare positional, so a label that word-splits passes it. U5 covers that.
- **A call assembled in a bash array is invisible to the drift check.** Follow the
  one-literal-line rule stated at `spinoff.sh:393-394`.
- **`check-version-bumped.sh` is mandatory.** Touching `plugins/spinoff/skills/**` without
  bumping both `plugins/spinoff/.claude-plugin/plugin.json` and the root
  `.claude-plugin/marketplace.json` ships the change to nobody.
- **`smoke.sh`'s `HERDR_ENV=0` kill-switch at `:18-19` is load-bearing.** A case added above
  it launches real tabs into deleted temp worktrees.
- A name is a shared string and an unsound selector. Address surfaces by id; use the name for
  humans only.

---

## Implementation Units

### U1. Derive the no-ticket default from `$NAME`

**Goal:** The default label becomes the de-kebabed title, dropping the repo token.

**Requirements:** R2. Implements KTD6, KTD7, KTD8.

**Dependencies:** none.

**Files:**
- `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` (the default at `:1348`; the printed
  `label:` line at `:1353`; the launch globals at `:1568`)
- `plugins/spinoff/skills/spinoff/scripts/smoke.sh`

**Approach:**
1. Replace the `<repo>/<name>` default with a de-kebabed `$NAME` — hyphens to spaces, first
   letter capitalized, leading and trailing whitespace trimmed. The trim matters: a `$NAME`
   with a leading hyphen de-kebabs to a leading space.
2. Leave `$LABEL` untouched when `--label` was passed.
3. Keep emitting the `label:` line at `:1353` — it is the observable contract every label test
   asserts against — but reword it as the label the run will *request*. It prints before any
   surface is named, so as written a reader takes it as the name that was set, which
   contradicts R12 and U5's unnamed-surface line.
4. When de-kebabing `$NAME` yields an empty string, fall back to the raw `$NAME` (KTD7). The
   label is then never empty, so no consumer needs an omit-when-empty arm. `spinoff.sh:1236`
   already rejects an empty `--name`, so this only triggers on a pathological name such as
   `---`.
5. Declare the shared unnamed-surface accumulator beside the other launch globals at `:1568`
   (`UNNAMED_SURFACES=""`). U2, U3 and U4 append to it; U5 reads it. Declaring it here, in
   the only unit with no dependencies, keeps the three producers from inventing three shapes.
6. Amend the default-label case at `smoke.sh:63-68` to the new expected value, and see it fail
   against the old default before this unit's code lands.

**Patterns to follow:** the existing `[ -n "$LABEL" ] || LABEL=…` shape at `:1348`.

**Test scenarios:**
- `Covers AE2.` `--name tab-naming-convention` with no `--label` produces
  `label: Tab naming convention`, with no repo token and no `Ticket:` prefix.
- `--label 'WEB-2757: Remove Logo'` is used verbatim and the default does not fire.
- A `$NAME` that de-kebabs to an empty string falls back to the raw `$NAME`; the run never
  prints `label: ` with an empty value.
- A `$NAME` of `---` falls back to the raw value rather than producing an empty label, so no
  backend call is ever issued with an empty title.

**Verification:** `bash smoke.sh` passes, including the amended default-label case.

### U2. Name the herdr split

**Goal:** Every herdr pane a spinoff runs claude into carries the label — split, tab and
workspace targets alike — closing the only naming gap on that backend.

**Requirements:** R7, R8, R12, R14. Implements KTD2, KTD5.

**Dependencies:** U1.

**Files:**
- `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` (`launcher_launch_agent_herdr`, 715-735)
- `plugins/spinoff/skills/spinoff/scripts/spinoff.bats`
- `plugins/spinoff/skills/spinoff/scripts/smoke.sh`

**Approach:**
1. In `launcher_launch_agent_herdr`, call `herdr pane rename` on `LAUNCH_RUN_PANE` with the
   label as a single quoted positional. No `--`: an end-of-options marker is not consumed and
   becomes part of the label (measured). Place the call **before** `pane run`, per KTD2 — after
   it, the rename races the session's own title writes with no pin to survive it.
2. Write the call as one literal single-line invocation, never array-built, so
   `cli-drift.test.sh` can extract it — its grep at `:41` scans a single line for
   `"$HERDR" <word> <word>`.
4. Capture stderr and test the exit status with the standard `if ! err="$(…)"` idiom. Warn and
   continue on failure; do not set `KICKOFF_OK=0`. Also treat an in-band `"error"` payload as
   failure, matching the `_ghostty_run` precedent at `:1023`.
5. Read the stored value back from the rename response — it already carries `result.pane.label`,
   so `_herdr_json` parses it at no extra call — and compare it to `$LABEL`. A stub argv
   assertion proves quoting, not storage.
6. Append the surface to `UNNAMED_SURFACES` per KTD8 on any failure.
7. Correct the stale subject of the leading-dash guard: `spinoff.sh:1237-1241`'s comment and the
   bats test name at `spinoff.bats:245` both cite `herdr agent start "$LABEL"`, a call that no
   longer exists. This unit is what makes the guard's stated subject real.

**Also name the viewer.** `launcher_open_viewer_herdr` splits a second pane at
`spinoff.sh:825` to show the handoff doc. Name it `Handoff` per R14, through the same
`pane rename` call. Without it a workspace spinoff still leaves an unnamed split on screen.

**Note on scope:** the session-pane call runs for the tab and workspace targets too, not only
the split —
all three set `LAUNCH_RUN_PANE` (`:624`, `:663`, `:701`) and route through the same function.
That is correct, not double-naming: a pane's `label` is a distinct object from the tab's and the
workspace's, and it is unnamed on every spinoff-created pane today, so naming it is what R7 asks
for.

**Execution note:** the behavioral scenarios below belong in `spinoff.bats`, not `smoke.sh`.
`smoke.sh` exports `HERDR_ENV=0` and never reaches `launcher_launch_agent_herdr`, so it cannot
observe the argument shape or the failure path. The herdr stub needs two additions before those
scenarios can run: a `pane rename` arm that emits a `result.pane.label` payload, and a failure
toggle. Its catch-all `*)` arm (`spinoff.bats:81`) currently makes any subcommand succeed
silently, so the read-back would have nothing to read.

**Patterns to follow:** the pane-swap warn-and-continue block at `spinoff.sh:697-700`. Do not
copy the silenced `>/dev/null 2>&1` form at `:422`. For the stubs, the existing argv-capture
assertions in `spinoff.bats`.

**Test scenarios:**
- `Covers AE6.` A two-word label reaches `pane rename` as one argument, not two positionals
  (argv assertion in `spinoff.bats`).
- `Covers AE1.` The label read back from `result.pane.label` equals the label that was sent.
- `Covers AE5.` A rejected rename warns, leaves `KICKOFF_OK` unchanged, and the run still
  reports the worktree and briefed session (stub failure toggle in `spinoff.bats`).
- An empty label skips the call entirely — no bare `pane rename <id>` is issued.
- The rename is issued before `pane run`, not after.
- Static assertion in `smoke.sh`: `spinoff.sh` contains a `pane rename` call in the herdr
  launch path.

**Verification:** `bats spinoff.bats` passes, including the new argv, read-back and failure cases.
`bash cli-drift.test.sh` passes against the installed herdr. `bash smoke.sh` passes.

### U3. Silence-proof the cmux rename

**Goal:** A failed cmux rename stops being invisible.

**Requirements:** R12. Implements KTD5.

**Dependencies:** U1.

**Files:**
- `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` (`:422`)
- `plugins/spinoff/skills/spinoff/scripts/spinoff.bats`
- `plugins/spinoff/skills/spinoff/scripts/smoke.sh`

**Approach:**
1. Replace `>/dev/null 2>&1` on the `rename-tab` call with the capture-and-test idiom used
   everywhere else in the file.
2. Warn and continue on failure; do not set `KICKOFF_OK=0`.
3. Append the surface to `UNNAMED_SURFACES` (declared in U1) for the summary.

**Execution note:** `--title` is still valid on the installed cmux; this unit changes error
handling only, not the call shape. The failure-path scenario belongs in `spinoff.bats` —
`smoke.sh` never reaches `launcher_launch_agent_cmux`. The cmux stub cannot fail today: it ends
in an unconditional `exit 0` (`spinoff.bats:21-33`) with no toggle. Add one; do not assume it.

**Patterns to follow:** `spinoff.sh:697-700`.

**Test scenarios:**
- `Covers AE5.` A failed rename produces a warning and does not fail the run (stub failure
  path in `spinoff.bats`).
- Static assertion in `smoke.sh`: the `rename-tab` line no longer discards stderr.

**Verification:** `bats spinoff.bats` passes, including the new failure case. `bash smoke.sh`
passes.

### U4. Name the ghostty tab and split

**Goal:** Ghostty surfaces carry the label, through `perform action`.

**Requirements:** R7, R8, R12, R13, R14. Implements KTD2, KTD3, KTD4.

**Dependencies:** U1.

**Files:**
- `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` (`_ghostty_stage` heredoc 890-981;
  `launcher_launch_agent_ghostty` 1062-1129)
- `plugins/spinoff/skills/spinoff/scripts/smoke.sh`

**Approach:**
1. Add a `set-title` verb to the staged AppleScript heredoc as a new `else if verb is …` arm,
   taking a terminal id, a title, and a scope of tab or surface. It resolves the terminal **and
   its containing tab** — a terminal has no back-pointer to its tab, and `findTerminal`
   (`:900-912`) walks terminals only, so the tab is found by scanning windows → tabs →
   terminals for a matching id.
2. Set and read back inside **one** Apple event, returning the observed title as a single
   `name=<value>` line parsed by `_ghostty_field` (`:992`), failing in-band with `error=` per
   `_ghostty_run`'s convention (`:1022`). One event keeps the tab handle off the shell boundary
   and removes a second-event race. `_ghostty_field` takes the first match, so `name=` must be
   the only field the verb emits; a label is single-line, so the comparison is sound.
3. Use `perform action "set_tab_title:<title>"` for a tab and `"set_surface_title:<title>"` for
   a split, then read back the object that scope actually changes (KTD4).
4. Call it from `launcher_launch_agent_ghostty` after `LAUNCH_SFC` holds the real terminal id
   (`:1099`), and after the split-to-tab fallback has run — that fallback rewrites
   `LAUNCH_WHERE` mid-function (`:1085-1090`), so a fallen-back split would otherwise issue
   `set_surface_title:` against a tab.
5. Compare the returned `name=` to the requested title. A first-attempt mismatch is the
   expected path, not the exception — the call fires as soon as the terminal handle returns,
   and KTD4 measured a set failing ~1s after creation. On mismatch, re-issue the **full**
   set-and-read verb (a bare re-read against an action that no-oped never converges), 2-3
   attempts spaced ~1s. Do not reuse the 20 x 0.5s pane-list poll — ten seconds of osascript
   on every ghostty spinoff is too costly for a cosmetic name. On a persistent mismatch, warn,
   continue, and append the surface per KTD8.
6. Treat `error=surface-not-found` as a liveness result, not a naming failure (KTD5): the
   terminal that set `KICKOFF_OK=1` (`:1116`) no longer resolves. Clear `KICKOFF_OK` so the
   summary and exit code report the session as not briefed. Do not append it to
   `UNNAMED_SURFACES`. The read-back doubles as the liveness probe, so it costs no extra call.
7. Probe for `set_tab_title` through the resolved bundle — `"$GHOSTTY_APP/Contents/MacOS/ghostty"
   +list-actions` — never a bare `ghostty` on `PATH`. The script resolves only `GHOSTTY_APP`
   (an `.app` directory) and `OSASCRIPT`, and its own comment at `:1294` records that ghostty
   ships no scripting CLI; a background agent's `PATH` may not contain `/usr/bin` at all
   (`:1003`).
8. Name the ghostty handoff viewer terminal `Handoff` per R14 — `launcher_open_viewer_ghostty`
   splits it at `:1167` and it is unnamed today.
9. Distinguish the two probe failure shapes. A probe that ran and did not list `set_tab_title`
   is a backend without naming support under R8. A probe that could not execute is not —
   attempt the rename anyway and report any failure through the unnamed-surface line, so a
   probe failure never silently disables naming on a ghostty that supports it.

**Execution note:** the read-back is the point of this unit. `perform action` returning `true`
is not evidence the title landed.

**Patterns to follow:** the focus-restore second event at `spinoff.sh:1093-1098` for the call
shape; the in-band `error=` check at `:1023`; `_ghostty_field` at `:992` for parsing the
read-back; the bounded poll at `:614-618` for the retry.

**Test scenarios:**
- `Covers AE1.` A tab title set through `set_tab_title:` reads back equal to the label, read
  from the tab's `name` rather than the terminal's.
- A split title set through `set_surface_title:` reads back from the terminal's `name`.
- `Covers AE6.` A ticketed label survives both boundaries: the argv crossing into AppleScript,
  and the action-string parse where the label's own colon follows the action's.
- `Covers AE5.` A title that does not land after the bounded retry warns and leaves
  `KICKOFF_OK` unchanged.
- A `--target workspace` run names the tab scope, and a split that fell back to a tab names the
  tab scope too, not the surface scope.
- `Covers R13.` A `surface-not-found` reply clears `KICKOFF_OK`, so the run reports INCOMPLETE
  and exits 3 rather than printing "Spinoff complete"; the surface does not appear in the
  unnamed list.
- An older ghostty whose probe ran and did not list `set_tab_title` leaves the surface unnamed
  and reports it, rather than erroring.
- A probe that cannot execute at all still attempts the rename, rather than treating the
  backend as unsupported.
- Static assertion: the staged script contains a `set_tab_title` arm.

**Verification:** manual run against a real ghostty window created and closed for the test.
`bash smoke.sh` passes.

### U5. Report unnamed surfaces in the run summary

**Goal:** The summary never implies a name that was not set.

**Requirements:** R12, R8.

**Dependencies:** U2, U3, U4.

**Files:**
- `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` (the summary block at `:1728`, printed
  lines from `:1761`)
- `plugins/spinoff/skills/spinoff/scripts/spinoff.bats`

**Approach:**
1. Read `UNNAMED_SURFACES` (declared in U1 per KTD8, appended to by U2, U3 and U4).
2. Print one line naming those surfaces when it is non-empty.
3. Say nothing when every surface took its name.

**Patterns to follow:** the plain indented `echo` used by the summary lines from
`spinoff.sh:1761`. Not `step()` (which writes above the summary box) and not `echo … >&2`
(stderr) — R12 puts this line inside the summary block the skill relays verbatim.

**Execution note:** the failure-path scenario runs under the `spinoff.bats` stubs — `smoke.sh`
disables the launcher and never produces a failed rename.

**Test scenarios:**
- `Covers AE5.` A run with one failed rename lists exactly that surface as unnamed, named by
  its target rather than a hardcoded "split".
- A fully successful run prints no unnamed-surface line.

**Verification:** `bats spinoff.bats` passes, including the failed-rename case. `bash smoke.sh`
passes.

### U6. Teach the new convention in SKILL.md

**Goal:** The calling model composes `Ticket: Title` instead of `workspace·work`.

**Requirements:** R10, R1, R2, R3, R4, R5, R6. Implements KTD1.

**Dependencies:** U1.

**Files:**
- `plugins/spinoff/skills/spinoff/SKILL.md` (`:305-322`)

**Approach:**
1. Replace the `~24 chars` / `workspace·work` guidance with the `Ticket: Title` rule and a
   worked example of each arm.
2. State the ticket-resolution order: a ticket already known in the conversation, then an
   optional Linear lookup, then the bare title.
3. State that Linear never blocks, and that ticket creation is confirmed with the user first.
4. State the no-ticket default so the model knows what omitting `--label` produces.

**Execution note:** guidance and code must move in the same commit. The doc drifting from the
script is the failure this section already caused once.

**Test scenarios:** `Test expectation: none -- documentation unit; behavior is covered by U1
and the model-side guidance has no automated harness.`

**Verification:** the SKILL.md example labels match what U1 produces for the same `--name`.

### U7. Extend the smoke suite and bump versions

**Goal:** The new derivation and naming calls are covered, and the change ships.

**Requirements:** R11.

**Dependencies:** none.

**Files:**
- `plugins/spinoff/skills/spinoff/scripts/smoke.sh`
- `plugins/spinoff/.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`

**Approach:**
1. Add the one case that belongs to no single unit: the colon-and-space label. U1 owns the
   empty-title case.
2. Keep every new case below the `HERDR_ENV=0` kill-switch at `:18-19`.
3. Bump both version strings.

**Execution note:** each unit owns the cases that prove it, and writes them before its own
code lands — U1 the amended default-label case, U2 the `pane rename` argv and failure cases
plus its static assertion, U3 its failure case and static assertion, U4 its `set_tab_title`
assertion. This unit holds only what spans units, so it no longer waits on them. Every case,
wherever it lives, is seen failing once before the code that satisfies it — a green run of a
test that never failed proves nothing.

**Patterns to follow:** the `run`/`ok`/`bad` helpers at `smoke.sh:23-32`; the static-assertion
case at `:207-218`.

**Test scenarios:**
- A colon-and-space label passes through `--label` verbatim to the `label:` line.
- Each case fails against the pre-change script and passes after.
- `smoke.sh` exits 0 with no real tab launched.

**Verification:** `bash smoke.sh` exits 0. `bash scripts/check-version-bumped.sh` passes.

---

## Verification Contract

Run from `plugins/spinoff/skills/spinoff/scripts/` unless noted. This repo has no CI; every
gate is run by hand.

| Command | Gate |
| --- | --- |
| `bash smoke.sh` | Arg validation, label derivation, handoff, kickoff shape. Exit 0 = all pass. |
| `bash cli-drift.test.sh` | The new `herdr pane rename` call checked against the installed CLI. |
| `bats spinoff.bats` | `bash -n`, launcher resolution, cmux argv capture. Confirm `bats` is on PATH before claiming it ran. |
| `bash kickoff-gate.test.sh` | The not-briefed gate and exit codes. |
| `bash scripts/check-version-bumped.sh` | Repo root. Both version strings bumped. |

Manual gate, not scriptable: open one spinoff per backend and read every surface name back
from the backend itself — `herdr pane get`, `cmux list-panes`, and Ghostty's `name` property.
A launcher exiting 0 is not evidence a name landed.

---

## Definition of Done

- Every requirement R1-R14 is implemented or explicitly deferred in Scope Boundaries.
- A spinoff on each backend names its tab, split, workspace, and session, verified by reading
  the name back from the backend.
- A no-ticket spinoff produces a bare title with no repo token.
- A rejected rename warns, leaves the worktree and briefed session intact, and appears in the
  run summary as unnamed.
- `SKILL.md` teaches `Ticket: Title` and its examples match what the script produces.
- Every gate in the Verification Contract passes.
- Both version strings are bumped.
- Abandoned experiments are removed from the diff. Probe scripts and temporary AppleScript
  files do not ship.
