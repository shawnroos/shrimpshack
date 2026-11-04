# Worker contracts: progress and done

For a worker that runs under a contract, read its progress from its run record. Never scrape its pane.

## Each sweep

1. When `why` has `contract_changed`, `worker_question_due` or `contract_status_unreadable`, run `P contract-status`. `P contract-status <item>` reads one item.
2. Read each item's `state`:
   - `contract`: the worker's run record is read. `steps`, `exit_predicate` (the cached one), `last_beat_at`, `version`, `applied_version`, `pending_versions` and `stale` say where it is and whether it has read your last change. `stale: true` means the worker has not yet read the latest version.
   - `no contract`: a hand-driven worker. Use the pane as before.
   - `unresolvable`: the run record is missing or moved. Say so in one line, ask the worker to run `register-run` again if it moved, and do not scrape its pane.
   - `launched`: the worker has not registered its run yet.
3. A worker's claim of done, or `exit_predicate.met: true`, is not evidence. An item counts as done only when `counts_as_done` is true. When `unverified_external` lists `pr_merged` or `ci_green`, run `P check-deliverable <item> merged` yourself. Until it confirms, the item is not done, whatever the worker says.
4. `questions` holds the open worker questions and the oldest one's age. Handle them as in [worker-questions.md](worker-questions.md).

## Quiet sweep

A contracted item whose version, last beat, record mtime, open-question count and oldest question are unchanged since the last sweep adds no reason. A change in any of them adds `contract_changed`. A question past its limit adds `worker_question_due` even when nothing else moved, until `P escalate-worker-questions` has raised it.
