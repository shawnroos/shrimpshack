---
title: PM Sweep in Four Steps - Plan
type: feat
date: 2026-10-31
topic: pm-sweep-four-steps
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# PM Sweep in Four Steps - Plan

## Goal Capsule

- **Objective:** The PM never loses sight of a live session in its domain. It handles every session in its remit in a stated order, and it tells Shawn about sessions outside the remit worth adding.
- **Means:** Rework the programme sweep (`plugins/auto/skills/programme-sweep/SKILL.md`, `lib/programme_sources.py`, `lib/programme_behaviours*.py`) into four ordered steps.
- **Product authority:** Shawn (typed 2026-10-31). Adding a session to the remit stays a typed line from Shawn.
- **Open blockers:** None. Three checks are deferred to planning (Outstanding Questions).

## Product Contract

### Summary

The sweep runs four steps in order: (1) check the whole domain and run behaviours aimed at the PM; (2) work each session in the remit, most urgent first; (3) look at sessions outside the remit and recommend which to add; (4) check the domain again for PM behaviours. A live session whose folder is gone no longer drops out silently: the PM closes it when safe and reports it.

### Problem Frame

The PM keeps missing tabs and panes. Measured on programme prog-20261028-130241-d8b9d6 (herdr workspace w2): the pane "Auto without herdr: Ghostty and Rex" (w2:pR) was skipped as `repo_out_of_remit`, because its worktree was removed after its PR merged. `_pane_scope` in `plugins/auto/lib/programme_sources.py` drops a pane whose folder is not in a remit repo, so a gone folder looks like an outside repo. The sweep also reads only the remit's workspaces, so panes in other workspaces (w3 holds the Peek tabs and "Spinoff without herdr") can never be recommended. Behaviours aimed at the PM (`applies_to: pm`) have no domain-level trigger: `due()` in `programme_behaviours_due.py` resolves only the `workers` audience, per item.

### Key Decisions

- **Step 2 order is Shawn-first.** Waiting on Shawn or blocked, then claiming a merge, then idle with work left, then working. Governs R3. (session-settled: user-directed — chosen over blocking-others-first, pane-state-only and gone-folder-first: Shawn's time is the scarcest resource, per `references/sequencing.md`.)
- **A gone-folder pane is closed and reported, not left skipped.** Governs R5, R6. (session-settled: user-directed — chosen over keep-and-flag and recommend-instead: Shawn chose "close it and report it".)
- **Close only when the folder is gone, the pane's PR is merged and its agent is idle.** Governs R6. (session-settled: user-approved — chosen over idle-only and folder-gone-only, which could close abandoned work or a live session.)
- **Step 3 shows a list in the Programme view and opens one picker only when the recommended set changes.** Governs R9, R10. (session-settled: user-approved — chosen over view-only and picker-every-sweep.)
- **The domain scan runs in `P sweep` and reuses the host's pane list.** It adds no host call and feeds the `sweep-inputs` digest, so an unchanged domain keeps the quiet sweep. Governs R11.
- **A host's "space" is a herdr workspace, a Rex session or a Ghostty window** (`plugins/auto/CONCEPTS.md`). The domain is every space the host can list. Rex `list_panes` already lists every session. Governs R7.

### Requirements

**Sweep shape**
- R1. The sweep runs four steps in this order: domain check, remit sessions, outside sessions, domain check again. SKILL.md states them as the sweep's spine.
- R2. Steps 1 and 4 run every behaviour whose audience is `pm` or `both` against the current state of the domain, and the PM answers each due line before the sweep may end.

**Remit sessions (step 2)**
- R3. The PM handles remit sessions in this order: waiting on Shawn or blocked; worker claiming a merge; idle with work left; working (no action). It applies worker behaviours per session as today.
- R4. A session whose state is unknown is handled before any "working" session and reported once.

**Gone folders**
- R5. A live pane whose folder no longer exists stays in step 2 and is flagged `folder_gone`. It is never reported as `repo_out_of_remit`.
- R6. The PM closes a `folder_gone` pane only when its PR is merged and its agent is idle, and reports the closure in the Programme view and the journal. In any other case it reports the pane and closes nothing.

**Outside sessions (step 3)**
- R7. Step 3 reads every session the host can list in the domain (herdr: every workspace on the server; Rex: every session; Ghostty: every window) and drops the ones already in the remit.
- R8. For each remaining session the PM states one line: why it is worth adding, or why not. The PM never adds to the remit by itself.
- R9. The Programme view lists the current recommendations at all times.
- R10. One picker opens only when the set of recommended sessions differs from the set last shown. The same set never opens a second picker.

**Cost**
- R11. A sweep where the domain, the remit and all behaviours are unchanged ends as a quiet sweep: the domain scan adds no extra PM turn.

### Key Flows

1. Sweep wakes, `sweep-inputs` reads the domain. If nothing changed, stop (R11).
2. Step 1: answer due PM behaviours.
3. Step 2: take remit sessions in R3 order; close eligible `folder_gone` panes (R6).
4. Step 3: list outside sessions, write recommendations, open a picker if the set changed (R10).
5. Step 4: answer any PM behaviours the new state made due.

### Acceptance Examples

- AE1. Covers R5, R6. Pane w2:pR has a deleted worktree, its PR is merged and its agent is idle. The sweep closes it and the view says so. It never appears as `repo_out_of_remit`.
- AE2. Covers R6. Same pane, but the agent is mid-task. The sweep keeps the pane, flags `folder_gone`, and closes nothing.
- AE3. Covers R7, R10. Workspace w3 holds Peek tabs outside the remit. The first sweep lists them and opens one picker. The next sweep, same set, opens none.
- AE4. Covers R3. One pane waits on Shawn and another is working. The PM acts on the waiting pane first.
- AE5. Covers R11. Nothing changed since the last sweep. The sweep ends in two PM turns.

### Scope Boundaries

- The PM does not add sessions to the remit by itself (R8). The `set-remit` verb still needs Shawn's typed line, and its repo list replaces the old list.
- The "Enforce behaviours" work (PR #145 "make the PM see and answer behaviours that are due", auto 0.16.11) is not redone. This plan builds on it.
- No change to worker behaviours or the claim-checking steps.

### Outstanding Questions

**Deferred to Planning**
- Which of herdr, Rex and Ghostty expose a close-pane call. Where one does not, R6 degrades to report-only. Not yet verified.
- Whether "PR is merged" is read from the programme record, from `gh`, or both.
- What "idle" means per host (herdr agent status, Rex process state, Ghostty foreground process).

### Sources

- `plugins/auto/lib/programme_sources.py` (`_pane_scope`, `propose`; the workspace filter near line 177)
- `plugins/auto/lib/host_herdr.py` `list_panes`; `plugins/auto/lib/terminal_host_capabilities.json` (`list_panes`)
- `plugins/auto/lib/programme_behaviours.py` (`AUDIENCES`), `programme_behaviours_due.py` (`due`)
- `plugins/auto/skills/programme-sweep/SKILL.md` (17 steps), `references/sequencing.md`
- `docs/handoff.md`

---

## Planning Contract

**Product Contract preservation:** restructured, no scope change. Corrected one factual claim: Ghostty's space is a window (not "no space level"), so R7 and the space-naming Key Decision say "window". R-IDs unchanged.

### Key Technical Decisions

- **KTD1. Keep the 17 step numbers; add the four-step spine as a mapping on top.** Tests pin step numbers ("step 11", "step 15", "step 16" in `programme-sweep-packager-skill.test.sh`), and a renumber would break them for no product gain. New work lands as lettered steps: 5b (stage 1), 11b (stage 3), 11c (stage 4). Governs R1.
- **KTD2. The lib computes the order and the lists; the PM only follows them.** `P sweep` adds `order` (remit sessions ranked per R3), `folder_gone`, and `domain` (outside sessions) to its JSON. The PM never ranks by judgement. This keeps the quiet sweep cheap (R11). Governs R3, R5, R7.
- **KTD3. The scan reuses the one host `list_panes` call.** `pane_views` takes a scope flag instead of the workspace filter at `programme_sources.py:177`; no second host call. Governs R7.
- **KTD4. `close_pane` becomes a host capability with a per-host row.** Hosts without a verified close call return `refuse`, and R6 degrades to report-only. The send-guard must class the new close verb (it is "unknown", treated as a send, today). Governs R6.
- **KTD5. "Merged" comes from the programme record first, then `check_mergeable`.** An item's `deliverables.merged` confirmed time counts. `check_mergeable` `ended` also covers CLOSED, so the gate text "already merged" decides. A pane with no item or PR is never closed. Governs R6.
- **KTD6. "Idle" is an explicit allow-list.** Only a status token the plan's discovery step proves means idle counts. Any other or unknown token is "report, do not close". Today only `"working"` is special-cased. Governs R6.
- **KTD7. Recommendations and domain behaviour answers live in programme-level fields, not on an item.** The existing `shown`/`shown_current` fingerprint pattern in `programme_asks.py` is reused, so a changed set re-opens one picker and an unchanged set does not. Governs R2, R9, R10.
- **KTD8. Domain behaviours get one new trigger, `domain`.** It is due when the domain fingerprint changed since the last answer. `due()` today skips PM-only behaviours with no trigger, so this is the first trigger that can reach them. Governs R2.

### High-Level Technical Design

*Directional sketch of the sweep's data flow, not implementation.*

```
P sweep (one host list_panes call)
  ├─ remit panes ──► order[] (rank), folder_gone[], skipped[] (no gone-folder entries)
  └─ other panes ──► domain[] ─► recommendations (fingerprint)
sweep-inputs: + domain_fingerprint, recommendations_changed, domain_behaviours_due
SKILL.md:  5b stage 1 ─► 11 stage 2 (order[]) ─► 11b stage 3 ─► 11c stage 4
```

Step-2 rank (R3, R4), highest first: waiting on Shawn or blocked; unknown state; claiming a merge; idle with work left; working.

### Assumptions

- The PM's own pane and tracker panes are excluded from `domain[]` (existing `role()` returns `pm` and `tracker`).
- `herdr api snapshot` already carries every workspace on the server (`host_herdr.py`); not re-verified here.
- Recommendation reasons are derived from data the sweep already has (cwd repo, title, agent, branch). No extra reads.

### Risks & Dependencies

- **The close verbs are unconfirmed on all three hosts.** `herdr pane --help` and the Rex and AppleScript calls were not run during planning (the auto hook blocks commands that name a pane). U2 starts with that discovery, and R6 degrades to report-only per host if none exists.
- **Closing is not reversible.** KTD5 and KTD6 make every unknown a no-close. The close verb takes a pane id read from this sweep's output only.
- **Step-pinned tests.** `programme-sweep-skill`, `programme-sweep-packager-skill` and `programme-command-shape` pin SKILL.md wording; U6 changes them with the text.

---

## Implementation Units

### U1. Domain scan and ordered remit list

**Goal:** `P sweep` returns the remit sessions in R3 order, flags gone folders, and lists outside sessions.
**Requirements:** R3, R4, R5, R7 (KTD2, KTD3)
**Dependencies:** none
**Files:** `plugins/auto/lib/programme_sources.py`, `plugins/auto/lib/programme_plans.py`, `plugins/auto/tests/unit/programme-sources.test.sh`
**Approach:**
1. In `_pane_scope`, check the folder before the remit-repo test: a missing cwd returns a `folder_gone` result, never `repo_out_of_remit`.
2. Keep a gone-folder pane that owns an item in the proposals/known list; a gone-folder pane with no item goes to a new `folder_gone` list.
3. Add an `order` field per remit session from item state, unread claims and `agent_status`.
4. Make `pane_views` return all workspaces; split remit panes from `domain` panes by workspace.
**Patterns to follow:** `propose()` and `_pane_scope()` return shapes; `skipped` entries `{pane, why}`.
**Test scenarios:**
- Covers AE1. A pane whose cwd was deleted lands in `folder_gone`, never in `skipped` with `repo_out_of_remit`.
- A gone-folder pane that owns an item stays handled as that item.
- Covers AE4. A pane waiting on Shawn sorts before a working pane.
- A pane with an unknown `agent_status` sorts before a working pane (R4).
- Covers AE3. A pane in workspace w3, not in the remit, appears in `domain`.
- The PM pane and tracker pane never appear in `domain`.
- A host `list_panes` refusal returns the existing failure shape, with no `domain` key.
**Verification:** `P sweep` output on a fixture with a deleted worktree has no `repo_out_of_remit` for it.

### U2. `close_pane` host capability

**Goal:** the host interface can close a pane, or says plainly that it cannot.
**Requirements:** R6 (KTD4)
**Dependencies:** none
**Files:** `plugins/auto/lib/terminal_host.py`, `plugins/auto/lib/host_herdr.py`, `plugins/auto/lib/host_rex.py`, `plugins/auto/lib/host_ghostty.py`, `plugins/auto/lib/host_stub.py`, `plugins/auto/lib/terminal_host_capabilities.json`, `plugins/auto/tests/unit/terminal-host-coverage.test.sh`, `plugins/auto/tests/unit/send-guard-hosts.test.sh`
**Approach:**
1. Discover each host's close call from its own help output outside the guarded session (herdr `pane` subcommands, Rex CLI, the Ghostty AppleScript dictionary). Record the result in `terminal_host_capabilities.json` as `native`, `degraded` or `refuse` with `how` and `fix`.
2. Add `close_pane` to `TerminalHost` (default `_unimplemented`) and to `CAPABILITY_OF`.
3. Implement it only on hosts where step 1 found a call. Class the herdr close verb in the send-guard tables.
**Execution note:** Do step 1 first; a host with no close call ships as `refuse` with a `fix:` line.
**Test scenarios:**
- Every host has a `close_pane` capability row (coverage test).
- The stub host close returns `refuse` unless the test selects otherwise.
- The send-guard classes the herdr close verb, not "unknown".
- A host that refuses leaves `close_pane` returning `refuse` with its `fix` text.
**Verification:** `terminal-host-coverage` and `host-wording` tests pass with the new row.

### U3. Close-or-report decision for gone-folder panes

**Goal:** the PM closes an eligible `folder_gone` pane in one verb and reports every other case.
**Requirements:** R5, R6 (KTD4, KTD5, KTD6)
**Dependencies:** U1, U2
**Files:** `plugins/auto/lib/programme_sources.py` (or a new `lib/programme_gone_panes.py`), `plugins/auto/lib/programme_readiness.py`, `plugins/auto/lib/programme_journal.py`, `plugins/auto/tests/unit/programme-gone-panes.test.sh`
**Approach:**
1. A new verb takes a pane id from the current sweep's `folder_gone` list and refuses any other id.
2. Eligibility: PR merged (KTD5), agent idle (KTD6). Any failed or unknown check returns `reported` and closes nothing.
3. On close, journal one row (pane, PR, why) so the Programme view can show it.
**Test scenarios:**
- Covers AE1. Folder gone, merged item PR, idle agent: pane closed, one journal row.
- Covers AE2. Agent working: nothing closed, status `reported`.
- A pane with no item or PR is reported, not closed.
- `check_mergeable` returning `ended` for a CLOSED (not merged) PR does not count as merged.
- An unknown `agent_status` token is reported, not closed.
- A pane id not in the current `folder_gone` list is refused.
- A host whose `close_pane` refuses returns `reported` with the host's `fix`.
**Verification:** the verb's output states closed or reported with the reason, on every path.

### U4. Recommendations: state, view and picker-on-change

**Goal:** outside sessions appear as a list in the Programme view, and one picker opens only when the set changes.
**Requirements:** R8, R9, R10 (KTD7)
**Dependencies:** U1
**Files:** `plugins/auto/lib/programme_home.py`, `plugins/auto/lib/programme_view.py`, `plugins/auto/lib/programme_asks.py` (or a new `lib/programme_recommendations.py`), `plugins/auto/lib/programme_sweep_inputs.py`, `plugins/auto/tests/unit/programme-view.test.sh`, `plugins/auto/tests/integration/programme-sweep-inputs.test.sh`
**Approach:**
1. Add a programme-level `recommendations` field holding the set fingerprint and `shown`.
2. Add a "Recommended for the remit" `_section` to `rows()` in the view.
3. Add a verb to mark the set shown (modelled on `ask-shown`) and a `recommendations_changed` check in `_verdict`.
**Patterns to follow:** `fingerprint`, `shown`, `shown_current` in `programme_asks.py`.
**Test scenarios:**
- Covers AE3. First sweep with an outside session: section lists it and `recommendations_changed` is true.
- After the mark-shown verb with the current fingerprint, the next sweep with the same set is `unchanged`.
- A changed set re-opens exactly one picker.
- A stale fingerprint on the mark-shown verb is refused.
- With no outside sessions the section shows its empty text and the verdict is unaffected.
**Verification:** the view prints the list with one line of reason per session.

### U5. Domain-level PM behaviours (steps 1 and 4)

**Goal:** behaviours aimed at the PM run against the domain and must be answered before the sweep ends.
**Requirements:** R2, R11 (KTD7, KTD8)
**Dependencies:** U1
**Files:** `plugins/auto/lib/programme_behaviours.py`, `plugins/auto/lib/programme_behaviours_due.py`, `plugins/auto/lib/programme_sweep_inputs.py`, `plugins/auto/tests/unit/programme-behaviours-due.test.sh`, `plugins/auto/tests/unit/programme-behaviours.test.sh`
**Approach:**
1. Add the `domain` trigger to `TRIGGERS` and a domain fingerprint from the pane list.
2. Add `domain_due()` over entries whose `applies_to` is `pm` or `both`; keep per-item `due()` unchanged.
3. Store answers at programme level; let `remind-behaviour` and `skip-behaviour` take `--domain` in place of `<item>`.
4. Add `domain_behaviours_due` to `build()` and `_verdict`.
**Test scenarios:**
- A `pm` behaviour with trigger `domain` is due when the domain fingerprint changed since its last answer.
- Answered with `--domain`, it is not due again until the fingerprint changes.
- A `workers`-only behaviour never appears in `domain_due()`.
- Covers AE5. An unchanged domain with all answers recorded keeps the verdict `unchanged`.
- Per-item `due()` output is byte-identical to before for existing fixtures.
**Verification:** `programme-behaviours-due` passes old and new cases.

### U6. SKILL.md spine, digest and vocabulary

**Goal:** the PM reads the four-step spine and the new lists; the vocabulary matches.
**Requirements:** R1, R2, R3, R8, R9 (KTD1)
**Dependencies:** U1, U3, U4, U5
**Files:** `plugins/auto/skills/programme-sweep/SKILL.md`, `plugins/auto/skills/programme-sweep/references/sequencing.md`, `plugins/auto/agents/` (packager agent), `plugins/auto/CONCEPTS.md`, `plugins/auto/tests/unit/programme-sweep-skill.test.sh`, `plugins/auto/tests/unit/programme-sweep-packager-skill.test.sh`, `plugins/auto/tests/unit/vocabulary-audit.test.sh`
**Approach:**
1. Add the four-step mapping near the top of "The sweep" and steps 5b, 11b, 11c without renumbering (KTD1).
2. Update step 5's `repo_out_of_remit` bullet: gone-folder panes come from `folder_gone`, not `skipped`.
3. State the R3 order in step 11 and cite `sequencing.md`; add the gone-folder close verb and the recommendation picker rule.
4. Teach the packager agent the new digest sections.
5. Add "domain" to `CONCEPTS.md` and keep its space definition (window, session, workspace).
**Test scenarios:**
- SKILL.md contains the four stage names in order and the steps 5b, 11b, 11c.
- Existing pins (`step 15`, `step 11`, `step 16`) still pass.
- The skill never tells the PM to add to the remit by itself (R8).
- `vocabulary-audit` accepts "domain".
**Verification:** `bash plugins/auto/tests/run.sh unit` passes.

---

## Verification Contract

- `bash plugins/auto/tests/run.sh unit` and `bash plugins/auto/tests/run.sh all` pass. Run long checks through `~/.claude/tools/honest-run/run.sh` and read its verdict line.
- Version bump moves `plugins/auto/.claude-plugin/plugin.json` and the plugin's entry in `.claude-plugin/marketplace.json` together; `scripts/check-version-bumped.sh` passes. `scripts/publish-plugin.sh` makes the publish commit, separately from the feature commit.
- Manual check: on this programme (herdr workspace w2), `programme.sh sweep` shows no `repo_out_of_remit` for a removed worktree, lists the w3 panes under `domain`, and the Programme view shows the recommendations.

## Definition of Done

- R1 to R11 hold; AE1 to AE5 each have a test.
- `P sweep` on a live programme shows the gone-folder pane and the outside workspace, verified in the real herdr session (not only fixtures).
- Hosts with no close call are recorded `refuse` with a `fix:` line, and R6 reports instead of closing.
- Abandoned-attempt code is removed from the diff.
