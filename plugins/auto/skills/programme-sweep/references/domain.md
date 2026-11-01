# The domain stages

The sweep's four stages, and the rules for the three steps that have no number of their own: 5b, 11b and 11c.
"Domain" means every agent session in every space the terminal host lists, in the remit or not.

| Stage | What the PM does | Steps |
| --- | --- | --- |
| 1. Domain check | Answer the PM behaviours owed because the domain changed | 1 to 5, then 5b |
| 2. Remit sessions | Work the sessions in the remit, most urgent first | 6 to 11 |
| 3. Outside sessions | Recommend which outside sessions to add. Never add one | 11b |
| 4. Domain check again | Answer the PM behaviours the new state made due | 11c, then 12 to 17 |

## 5b. Domain check (stage 1)

The digest's "Behaviours due on the domain" section lists each PM behaviour (audience `pm` or `both`, trigger
`domain`) owed because the set of sessions in the domain changed. Apply each one yourself, then run
`P answer-domain-behaviour <behaviour-id> --as applied_by_pm --why "<what you did>"`, or `--as skipped --why
"<one line>"` when its PM checks do not hold. The sweep stays open until that list is empty.

## Step 11: order and gone folders (stage 2)

- Take the remit sessions in the order of `order` in the `P sweep` output. The order is computed, so do not
  re-rank it: rank 0 `needs_shawn` (waiting on Shawn, or the agent is blocked), then `unknown_state`,
  `claims_merge`, `idle` (idle with work left) and `working` (leave it alone). Shawn's time comes first for the
  reason in section 1 of [sequencing.md](sequencing.md).
- For each pane in `folder_gone` (a live pane whose folder was removed, never `repo_out_of_remit`), run
  `P close-gone-pane <pane>`. It closes the pane only when the folder is gone, the item's PR is merged and the
  agent is idle, and prints `closed` or `reported` with the reason. A `reported` pane stays in the sweep. Mention
  it in chat only when the verb printed a `fix:` line for Shawn. Never close a pane by any other command.

## 11b. Outside sessions (stage 3)

`domain` in the `P sweep` output lists the agent sessions outside the remit; the digest shows them under "Outside
sessions" and the Programme view under "Recommended for the remit", each with a reason. You only recommend. Adding
one takes Shawn's typed line through the `auto:programme-remit` skill, and its repos list replaces the old list.

When `why` has `recommendations_not_shown`, post the list once in one AskUserQuestion picker with two options, "Add
some (I will type the repos)" and "Leave the remit as it is", then run `P recommendations-shown --fingerprint
<fingerprint>`. The same set never asks again; a changed set asks once.

## 11c. Domain check again (stage 4)

Steps 11 and 11b can change the domain (a pane closed, a session added). Run `P sweep --record-sources` and
`P sweep-inputs --save` again. If `why` has `domain_behaviours_due`, repeat step 5b.
