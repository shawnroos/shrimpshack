# Programme durability

This document says what a programme keeps when a process stops, what it does
not keep, and what you must do before you rely on it. It describes the code as
it is. Each statement names a verb or a file so you can check it.

## 1. What is kept

A programme home is `<data>/programmes/<run>/`. The data folder is
`~/.claude/plugins/data/auto-shrimpshack` unless `CLAUDE_AUTO_DATA_DIR` names
another one.

| Object | Where | Role |
| --- | --- | --- |
| Programme database | `<home>/programme.db` | The only authority. It holds the record, the journal rows, the claims, the decisions, the requirements, the operations and the archive seal. Each write is one SQLite transaction with a new revision. |
| Retained objects | `<home>/artifacts/objects/` | Worker results, source extracts and code bundles, named by their sha256. The database refers to an object only after the object is written. |
| Leases | `<data>/programmes/leases/*.json` | An index of which programme holds which herdr space. It is not a second record. `reconcile-leases` rebuilds it from the database. |
| Exports | `<home>/.claude/auto/<run>.json`, `journal.jsonl`, `claims.jsonl` | Copies rebuilt after each commit and tagged with their revision. No reader takes them as state. |
| View | `<home>/views/view.json` | A copy of the working model for the programme-view mod. `status` writes it again when it is missing and the programme is active. |
| Archive manifest | a retained object named by the seal | The final record of outcomes, dispositions and retained objects. |

## 2. Failure model

The tests prove these results when a process is killed at named points
(SIGKILL), on one Mac, with one user.

- A write that returned success is in the database after a restart.
- A write that did not finish leaves no part of itself. A retry with the same
  `--op <id>` returns the first result and writes nothing twice.
- A worker launch or a pane prompt is recorded before it runs and settled after.
  If the process stops between the two, the action stays "uncertain". A retry
  on the same item refuses until `reconcile-operations` settles it, or the PM
  retries with `--despite <attempt>`.
- A database that is missing, damaged or written by a newer version is a hold.
  Every reader reports the hold. No reader falls back to an export, and no
  reader shows an empty programme.
- A missing retained object is a hold on its item. Dispatch for that item
  refuses, and an archive refuses.
- A sealed archive is read-only. Every write, export, view refresh, prune and
  import refuses. A database with an unfinished SQLite journal after the seal is
  a hold; nothing repairs it in place.

### Process kill and power loss are different

The tests stop processes. They do not cut power. The database runs with
`journal_mode=delete`, `synchronous=EXTRA` and `fullfsync=1`, and each
connection reads these settings back and refuses to write if they are wrong.
That makes SQLite ask the disk to flush. It does not prove that the disk does
it. After a power loss, the last acknowledged writes are as safe as the
filesystem and the drive make them. Machine loss, disk damage and changes by
another process of the same user are outside this model. Checksums find
damage; they do not stop a same-user process.

## 3. Restoring context

A new session, a compaction, a handover and a takeover restore the PM's context
from the database, not from the old chat.

- SessionStart (in the driving session), the compact refusal, `rules` and
  `takeover` print one block: the rules in force and an `<auto-context>` block.
  The block holds the decisions with their reasons and limits, the requirements,
  acceptance, blockers, binding pauses and denials, pending questions,
  assignments, open items and uncertain actions. It names the store revision and
  a context digest.
- Long text is cut and keeps its id. `recover --get <id>` prints the full entry.
  `recover` prints the whole packet and re-reads every retained result.
- PreCompact, and `handover` for the new driver, set `<home>/.compact-flag` with
  the context digest. Write verbs refuse until `rules --ack`. An ack whose digest
  is older than the committed context refuses, prints the new block, and binds
  the flag to it.
- An ack means "context read". It accepts no agreement, decision or
  requirement.
- Restored text is context, not approval. Restoring writes no prompt row, so
  nothing in the block can be cited as a typed prompt.

### What hooks can see

The hook shell scripts start Python only when a cheap file test passes. This
keeps a session with no programme fast.

| Hook | Python runs when |
| --- | --- |
| SessionStart | the folder has a repo with `.claude/auto`, or a lease file or a closing entry names the session |
| PreCompact | a lease file names the session |
| UserPromptSubmit | a lease file or a closing entry names the session, or the prompt is a programme takeover, handover or end request |
| Stop | the folder has a repo with `.claude/auto`, or a lease file names the session |

A programme whose lease file is gone is not seen by PreCompact, the prompt hook
or Stop. SessionStart reports it ("no lease file names the run") only when its
gate passes for another reason. Run `programme.sh reconcile-leases --run <run>`
to write the lease again. The hooks do not scan homes, because homes are never
deleted and a scan would run Python in every session.

A takeover, handover or end request that the prompt hook cannot journal (for
example, the programme's database is damaged) is reported back to the session.
The verb then refuses, because it finds no request.

## 4. Retention

Nothing is deleted automatically.

- Retained objects, staging, archives, closing entries and old exports stay
  until a person removes them.
- `prune` hides old uncited prompts. Their bytes stay in `programme.db`, because
  events are never rewritten.
- A preservation receipt says what was captured. It is not permission to delete
  the source. Remove a worker's worktree only after
  `preserve-code --source <worktree> --check` says the receipt still covers it.

## 5. Source verification

The approval-origin verifier is not installed. Until it is:

- Every decision revision, retained result and disposition records
  `origin_verified: false`.
- A typed prompt is still checked as before (typed origin, driving session, not
  imported, and the text names what it approves). That check does not prove a
  human typed it.
- A retained or restored copy approves nothing. A use that needs a verified
  human source refuses, and the source is kept.

## 6. What capture does not support

`collect-result` and `preserve-code` refuse these cases. A refusal is recorded,
nothing is written, and the source is kept.

| Case | Result |
| --- | --- |
| A payload over 8 MiB | refused as unsupported. A code bundle holds the full history, so most real worktrees are over this limit today. |
| Binary or compressed bytes in a result | refused by `collect-result`. Code capture admits clean binary files and refuses compressed ones (gzip, zip, zstd, xz, bzip2, 7z, zlib). |
| Text that looks like a secret, or a value from the secrets file | prohibited |
| Git LFS pointers | unsupported |
| Submodules and nested repositories | unsupported |
| Shallow history, alternates, partial clones, promisor packs | unsupported |
| Git lock files, or a source that changes during capture | quiescence uncertain |

Restore does not rewrite `MERGE_HEAD`.

## 7. Before you move a live programme to the database

A programme made before this version keeps its JSON files until
`programme.sh promote --run <run>` imports it. Check these first:

1. **Remove the old plugin version.** Old code can still write the JSON
   export after promotion and report success. The next database write finds it,
   renames the changed export aside and records a gap, but it does not stop it.
   Promote only when no session runs the old version.
2. **Check the secrets file.** Every write refuses if any value of six or more
   characters from the secrets file (`~/.secrets`, or
   `CLAUDE_AUTO_SECRETS_FILE`) appears anywhere in the record. A non-secret
   value such as a user name can block every write. Remove such values from
   the secrets file or from the record first.
3. **Expect a declined import to change nothing.** `promote` refuses content it
   cannot classify and leaves every input untouched.

Imported prompts carry `provenance: legacy_import` and approve nothing new.
