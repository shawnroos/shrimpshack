---
title: "Reordering writes across files with no transaction only chooses which inconsistency a crash leaves"
date: 2026-10-29
category: logic-errors
module: plugins/auto
problem_type: logic_error
component: tooling
symptoms:
  - "successive review rounds each found a new crash window in programme_authority._legacy_write and programme_carryover._carry on legacy JSON programme homes"
  - "a crash after the approval row left a spent prompt with no Ruling change"
  - "a crash after the journal append left a journal row with no matching run-record state"
  - "a lost proposal row let an older prompt approve a Ruling change"
  - "each fix reordered the journal, run-record and carry-over writes, and each new order opened the next window"
root_cause: data_integrity
resolution_type: code_fix
severity: high
tags: [programme, legacy-json-home, crash-consistency, multi-file-write, sqlite-transaction, promote-first, write-ordering, carry-over]
---

# Reordering writes across files with no transaction only chooses which inconsistency a crash leaves

## Problem

A programme home in `plugins/auto` that still lives on the old JSON files keeps its state in three separate files: the journal, the run record, and the carry-over store. No transaction covers them. A Ruling change must write to more than one of them: the record gets the change, the journal gets the approval row that cites Shawn's typed prompt, and `carry-rulings` also writes the carry-over store.

The approval checks read the journal. They ask whether the prompt is the newest one, whether it was typed after the change it approves, and whether it has already approved another Ruling change. So any crash that leaves the journal and the record out of step changes what those checks see next time.

Review rounds 5 to 8 on branch `feature/agreement-consolidation` (the numbering comes from the session's review history; the commits do not carry it) each found a new crash or ordering window in `programme_authority._legacy_write` and `programme_carryover._carry`. Each fix reordered the writes, and each new order opened the next window.

## Symptoms

Each ordering left a different inconsistency after a crash or a race. The commit trail on the branch is below. As of this writing the branch is unmerged and has no PR. A squash merge will rewrite these SHAs, so each one is quoted with its commit subject, which still finds it in the PR history.

| Commit | Legacy write order | What a crash or race left |
|---|---|---|
| before 95366147 (as of 2402e3c8, "approve a Ruling change only with a fresh, unused typed prompt") | Record under the run lock. The approval row was appended after the lock was released. `carry-rulings` wrote the store, then one `rule_adopted` row per entry, then a `rulings_carried` row. | A second writer could check the journal in the gap and see the prompt as unused. A crash left a Ruling change with no approval row, so the spent prompt looked unused. A carry cut off before its `rule_adopted` rows left store entries that pre-fill drops. |
| 95366147 ("run Ruling approval checks under the write lock") | Approval row appended inside the run lock, after the record write. | A typed prompt was appended under the journal lock only, so it could land between a writer's "newest prompt" check and its row (the fix in 48397197 says so). A crash between record and row still left a change with no row. |
| 48397197 ("serialize legacy prompts with Ruling writes; make a carry one approval") | Prompts wait up to 2s for the run lock. The single `rulings_carried` row became the approval for every stored entry. | The carry still wrote the store inside its change, before the row. A carry refused or cut off at the row left store entries behind (206b04a3 moves the store write after the row for this reason). A prompt whose run-lock wait timed out was still journaled without the lock. |
| 206b04a3 ("recheck a Ruling approval under the journal lock before it applies") | Every row journaled first, re-checked under the journal lock, then the record, then the store. | A crash after the row left **a spent prompt with no change**. The commit's own comment accepts this: "a refused or crashed approval leaves at worst a used prompt". Because every row went first, a crash also left **a journal row with no record state**. A carry cut off after its row lost its store entries. |
| b63441c9 ("journal only approvals first; rebuild the carry store from its approval row") | Approval rows first; every other row after its record again. | A proposal and a prompt-less close change a Ruling but are not approvals, so they went record-first. A crash lost the row, and the journal no longer showed the newest change. **An older prompt then passed "typed after the change it approves".** The comment on `changes_ruling`, added in 2b0d42f9, names these two row kinds. |

The commit message of 2b0d42f9 ("move a legacy programme to programme.db before any Ruling change") states the conclusion: "each reordering of their writes only moved the crash window."

## What Didn't Work

- **Reordering the writes.** Five orders in a row each closed the window the last review found and opened another one. This cannot converge. With N files and no transaction, a crash after write k leaves writes 1 to k on disk. An order only chooses *which* partial state a crash can leave. Here the checks pull in opposite directions. The approval row must come first, or a crash leaves a change with no approval. The record must come first, or a crash leaves a row whose state the record lacks. No order satisfies both.
- **Splitting the rule by row kind.** b63441c9 sent approvals first and everything else record-first. That only moved the window to the row kinds the split classed wrongly (proposals, prompt-less closes). This is an enumeration fix: it lists the safe forms and leaks on the ones it missed ("enumeration fixes never close a class" (auto memory [claude])).
- **Adding locks and rechecks.** Waiting for the run lock (48397197) and rechecking under the journal lock (206b04a3) close races between live writers. They do nothing for a crash, because a crash happens with the lock held.
- **Promoting before the checks.** The first upgrade-first version (2b0d42f9) moved the home at the start of the verb: `upgrade_legacy` ran before `authority.write` in `_carry` and in `_write` when `ruling=True`. A verb that its own checks would refuse (an unknown id, a session that does not drive the programme, a prompt that does not name the id) still moved the home. The move is one-way, and it turns every prompt on the home into an imported one that approves nothing new. So a typo cost a move and a re-typed prompt. 86d63455 ("keep JSON-home approvals across the move; move only for a change that applies") fixed this.

## Solution

Stop ordering writes on the JSON home. Before a Ruling change, move the home to `programme.db`, which has real transactions, through the existing `programme_import.promote` (`plugins/auto/lib/programme_import.py:339`). Do the move only after the verb's own checks pass. This was Shawn's choice ("upgrade first"). The behaviour is in `plugins/auto/docs/contracts/programme-durability.md` §7 (L212-224) and in the "promotion" entry of `plugins/auto/CONCEPTS.md:74`. This doc does not repeat it.

The mechanism has three parts.

1. `_legacy_write` runs the verb's `change` first, so every check runs. It refuses a Ruling row only after that, and before the record write (`plugins/auto/lib/programme_authority.py:267-283`):

```python
def staged(record):
    result = change(record)
    seen["row"] = compose(result, record) if compose else None
    if seen["row"] is not None and legacy_refuses is not None and legacy_refuses(seen["row"]):
        raise legacy_refusal(run_id, seen["row"]["kind"])
    return result
```

   `legacy_refuses` is `programme_rulings.changes_ruling` (`plugins/auto/lib/programme_rulings.py:115-119`). It matches every Ruling-changing row, proposals and `rulings_carried` included, not only approvals. The refusal carries the code `legacy_ruling` (`programme_authority.py:256-259`).

2. `programme.promoting` catches only that code, promotes, and runs the whole verb again on the moved home (`plugins/auto/lib/programme.py:279-288`):

```python
def promoting(run_id, home, verb, attempt):
    try:
        return attempt()
    except programme_authority.AuthorityError as exc:
        if exc.code != programme_authority.LEGACY_RULING:
            raise
    upgrade_legacy(run_id, home, verb)
    return attempt()
```

   `upgrade_legacy` (`programme.py:267-276`) refuses with the import's reason, changing nothing, when the move declines or fails. `_carry` wraps its write in `promoting` (`plugins/auto/lib/programme_carryover.py:348-351`).

3. Every other row on a legacy home still follows its record under the run lock. A crash there leaves at worst a record change with no row (`programme_authority.py:262-266`). No approval check reads that gap.

### Follow-on 1: past adoptions must survive the move

Promotion stamps every imported row with provenance `legacy_import` (`programme_import.py:68`, `:79`, `:189`; `programme_authority.py:166`). An imported prompt is unverified, so it approves nothing new (`plugins/auto/lib/programme_approval.py:168-171`). In 2b0d42f9 that same stamp also stopped past adoptions from verifying: a behaviour, protocol rule or carry entry that Shawn approved on the JSON home fell out of force after the move.

86d63455 separates the two readers:

- `programme_journal.adopted_origin` (`plugins/auto/lib/programme_journal.py:369-375`) reads an imported prompt as the JSON home did, for past approvals only. New approvals still read `prompt_origin` (`:361-366`), which refuses it.
- `programme_approval._approved` (`programme_approval.py:46-61`) lets an imported prompt count only the approval rows imported with it: `imported and row.get("provenance") != programme_authority.LEGACY` skips the rest. `prompt_lookup` (`:64-81`) passes `imported` and uses `adopted_origin`.

### Follow-on 2: the carry-over store is a cache of one atomic row

The store is a separate file, even on a promoted home, so a crash can still fall between the `rulings_carried` row and the store write. b63441c9 removed that window by making the row the source of truth. The row holds the full adopted entries (`programme_carryover.py:343-346`). `_refill` (`programme_carryover.py:231-252`), called from `prefill` (`:255-259`), writes any entry that verifies from its row and is missing from the store. It never overwrites a newer carry, and it never stores an entry twice (`_missing`, `:225-229`). The comment on `_carry` (`:321-324`) records this: "the store is a cache of those rows, which pre-fill refills".

## Why This Works

`programme.db` commits the record change and its journal row in one transaction, so a crash leaves either both or neither. There is no partial state for the approval checks to misread. Ordering stops mattering because there is only one write.

Promoting after the checks matters for two reasons. The move is one-way, and it spends every prompt on the home. A verb that would refuse must therefore refuse on the JSON files and leave them byte-identical. And the retry runs every check again on the moved home. A prompt typed before the move is now imported, so it is refused there. The JSON home never takes the change.

The carry store is safe for a different reason. It is not made atomic; it is made disposable. Losing it after the row costs nothing, because the next pre-fill rebuilds it from the row.

## Prevention

- **Rule:** when state spans several files with no transaction, and review after review finds a new crash window after each reorder, stop reordering. Move the write onto a store with a transaction. Or keep one atomic row as the truth and make the other files caches rebuilt from it. Two reorder fixes in a row on the same write path is the signal ("round2 review catches fix induced regressions" (auto memory [claude])).
- **Rule:** an irreversible migration that a verb triggers must run after the verb's own checks, never before. A verb its checks refuse must leave the old home untouched.
- **Rule:** when a migration re-stamps provenance to block new use, check every reader of that stamp. Past approvals and new approvals need different answers.
- **Tests that keep this from regressing:**
  - `plugins/auto/tests/unit/programme-legacy-move.test.sh`: "legacy: close-ruling of an unknown id refuses, does not move the home, and changes nothing"; "legacy: record-ruling from a session that does not drive the programme refuses and changes nothing"; "legacy: record-ruling citing a prompt that does not name the id refuses without moving; only the refusal is journaled"; "after a Ruling verb moved the home the behaviour, the protocol rule and the carry-over entry are still in force"; "a new adoption citing a prompt typed before the move is still refused"; "an imported prompt verifies only the approvals imported with it"; "a move cut off after its marker and before its commit: the next Ruling verb redoes the move and applies".
  - `plugins/auto/tests/unit/programme-carryover.test.sh`: the `heal_case` cases (defined at L596, run at L629-630), including "(each case) (put): the next programme's pre-fill refills the store from the row and brings the Ruling in" and "a second pre-fill stores nothing twice"; "a refill never overwrites a later carry of the same Ruling"; "a refill skips an adopted entry its row does not approve: nothing is stored or carried"; "legacy, promotion declined: carry-rulings runs its checks on the JSON files, refuses the move, home and store byte-identical"; "legacy, promotion reporting success without moving: the legacy write refuses the rulings_carried row, store unchanged".
  - `plugins/auto/tests/unit/programme-rulings.test.sh`: "legacy: a record-ruling with no prompt moves the home to programme.db, then records the proposal there"; "legacy: a record-ruling citing a prompt typed before the move moves the home, then refuses that prompt"; "legacy: a prompt-less close-ruling of a grant moves the home and closes it there as a promoted run does"; "legacy: accept-context of a requirement is not a Ruling change and keeps the JSON files"; "legacy: a blocker_raised killed just before its row lands leaves only the record change".

## Related Issues

- `docs/solutions/logic-errors/a-routing-decision-made-before-the-lock-must-be-rechecked-under-it.md`: the other half of the legacy-home problem. It covers a writer that picks the JSON path just before `promote` runs. This doc removes the JSON path for Ruling changes entirely.
- `docs/solutions/best-practices/a-refusal-log-and-a-writes-nothing-test-must-be-reconciled-not-picked.md`: defines "a refused verb writes nothing", which promoting only after the checks keeps.
- `docs/solutions/logic-errors/a-clean-git-status-does-not-prove-a-worktree-is-safe-to-remove.md`: the same pattern in another area. Each review round found a new hole until the fix changed class.
