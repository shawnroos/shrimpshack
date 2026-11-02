---
title: "feat: Rituals that run a named check themselves"
type: feat
status: revised-after-review-awaiting-pm
date: 2026-11-02
product_contract_source: ce-plan-bootstrap
origin: Shawn's pick (option A, point 3 of docs/ritual-options-note.md)
---

# feat: Rituals that run a named check themselves

This is the second version. The document review (coherence + feasibility, 1 P0, 4 P1) found that the first version's design let a repo's own script run in the sweep. This version removes that. It is tighter on authority than the version the PM approved, but it changes the shape (a new verb, the check re-written inside the plugin), so the PM re-approves it before building.

## Goal Capsule

**Objective.** A ritual can name one check from a short fixed list. A new verb runs due checks and wakes the PM, and Shawn, only when one fails. A passing check adds no model turn to a quiet sweep.

**Shawn's decision.** Checks come from a fixed list. Start with one: "versions bumped". Attaching a check to a ritual needs his typed words naming the check.

**PM answers (still stand).** No live PM means no checks; a missed slot is offered at the next sweep (see Decision D2). A ritual with a check names one remit repo. A pass has no effect on handover and end gates. Recording the shrimpshack ritual with the check is a separate act needing Shawn's typed words.

**Depends on.** PR #192. This branch is stacked on it.

## Authority

| Question | Answer |
|---|---|
| Can a ritual run an arbitrary command? | **No.** A check name maps to a Python function inside the plugin. It runs `git` with fixed argument lists. It never runs a script from the repo, never builds code from names in the repo, and never uses a shell. |
| Why not wrap `scripts/check-version-bumped.sh`? | The script lives in the repo, so a branch could change what runs. It also builds Python source from file names (proved: a directory name with a quote ran code and the script still exited 0). The check is re-written as plain Python; plugin names are data and must match `^[a-z0-9][a-z0-9._-]*$` or the check reports `error`. |
| Who adds a check to the list? | A reviewed code change. |
| Who attaches one to a ritual? | Shawn's typed words naming the check (`record-ritual --check versions-bumped` requires the prompt to name `versions bumped`). `propose-ritual --check` stores a proposal and runs nothing. No verb attaches a check to an existing ritual in v1 (retire and record again). |
| Where may a check be set? | Programme and repo layers only. Refused on the personal layer. On a repo-layer ritual the repo is the entry's own `repo_key`. On the programme layer the record stores a concrete remit repo key (defaulted when the remit has one repo) and never resolves a default at run time. |
| Does moving a ritual carry its check? | `move-ritual` and `keep-rituals` on an entry with a check also require the prompt to name the check. |
| Validation | Inside `_validate`, the one function every load path uses, so a hand-edited store, a programme block or a later repo file is checked the same way. |

## What the first check answers (needs the PM's yes: Decision D1)

"For each plugin under `plugins/` on the named ref (default `origin/main`, never the checked-out `HEAD`): did shipped files change since the last commit that changed that plugin's version in both `plugin.json` and `marketplace.json`, with no bump since?"

- It reads history of a named ref, so it does not depend on which branch is checked out.
- It never runs `git fetch` (no network from a sweep). The result states the ref's commit and the age of the ref, so a stale clone is visible.
- **Pass needs proof.** `pass` only when the ref resolved, `plugins/` exists, the marketplace file parsed, and at least one plugin was checked. Anything else is `error` (a repo without `plugins/`, git missing, not a repo, base not found). A pass row journals the counts (plugins checked, changed).
- "Shipped files" uses the same path rules as `scripts/check-version-bumped.sh`; the unit tests copy its cases.

## Design

1. **Entry field.** `check: {name, repo_key?, base?}` with flags `--check`, `--check-repo`, `--check-base`. `base` matches a ref pattern, may not contain `..`, and is verified with `git rev-parse --verify --end-of-options <base>^{commit}` at run time.
2. **Runner module** `lib/programme_ritual_checks.py`: registry `RITUAL_CHECKS`, one function per check, structured result `{result: pass|fail|error, reason (fixed list), counts, plugins (name-checked), ref_sha, ref_age}`. Git runs through the existing bounded-child helper, extended with optional `cwd`, `env` and `max_bytes` (default behaviour unchanged). Environment: `PATH` of absolute system folders only, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`. The remit path must be an absolute existing folder.
3. **Run site: a new verb `run-ritual-checks`**, chained in step 1 of the sweep just before `sweep-inputs --save`. `sweep-inputs` stays a read verb that journals nothing. The verb: finds due (and, per D2, missed) calendar rituals with a check; runs each check **outside the programme lock**; for a pass, takes the write path and **re-checks under the lock** that the ritual is still due for the same slot, then moves the clock and journals; for fail or error, appends the journal row and leaves the ritual due. A caller that is not the driver, or a refused write, leaves the ritual due and untouched. A per-ritual error never hides other rituals.
4. **Budget.** 30 seconds per check, 90 seconds per sweep. Checks left over stay due with no row and show in the digest.
5. **Once per slot.** A check runs at most once per (ritual, `pending_at`). A failing check does not re-run and re-journal each sweep; a human can re-run it with `run-ritual-checks --ritual <id>` (read-only, no typed words).
6. **Journal.** New kind `ritual_checked` in `programme_journal.KINDS`, payload = the structured result plus `pending_at`. Quiet only when `result == pass` (listed in the sweep's quiet bookkeeping, and not resetting the `quiet` trigger). The sweep reloads the record and journal after the checks and then builds `rituals`, so a pass is not read as still due in the same sweep.
7. **What the PM sees on failure.** A digest line built from the structured fields (`reason`, counts, plugin names that passed the name pattern). The raw git output is **not** put in the digest, so repo text cannot instruct the PM. The ritual's steps and offers appear with it.
8. **Calendar rituals only in v1.** Event rituals run at programme moments and need the PM anyway.
9. **Programme view.** Last result, time and ref age, read from the journal rows. A rejected ritual count shows (an older plugin copy rejects the `check` key and the daily check silently stops there; stated in the contract doc).

## Units (sequential)

| Unit | What | Tests (red first) |
|---|---|---|
| C1 | `check` field in `_validate`; `--check`, `--check-repo`, `--check-base` on `propose-ritual`/`record-ritual`; `require_named` for the check name; layer rules; `programme_journal.KINDS` gets `ritual_checked` | unknown name, unknown key, `..` in base, check on personal layer, event ritual with check: all refused at record **and at load of a hand-edited store**; "versions bumped" in typed words matches `versions-bumped`; a prompt that does not name the check is refused; move/keep need the check named |
| C2 | `programme_ritual_checks.py` and the extended bounded-child helper | table of the reviewer's cases, each must be `error` not pass: not a repo, base missing, git missing, no `plugins/`, marketplace unparseable, git "dubious ownership", zero plugins; a directory name with a quote creates nothing and reports `error`; a repo shipping its own `scripts/check-version-bumped.sh` is never executed; on `main` with an unbumped commit fails, with a bump passes; hang times out as `error`; per-ritual exception stays local |
| C3 | `run-ritual-checks` verb; sweep skill step 1 and quiet paragraph; quiet bookkeeping lists; once-per-slot; budget | the real quiet path from `programme-sweep-inputs.test.sh` (set idle, chain, second sweep-inputs) with a passing check gives `verdict == unchanged` twice; a failing check shows in the digest once and does not re-run on the next sweep; refused write leaves the ritual due; lock is not held during a 5-second check; a missed calendar ritual is checked (D2) |
| C4 | Programme view; docs: `programme-rituals-format.md`, `run-record-schema.md`, `agent-tool-surface.md`, the packager agent text, `programme-verbs` list; skill and sweep reference text | skill test; docs name the fixed list, "a check that cannot run is an error", and old-copy behaviour |

Plugin version bump: the version check this plan adds would fail on this PR too. The bump and publish are left to the PM, as in #192.

## Decisions for the PM (D1, D2)

- **D1. What the first check asks.** Proposed above: history of `origin/main` per plugin, no fetch, ref age shown. Alternative: only changes in the last N days. Recommendation: as proposed.
- **D2. Missed slots.** A slot becomes "missed" after 2 hours without a sweep. Proposed: the verb still runs a missed calendar ritual's check (it is read-only and cannot do harm), moves the clock on a pass and journals it as checked late, and only a fail goes to Shawn. This differs from the earlier answer "a missed one is offered at the next sweep" for the pass case: Shawn would otherwise be asked a question after every laptop sleep. Recommendation: as proposed.

## Risks

| Risk | Mitigation |
|---|---|
| A pass without running | positive-proof rule; every non-completion is `error` |
| List becomes a back door | name maps to plugin code; no repo script, no shell, no free text |
| Repo text reaches the PM | structured digest only |
| Sweep gets slower or killed | budget; verb outside the lock; test for lock not held |
| Older plugin copies drop the ritual | stated in the contract doc; rejected count in the view |
