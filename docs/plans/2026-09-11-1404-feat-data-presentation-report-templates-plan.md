---
title: Data Presentation Report Templates - Plan
type: feat
date: 2026-09-11
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Data Presentation Report Templates - Plan

## Goal Capsule

- **Objective:** a person can ask in plain words for a report they built once with an agent, and get the same report on today's data with what changed since last time. When the report cannot be reproduced exactly, they are told so plainly instead of being shown something different.
- **Means:** saved template files, one report skill, and a shared script that reads the agent's tool results from the session log, checks them, compares them with the last run, and renders them through the existing `present()` pipeline (KD7, KTD1).
- **Authority hierarchy:** an R-ID wins on behaviour. A KTD wins on mechanism inside the R-IDs it cites. A unit overrides neither.
- **Stop conditions:** stop and report when a session-settled decision proves infeasible, wrong or destructive. Stop and report when the session log cannot be read in the shape U1 pins; never fall back to numbers the agent types.
- **Execution profile:** one plugin, seven units, stdlib-only Python, no network access from the plugin. U7 runs live in the main Claude Code session, never in a subagent.
- **Tail ownership:** a new branch, `feature/data-presentation-templates`, stacked on PR #80 (the data-presentation skill). Its PR targets `feature/data-presentation`.

---

## Product Contract

### Summary

A person builds a report with an agent in conversation, then runs `/data-presentation:new` to save it as a named template. Later, a plain request such as "show me the AI tools report" finds the template. The agent repeats the saved call with its own tools. The plugin reads the result from the session log, checks it is the same call and the same shape, marks what changed since the last run, and renders the report with the time the data was fetched.

### Problem Frame

Today a repeat report is rebuilt from nothing. The AI Tools weekly usage report took six Amplitude tool calls, a reshape into weeks and tools, and a render. A second request repeats all of that reasoning, and nothing guarantees the second run asks the same question. Nothing says what moved since the last time either. So the person cannot tell whether a number is new, revised, or simply fetched a different way.

### Actors

- A1. The person who builds, saves and asks for reports. One person, on their own machine.
- A2. The agent. It makes every fetch with its own tools and relays the plugin's output.
- A3. The report script. It reads the session log and the template store, and it never fetches.

### Key Flows

- F1. Build and save
  - **Trigger:** the person runs `/data-presentation:new` after building a report in conversation.
  - **Actors:** A1, A2, A3
  - **Steps:** the agent drafts a template that names the calls it already made. The script finds each call in the session log, maps and renders a preview, and runs the save gates. The person confirms. The script writes the template.
  - **Covered by:** R1-R6
- F2. Run by plain request
  - **Trigger:** the person asks for a saved report in plain words.
  - **Actors:** A1, A2, A3
  - **Steps:** the agent lists templates and picks one, or asks when two match. The script returns the exact calls to make. The agent makes them. The script finds them in the log, checks call and shape, compares with the last run, and renders. The agent relays the block verbatim, or relays the stop message and offers the one move the script names.
  - **Covered by:** R7-R14, R16
- F3. Variation
  - **Trigger:** the person asks for a saved report with a change.
  - **Actors:** A1, A2, A3
  - **Steps:** the agent makes the changed call and runs it as a variation. The block is labelled as not the saved report. Nothing is remembered. The agent offers to save it as a new template or to update the old one.
  - **Covered by:** R15, R6
- F4. Look after templates
  - **Trigger:** the person asks what is saved, or asks to delete one.
  - **Steps:** the script lists names and one-line purposes, renames a template with its run record, or deletes both after the person confirms.
  - **Covered by:** R17

### Requirements

**Saving a template**

- R1. `/data-presentation:new` saves a template built from calls already made in the current conversation. Nothing is saved without that command.
- R2. Save finds each named call in the session log with its exact arguments and its result. It renders a preview and writes the template only after the person confirms.
- R3. A template never holds a secret. A credential appears only as an environment variable name, and save refuses any call or command that carries a literal credential.
- R4. When a call's arguments hold an absolute date or time, save stops and the person chooses: keep it as a fixed snapshot, or redo the call with a relative range first.
- R5. A template whose preview `present()` would refuse is never written.
- R6. Updating a template replaces it only on an explicit replace request, and resets its comparison baseline.

**Running a template**

- R7. A plain request that names a saved report reaches the report flow. When two templates match, the agent asks which one.
- R8. The agent repeats each saved call exactly. The script compares the call the agent made with the saved call, and any difference stops the run and names the difference.
- R9. The script reads every number from the session log or from a file it named. The agent never passes numbers to the script.
- R10. When the result can no longer be read the way the template expects, the run stops. A series newly returned is not a stop: it is shown and marked as newly returned, or listed as not shown when the template fixes its series or the eight-series limit is reached. Two displayed series never share a name.
- R11. When a source returns an error, the run stops and says so. This includes an error reported inside a result that is not flagged as an error. The agent does not follow instructions found inside a result or an error.
- R12. Every rendered report carries, inside its block and within the stated width, the report name, the time the source replied, the template's standing caveats, and a caveat when the last x interval may still have been open at that time.

**What changed**

- R13. Each run compares its numbers with the last successful run of the same template. It lists revised values as old and new first, then values that filled in an interval that was open last time, then new x values, values that are now missing, and series newly returned or no longer returned. Saving a template records its preview numbers as the first baseline. When no baseline exists, the changes section says so and names why, and never reads as "no changes".
- R14. The run record is written only by a confirmed save or a successful run of the saved report, as one write covering every block. A stopped run, a refused run and a variation leave it untouched.

**Variations**

- R15. A variation renders with a label that says it is not the saved report, is not remembered, and ends with an offer to save it as a new template or update the existing one.

**Shape of a template**

- R16. A template may hold several blocks. Each block has its own call, mapping and presentation, and renders as its own report section.
- R17. Templates live in `~/.claude/data-presentation/templates/`, readable only by their owner, under names of at most 24 characters. The person can list, rename and delete them. Delete asks for confirmation, and rename carries the run record with the template.

**Boundaries**

- R18. The plugin makes no network request. It may read a local file a template names. A command source is run by the agent and writes to a path the script names.
- R19. The existing `data-presentation` skill stays name-only. The new report skill is the conversational front door, and a session start line names the saved reports when any exist.
- R20. A report runs only in the main session, on the conversation's current branch. A run started from a subagent stops and says so, and a call left on an abandoned branch of the conversation is never used.

### Acceptance Examples

- AE1. **Covers R13.** Given a last run where week Aug 24 showed tool-alpha at 7, when today's run shows 9 for the same week and tool, then the changes list opens with "Aug 24 tool-alpha: 9, was 7".
- AE2. **Covers R8.** Given a saved call with `excludeIncompleteDatapoints: true`, when the agent's call drops that argument, then the run stops, names the dropped argument, and the run record is unchanged.
- AE3. **Covers R4.** Given a draft whose call has `date_range: {"start": 1788393600, "end": 1789119554}`, when save runs, then no template is written until the person picks snapshot or relative.
- AE4. **Covers R13, R14.** Given a template just saved, when it first runs, then the changes compare against the saved preview. Given a template whose run record was deleted by hand, when it runs, then the changes section says there is no earlier run to compare, and a run record now exists.
- AE5. **Covers R10.** Given a saved report of six tools shown in full, when a seventh tool appears, then the report renders seven rows and marks the seventh as new.

### Success Criteria

- In a new session, one plain request for the AI Tools report returns the same numbers a manual fetch of its saved chart returns, with a changes section and a fetch time.
- Every stop path in the `finish` decision order has a test that shows the run stopped and the run record did not move.

### Key Decisions

- KD1. **The plugin never fetches data.** The agent fetches with its own tools, and the plugin validates and renders. (session-settled: user-directed — chosen over the skill querying Amplitude or APIs itself: one honest rendering layer, independent of source.) Governs R9, R18.
- KD2. **A template stores the exact call, and a run stops on any difference.** (session-settled: user-approved — chosen over a plain-language intent re-derived each run, and over an exact call with intent as fallback: the same report every time, and it breaks loudly when the source changes.) Governs R2, R8, R10, R11.
- KD3. **Templates are fixed.** (session-settled: user-approved — chosen over per-template knobs and over free edits on request: a saved report never drifts without the person knowing.) Governs R6, R15.
- KD4. **Templates live in the user folder.** (session-settled: user-approved — chosen over repo-only storage and over a user folder with repo override: reports are not tied to a repo.) Governs R17.
- KD5. **A command creates, and a plain request re-runs.** (session-settled: user-directed — chosen over command-only and over plain-request-only: nothing is saved by accident, and re-running stays easy.) Governs R1, R7, R19.
- KD6. **Each run remembers the last run and shows what changed.** (session-settled: user-directed — chosen over a fresh run with no stored data: the weekly check-in value.) Governs R13, R14.
- KD7. **Template files, one report skill, and a shared script.** (session-settled: user-approved — chosen over one generated skill per template and over self-running templates: it works with every source, including MCP-only ones, and keeps KD1.) Governs R16, R19.
- KD8. **Revisions stand out more than new points.** A revision means a number the person may already have repeated has changed. Governs R13.

### Scope Boundaries

**Deferred for later**

- Scheduled or unattended runs.
- Sharing templates through a repo or with a team.
- A capture hook as a second way to read tool results (KTD1 names when it becomes necessary).
- Adapters for sources other than the Amplitude chart result, a JSON path mapping and ready-shaped data.
- Runs started from a subagent. They stop with a message in this plan (R20).
- Saving a report built before `/clear` or in another session. Save names the missing calls and asks for them to be made again.

**Outside this product's identity**

- Saying what the numbers mean.
- SVG or any output other than the text block.

### Dependencies / Assumptions

- The session log is JSON lines at `~/.claude/projects/<project-folder>/<session-id>.jsonl`, and `CLAUDE_CODE_SESSION_ID` holds the id. The project folder comes from the directory the session started in, not the shell's current directory, so the log is found by its id alone. Checked live on 2026-09-11: the variable was set, a lookup by id alone found exactly one file, and a tool result was in the log before the next call.
- A Bash call's own `tool_use` line is in the log while the command runs. Checked live on 2026-09-11 by grepping for a string in the running command. A subagent inherits the parent's `CLAUDE_CODE_SESSION_ID`, and its calls are logged under `<session-id>/subagents/`. `CLAUDE_CODE_CHILD_SESSION` is `1` in the main session too, so it cannot tell them apart.
- Log lines link to their parent by `parentUuid`, and a chain ends at a compaction boundary that carries `logicalParentUuid`. A naive walk across that boundary looped in a probe on 2026-09-11, so the walk needs a visited set.
- A result too large to keep inline is saved to `<session-id>/tool-results/<id>.txt` and the log holds a `<persisted-output>` notice with that path. Checked live on 2026-09-11.
- Bash output kept in the log is cut at about 30,000 characters. Checked live on 2026-09-11 (a 40.3 KB output kept 31 KB).

### Sources

- `plugins/data-presentation/scripts/present.py` — `present(request)` is the in-process entry point (line 169). `main()` is the CLI shell (line 253).
- `plugins/data-presentation/scripts/constants.py` — `MAX_SERIES = 8`, `MAX_LABEL_CHARS = 24`, `MAX_SOURCE_FIELDS = 8`.
- `plugins/spawn/skills/spawn/SKILL.md` — one conversational skill in front of name-only siblings.
- `plugins/auto/lib/run_record_core.py` — atomic write with `mkstemp`, `os.replace`, mode `0o700` directories and `0o600` files.
- `docs/solutions/architecture-patterns/command-and-skill-sharing-a-name.md` — a command and a skill with one name hide the skill.
- `docs/solutions/logic-errors/exporting-an-empty-credential-is-worse-than-exporting-none.md` and `docs/solutions/best-practices/default-deny-for-an-unattended-agent.md` — state safety rules as an allowlist, and test them.
- `docs/solutions/logic-errors/a-tally-keyed-on-exit-status-reports-work-that-never-happened.md` — count observed values, never exit codes.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The script reads tool calls and results from the live session log.** It pairs each `tool_use` with its `tool_result` by id, follows a `<persisted-output>` notice to its file, and unwraps the MCP text envelope. All log reading lives in one module so a format change breaks in one place and stops with a clear message. The log is found by globbing `~/.claude/projects/*/<session-id>.jsonl`, and anything other than exactly one match stops with a named message. The reader skips line types other than `user` and `assistant`, and stops as unreadable only when a `tool_use` or `tool_result` block it needs cannot be parsed. Two capture hooks are the alternatives. An armed hook lost because it must be switched on before a call and re-issue the call at save. An always-on `PostToolUse` hook would also hold build calls, but it writes every tool result to disk and runs on every tool call. Promote a hook only if the log stops holding full results. Implements KD1, R9.
- KTD12. **Only calls on the current branch of the main session count.** `prepare` returns a random marker, and the agent passes it to `finish` on the command line. `finish` first finds its own Bash `tool_use` by that marker in the main log. When the marker is absent there, it looks in `<session-id>/subagents/`, and stops with the subagent message when found. From that line it walks `parentUuid` links back, crossing a compaction boundary by `logicalParentUuid`, with a visited set. Only calls on that path and after the matching `prepare` count. `save` walks the same path from its own Bash line. Implements R20, R2, R8.
- KTD2. **Call equality is canonical JSON after dropping volatile arguments.** Each source kind declares an ignore list. For Amplitude it is `rationale`, which every call in this session carried with different text. For Bash it is `description`, `timeout` and `run_in_background`. The same list applies to the saved call and the new call. For each block, `finish` pairs the saved call with an equal call made after the marker. It names a difference only when exactly one unpaired call to the same tool remains, and otherwise stops naming the block whose call was not made. (session-settled: user-approved — inherits KD2: chosen over plain-language intent: the same report every time.) Governs R2, R8.
  - Conflict call-out: an exact call with absolute dates returns the same window forever, so no new x value ever appears. 9 of 36 real `query_amplitude_data` calls in past session logs used absolute epoch dates. R4's save gate handles it. The decision stands.
- KTD3. **Three source kinds, one closed list.** `tool` is an MCP or other tool call found in the session log. `command` is a shell command the agent runs, which writes to an output path the script names, because Bash output in the log is cut at about 30,000 characters. The template stores the command with an `{output}` placeholder. `prepare` fills it with a path unique to the run, inside `~/.claude/data-presentation/out/` (`0o700`), and `finish` substitutes the placeholder back before comparing. `finish` refuses an output file that is missing or older than the marker, and deletes it when done. A saved `curl` command must use `-f`, so an HTTP error fails the command. `file` is a local path the script reads, and its reply time is the file's modification time. Any other kind is refused at save. Implements R9, R18.
  - Conflict call-out on KD1: reading a local file named in a template is the plugin acquiring data. This plan keeps it in bounds because no network is involved, and records the choice here.
- KTD4. **Three mapping adapters, one closed list.** `amplitude-segmentation` reads `xValuesForTimeSeries`, the name in each `seriesLabels` pair, and `timeSeries` from a `get_amplitude_charts` result with `include: "data"`. It first checks the top-level `success` and `failedCount` and its chart's `results[i].success`, and routes any failure to the source-error stop. That tool takes at most three chart ids per call, so a block names a chart id within a call, and `prepare` asks for the fewest calls. A result that the adapter cannot read but that parses as an error shape (a top-level `error` or `errors` key) is a source error, not drift. `paths` reads x, series names and values by the grammar in the design section. `identity` takes data already shaped as `x` and `series`. Implements R10, R16.
- KTD5. **The fingerprint is structural.** It holds the key paths the adapter reads, the type at each path, and the x kind: dates with their step in days, or labels. It treats integer, float and `null` as one numeric type. It excludes counts, so a new series or a longer range is not drift. For Amplitude it also holds a hash of the chart definition's `params` from the result, so an edit to the chart in Amplitude stops the run. Implements R10.
- KTD6. **The run record holds mapped numbers only, for every block in one file.** It stores the raw x values, series, the source reply time, and which x value may still have been open, per block, plus a hash of the template body. A confirmed save writes the first record from its preview. A record whose hash differs from the template is treated as absent, and the changes section says the template changed since the record was written. Writes are atomic: `mkstemp` in the target directory, then `os.replace`. Implements R6, R13, R14.
- KTD7. **Closed status and next-move vocabularies.** `status` is one of `ok`, `stopped`, `refused` or `fault`. `next` is one of `none`, `ask_which_template`, `make_calls`, `offer_save_variation`, `offer_rebuild_template`, `ask_user_to_set_env`, `ask_snapshot_or_relative`, `confirm_save`, `confirm_delete` or `run_finish_again`. `run_finish_again` covers a call found with no result yet, which happens when `finish` runs in the same message as the call. Each stop names one move the agent may offer. Without one, the agent draws the chart itself from numbers it already holds. Implements R8, R10, R11.
- KTD8. **The report block is composed around `present()`, which stays unchanged.** Title and units go in as today. The report name, reply time, variation label, caveats and changes list are lines the report script appends inside the same block, each cleaned with the gate's escaping and held within the stated width. The changes list shows at most 12 lines and says how many more there are. With `series: "all"` and more than eight series, the block shows the eight with the largest latest value and lists the rest as not shown. Implements R10, R12, R13, R15.
- KTD9. **The report skill triggers from conversation.** Its description says to use it when a person asks for a report by name or asks what reports are saved. That breaks this plugin's name-only convention on purpose, and follows `spawn`, where one conversational skill fronts name-only siblings. A session start hook prints one line naming saved reports whose file names match the name pattern, and prints nothing when none exist. The skill is named `report` and the command `new`, and a harness check asserts no command shares a skill's name. (session-settled: user-directed — inherits KD5: chosen over command-only: re-running stays easy.) Governs R7, R19.
- KTD10. **Secrets are refused by allowlist.** In a `command` source, a credential position must hold only a `$NAME` or `${NAME}` reference. Credential positions are every header value except a short safe list (`Accept`, `Content-Type`, `User-Agent`), URL userinfo, `-u` and `--user`, `--oauth2-bearer`, and any query value whose key contains `token`, `key`, `secret`, `pass` or `auth`. Any other value there is refused. Any string of 20 or more characters that mixes letters and digits outside an env reference is also refused. At run time the script checks each named variable is set and non-empty, and never prints its value. Implements R3.
- KTD11. **Storage paths and permissions.** Templates go in `~/.claude/data-presentation/templates/<name>.json` and run records in `~/.claude/data-presentation/runs/<name>.json`. Directories are `0o700` and files `0o600`. A name matches `^[a-z0-9][a-z0-9-]{0,23}$`, and every operation checks the name before building a path. A followed `<persisted-output>` path is resolved with `realpath` before the containment check. Unknown keys in a template are refused on read, so a hand edit cannot add behaviour. An alias target that equals any other displayed name, aliased or not, is refused at save and stops a run. Implements R10, R17.

### High-Level Technical Design

Run sequence:

```mermaid
sequenceDiagram
  participant P as Person
  participant A as Agent
  participant S as report.py
  participant L as Session log
  P->>A: show me the AI tools report
  A->>S: list "AI tools"
  S-->>A: ai-tools (one match)
  A->>S: prepare ai-tools
  S-->>A: calls to make + run marker, next=make_calls
  A->>A: get_amplitude_charts(chart-aaaa, include=data, ...)
  A->>S: finish ai-tools --marker M (a later message)
  S->>L: find this Bash call by M, walk back to prepare, read the saved call's result
  S->>S: call equality, error flag, map, fingerprint, compare, present()
  S-->>A: status=ok, block, next=none
  A->>P: block, verbatim
```

`finish` decision order:

```mermaid
flowchart TB
  A[finish] --> B{log found, marker in main log?}
  B -->|no| X1[stopped: cannot read this session, or run from a subagent]
  B -->|yes| C{each saved call on the current branch after prepare?}
  C -->|no| X2[stopped: call not made, next=make_calls]
  C -->|call, no result yet| X7[stopped: next=run_finish_again]
  C -->|yes| D{canonical args equal?}
  D -->|no| X3[stopped: names the difference]
  D -->|yes| E{error flag, failure fields, or error shape?}
  E -->|yes| X4[stopped: source error, no retry]
  E -->|no| F{adapter reads it and fingerprint matches?}
  F -->|no| X5[stopped: next=offer_rebuild_template]
  F -->|yes| G{present accepts every block?}
  G -->|no| X6[refused: present message]
  G -->|yes| H[compare with run record, compose block]
  H --> I{variation?}
  I -->|yes| J[ok, labelled, next=offer_save_variation]
  I -->|no| K[write run record, ok]
```

Template shape, as directional guidance:

```json
{
  "name": "ai-tools",
  "purpose": "Weekly people using each AI tool",
  "caveats": ["Staff accounts only", "Demo accounts excluded"],
  "blocks": [
    {
      "source": {"kind": "tool", "tool": "mcp__plugin_amplitude_amplitude__get_amplitude_charts",
                 "args": {"chartIds": ["chart-aaaa"], "include": "data", "excludeIncompleteDatapoints": true}},
      "mapping": {"adapter": "amplitude-segmentation", "chart": "chart-aaaa", "series": "all", "aliases": {"tool-alpha-v2": "tool-alpha"}},
      "present": {"title": "Weekly people using each AI tool", "units": "people", "type": "auto"},
      "fingerprint": {"paths": {"...": "list"}, "x": {"kind": "date", "step_days": 7}, "definition": "sha256:..."}
    }
  ]
}
```

`paths` grammar, as directional guidance:

```text
path     := segment ("." segment)*
segment  := key | index | "*"
key      := [A-Za-z_][A-Za-z0-9_]*
index    := digits
mapping  := { x: path, names: path, values: path }   one "*" in names, two in values (series, then x)
```

### Output Structure

```text
plugins/data-presentation/
  .claude-plugin/plugin.json        (adds commands; version 0.2.0)
  commands/new.md
  hooks/hooks.json
  hooks/saved-reports.sh
  skills/data-presentation/SKILL.md (unchanged)
  skills/report/SKILL.md
  scripts/session_log.py
  scripts/templates.py
  scripts/mapping.py
  scripts/changes.py
  scripts/report.py
  tests/fixtures/                   (synthetic values in real structure)
  tests/session_log_test.py
  tests/templates_test.py
  tests/mapping_test.py
  tests/changes_test.py
  tests/report_test.py
  tests/harness.sh                  (explicit list grows by five)
```

### Assumptions

- A template with `series: "all"` shows every series in the result up to eight, per KTD8. A template with an explicit list shows only those, and lists the rest as not shown.
- When a call carries a top-N argument (Amplitude `groupByLimit`), the changes section adds a line that a series may be newly returned or no longer returned because of that limit.
- An open last interval gets a caveat. The script does not drop it, because `excludeIncompleteDatapoints` does that at the source when wanted.
- The run record has no lock. Two sessions finishing one template together leave the later one's record, and the next run's changes name the reply time they compared against.
- When any block stops, the whole run stops. A partial report is not shown.
- The reply time is the `timestamp` of the log line that holds the result, stored in UTC and shown in local time with its UTC offset.
- Amplitude x values carry no time zone; they are in the project's zone. The open-interval caveat fires when the reply time falls before the last interval's end in the latest zone (UTC-12), and says the last point may still have been open. It can fire on a closed interval; it cannot miss an open one.
- A run from a subagent stops with a message. The main session's log is the only one read.

### Sequencing and Parallelism

- U1, U2 and U3 have no dependency on each other and can run in parallel.
- U4 needs U3's mapped shape and can start once U3's output contract is fixed.
- U5 needs U1 to U4.
- U6 needs U5.
- U7 needs U6 and runs in the main session.

---

## Implementation Units

### U1. Session log reader

**Goal:** find a tool call and its result in the current session log, exactly and only there.

**Requirements:** R2, R8, R9, R11, R18, R20; KTD1, KTD3, KTD12.

**Dependencies:** none.

**Files:**
- Create `plugins/data-presentation/scripts/session_log.py`
- Create `plugins/data-presentation/tests/fixtures/` (synthetic values in real structure)
- Create `plugins/data-presentation/tests/session_log_test.py`

**Approach:**
1. First build fixtures that copy the structure of real log lines and replace every value. Keep the keys, nesting, `parentUuid` links, a compaction boundary, the double MCP text envelope and the `<persisted-output>` notice. Make every number, label, id, chart parameter, path, timestamp and free text synthetic, and use generated filler for the cut Bash output. This repo is public, so no real value may reach a fixture.
2. Resolve the log per KTD1. Stop when the variable is unset or the match count is not one.
3. Pair `tool_use` to `tool_result` by id. Return tool name, arguments, result text, error flag and the result line's timestamp.
4. Unwrap the MCP text envelope. Follow a `<persisted-output>` path only when it resolves inside this session's `tool-results/` directory.
5. Walk the current branch per KTD12, and keep only calls between the matching `prepare` line and the `finish` line.
6. Skip other line types. Report an unparseable tool block as a named stop, never as "no call found".

**Patterns to follow:** the standalone `check()` test style in `plugins/data-presentation/tests/present_test.py`.

**Test scenarios:**
- The fixture Amplitude call is found by tool name, and its arguments and result text equal the fixture's.
- A call made before `prepare` is not returned.
- A call on an abandoned branch after `prepare` is not returned, and the call on the current branch is.
- The walk crosses a compaction boundary and terminates on a fixture whose links form a loop.
- The reader finds the log when run from a subdirectory of the launch directory.
- A marker found only under `subagents/` returns the subagent stop.
- A line of an unknown type is skipped.
- A harness check fails when a fixture contains a `/Users/` path, the real chart id or a real session id.
- A spilled result returns the full file text, not the notice.
- A `<persisted-output>` path outside the session's directory is refused.
- An `is_error` result returns the error flag set.
- `CLAUDE_CODE_SESSION_ID` unset stops with a message that names the variable.
- A tool block that cannot be parsed stops with "cannot read this session log", distinct from "call not found".
- A path under `subagents/` is never read.

**Verification:** each scenario passes, and removing the branch walk, the visited set or the directory check turns its test red.

### U2. Template store and save gates

**Goal:** read, validate and write templates and run records safely, and refuse templates that break R3 or R4.

**Requirements:** R3, R4, R6, R17; KTD6, KTD10, KTD11.

**Dependencies:** none.

**Files:**
- Create `plugins/data-presentation/scripts/templates.py`
- Create `plugins/data-presentation/tests/templates_test.py`

**Approach:**
1. Validate a template against a closed schema. Unknown keys, unknown source kinds and unknown adapters are refused.
2. Validate names against KTD11's pattern.
3. Write atomically with the modes in KTD11. Refuse to overwrite without a replace flag.
4. Secret scan per KTD10 over every argument value and command string.
5. Absolute-date scan over the remaining arguments: epoch seconds or milliseconds in a plausible range, and ISO dates. Return the paths it found.
6. Delete removes the template and its run record together.
7. Tests run with `HOME` pointed at a temporary directory.

**Patterns to follow:** `plugins/auto/lib/run_record_core.py` for the atomic write; `plugins/data-presentation/scripts/validate.py` for refusals as plain-language messages.

**Test scenarios:**
- A valid template round-trips and reads back equal.
- A template with an unknown top-level key is refused, naming the key.
- A written file has mode `0o600` and its directory `0o700`.
- Saving over an existing name without replace is refused, and with replace succeeds.
- A name with a slash, a dot or uppercase is refused.
- A curl command with `-H "Authorization: Bearer abc123def456ghi789jkl"` is refused.
- The same command with `-H "Authorization: Bearer $AMPLITUDE_TOKEN"` is accepted.
- A command with `-H "X-Api-Key: abc123"` is refused, and one with `https://user:pass@host` is refused.
- A `curl` command without `-f` is refused.
- A 25-character name is refused, and `delete` and `rename` refuse an invalid name before touching any path.
- An empty env reference such as `$` alone is refused.
- `date_range: {"start": 1788393600, "end": 1789119554}` is flagged with both paths.
- `{"relative": "Last 90 Days"}` is not flagged.
- Delete removes both the template and its run record.

**Verification:** each gate has one test that goes red when the gate line is removed.

### U3. Mapping and fingerprint

**Goal:** turn a result into `x` and `series` the same way every run, and detect when the result's structure changed.

**Requirements:** R10, R16; KTD4, KTD5.

**Dependencies:** none. U1's fixtures are reused once they exist.

**Files:**
- Create `plugins/data-presentation/scripts/mapping.py`
- Create `plugins/data-presentation/tests/mapping_test.py`

**Approach:**
1. Implement the three adapters in KTD4 behind one closed registry.
2. Implement the `paths` grammar in the design section. A missing key, a type mismatch, or a names count that differs from the values count is a stop, never a gap.
3. Apply aliases and series selection. Aliases must map to distinct names.
4. Build the fingerprint at save and compare it at run, per KTD5.
5. Convert Amplitude week dates to short labels only after the fingerprint check.

**Test scenarios:**
- The weekly fixture maps to 13 x values and six series with the fixture's values.
- A `paths` mapping over a hand-built JSON file maps to the expected x and series.
- A result with `jsonResponse` renamed stops, naming the missing path.
- A seventh series in the result passes the fingerprint and appears in the output. Covers AE5.
- A 14-week result passes the fingerprint.
- A result whose x step changes from 7 days to 1 day fails the fingerprint.
- A changed chart definition `params` hash fails the fingerprint.
- Two aliases mapping to one name are refused at save.
- An alias that equals an untouched series name is refused at save, and stops a run when the source later returns that name.
- Nine series with `series: "all"` show the eight largest by latest value and list the ninth as not shown.
- A result with `failedCount: 1` and no error flag routes to the source-error stop.
- A block selects its chart by id from a three-chart result.
- Two fetches of the same chart a week apart produce the same definition hash.
- A `null` value maps to a gap and a `0` maps to zero.

**Verification:** each scenario passes, and removing the step check or the definition hash check turns its test red.

### U4. Run record and changes

**Goal:** compare a run with the last successful one and describe the difference in plain lines.

**Requirements:** R13, R14; KD6, KD8; KTD6.

**Dependencies:** U3's mapped output shape.

**Files:**
- Create `plugins/data-presentation/scripts/changes.py`
- Create `plugins/data-presentation/tests/changes_test.py`

**Approach:**
1. Compare by raw x value and series name, never by position or short label.
2. Order the output: revised values, then values that filled in an interval that was open last time, then new x values, then values now missing, then series newly returned or no longer returned.
3. An x value that rolled off the start of a relative range is not listed as missing.
4. Compare numbers after the same formatting `render.format_number` uses. A difference that formats the same is not a revision.
5. Treat a record with a different template hash as absent.
6. List a later value for an x that may still have been open last time as filled in, below revisions.
7. Cap the list per KTD8.

**Test scenarios:**
- Covers AE1. The Aug 24 value going from 7 to 9 is the first line, worded as revised.
- A new week at the end is listed as new.
- The oldest week rolling off is not listed.
- A value that was 5 and is now `null` is listed as now missing.
- A first run returns the "no earlier run" line. Covers AE4.
- A record written under a different template hash is treated as absent.
- 30 revisions produce 12 lines plus a line saying 18 more.
- A week stored as possibly open at 40 and now 70 is listed as filled in, not revised.
- Series wording reads "newly returned" and "no longer returned".
- Two values that format identically are not listed as revised.

**Verification:** each scenario passes, and removing the rolled-off rule or the hash check turns its test red.

### U5. The report script

**Goal:** one CLI with `list`, `prepare`, `finish`, `save` and `delete` that the agent drives and cannot talk past.

**Requirements:** R2, R4, R5, R7-R16, R20; KTD2, KTD7, KTD8, KTD12.

**Dependencies:** U1, U2, U3, U4.

**Files:**
- Create `plugins/data-presentation/scripts/report.py`
- Create `plugins/data-presentation/tests/report_test.py`

**Approach:**
1. `list` returns names and purposes. With a phrase, it returns every match, and `ask_which_template` when there is more than one.
2. `prepare` checks that named env variables are set, then returns the exact calls, output paths for `command` sources, and a random marker for `finish`.
3. `finish` follows the decision order in the design section and returns KTD7's fields.
4. `save` takes a draft, finds each call in the log, runs U2's gates and U3's fingerprint, renders a preview, and returns `confirm_save`. A second call with `--confirm` writes the template.
5. Compose each block through `present.present()` in-process, then append caveats and changes per KTD8.
6. Add the open-last-interval caveat per the time-zone assumption.
7. `save` takes one draft for the whole template. A call not found for any block refuses the whole save.
8. `rename` moves the template and its run record together. `delete` returns `confirm_delete`, and a second call with `--confirm` deletes both.
9. Stop per KTD12 when the marker is not in the main log.
10. Every response carries the relay rule: show the block verbatim, and on a stop, relay the message and do not show the numbers another way.

**Test scenarios:**
- An end-to-end `save` then `finish` over fixture logs returns `ok` with the block, the changes section, and a written run record.
- Covers AE2. A call missing `excludeIncompleteDatapoints` stops, names it, and leaves the run record byte-identical.
- A call whose only difference is `rationale` passes.
- Covers AE3. A draft with absolute dates returns `ask_snapshot_or_relative` and writes nothing.
- A draft whose preview `present()` refuses returns `refused` and writes nothing.
- An `is_error` result stops, and the run record is unchanged.
- A variation returns `ok`, a label inside the block, `offer_save_variation`, and an unchanged run record.
- A two-block template where the second block's call is missing stops as a whole.
- Two blocks calling the same tool with different chart ids pair correctly, and dropping an argument on block one names that argument for block one.
- A call with no result yet returns `run_finish_again`, not `make_calls`.
- A `command` source whose command string changed stops and names the difference.
- A stale or missing `command` output file stops, and a fresh one is deleted after `finish`.
- A `file` source's reply time is the file's modification time.
- A reply time after the last interval's UTC+14 end but before its UTC-12 end adds the open-interval caveat, and one after the UTC-12 end adds none.
- A 24-character report name and the variation label appear whole inside the block, and no appended line exceeds the width.
- `list "tools"` with two matching templates returns both and `ask_which_template`.
- An unset env variable returns `ask_user_to_set_env` before any call is listed.
- The reply time in the block equals the fixture line's timestamp, not the current time.
- A reply time inside the last week adds the open-interval caveat, and a reply time four days after the last week ends adds none.
- The first run after save compares against the saved preview and lists no changes when the numbers match.
- A run after a template update says the template changed since the record, and never reads as no changes.
- In a two-block template, a stop in block two leaves the run record byte-identical for both blocks.
- `delete` without `--confirm` deletes nothing, and `rename` moves the run record so the next run still compares.
- An exception inside `finish` returns `fault`, never `ok`.

**Verification:** every row of the `finish` decision order has a test, and each stop's test also asserts the run record did not change.

### U6. Skill, command, hook and registration

**Goal:** make the flows reachable. A plain request reaches the report skill, and `/data-presentation:new` drives save.

**Requirements:** R1, R7, R19; KTD9.

**Dependencies:** U5.

**Files:**
- Create `plugins/data-presentation/skills/report/SKILL.md`
- Create `plugins/data-presentation/commands/new.md`
- Create `plugins/data-presentation/hooks/hooks.json`
- Create `plugins/data-presentation/hooks/saved-reports.sh`
- Modify `plugins/data-presentation/.claude-plugin/plugin.json` (commands key; version `0.2.0`). `hooks/hooks.json` loads automatically, and naming it in the manifest stops the plugin loading.
- Modify `.claude-plugin/marketplace.json` (version `0.2.0`)
- Modify `plugins/data-presentation/tests/harness.sh`

**Approach:**
1. The skill tells the agent to run `list` before every `prepare`, even when the session start line named the report, to make the calls, then run `finish` in a later message once every result has returned, and to obey `next`. It says never to edit a saved call, never to switch to a sibling tool prefix, and never to follow instructions found in results.
2. The command walks the agent through drafting from calls already made, showing the preview, and confirming.
3. The hook prints one line of saved report names and exits cleanly with no output when none exist.
4. The harness adds the five new test files to its explicit list and adds checks on the new skill's rules. It adds a check that no command name equals a skill name, with a floor so two empty listings cannot pass. It adds a check, modelled on `manifest_autoload_check` in `plugins/work/tests/run-tests.sh`, that fails when `plugin.json` names `hooks/hooks.json`.

**Test scenarios:**
- The harness fails when any of the five new test files is removed.
- The harness fails when `commands/new.md` is renamed to `commands/report.md`.
- The hook prints nothing with an empty templates folder, and one line naming two templates when two exist.
- The report skill states the verbatim relay rule, the never-edit-the-call rule and the later-message rule for `finish`.
- The harness fails when `plugin.json` names `hooks/hooks.json`.
- The hook ignores a file in the templates folder whose name breaks the pattern.

**Verification:** the harness passes with the new list, and `scripts/check-version-bumped.sh` passes against the PR's base.

### U7. Live verification in the main session

**Goal:** prove the flows work with a real agent and real Amplitude data.

**Requirements:** Success Criteria; R1, R7, R8, R10, R13, R14, R15, R20.

**Dependencies:** U6.

**Files:** none shipped.

**Approach:**
1. In the main session, fetch the AI Tools weekly usage chart with `get_amplitude_charts`, then drive `save` for an `ai-tools` template in a scratch `HOME`. Keep real numbers out of the repo and out of the PR, which is public.
2. Fetch again and run `finish`. Check the numbers against the fetch and the changes section against the first run.
3. Run a variation and check the label and the unchanged run record.
4. Change one argument on purpose and check the stop.
5. Run `finish` from a subagent and check the stop message.

**Test expectation:** live checks only. Record each outcome in the PR body as a description, with no real numbers.

**Verification:** all five steps produce the outcome named, and any block in the PR body is rendered from synthetic fixture data.

---

## Verification Contract

| Gate | Command | Pass signal |
|---|---|---|
| Plugin tests | `bash ~/.claude/tools/honest-run/run.sh --expect "harness: [0-9]+ passed, 0 failed" -- bash plugins/data-presentation/tests/harness.sh` | a `verdict:` PASS line |
| Mutation | remove each gate line named in a unit's Verification, run the harness, restore byte-exact | every mutant red, restore checksum equal |
| Version | `scripts/check-version-bumped.sh origin/main` | exit 0 |
| Live | U7's five steps | each named outcome observed |

---

## Definition of Done

- Every unit's test scenarios exist and pass through the harness's explicit list.
- Every gate named in a unit's Verification has been removed once and turned a test red.
- U7's five live outcomes are described in the PR body, which contains no real Amplitude numbers.
- `plugin.json` and `marketplace.json` both say `0.2.0`.
- No code from abandoned approaches is left in the diff.
- `docs/handoff.md` is not staged.
