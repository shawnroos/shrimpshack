# One issue in full

`bin/work-issue.sh <issue-id>` prints one JSON document with everything the
board's issue page shows: the issue itself, its description, its sub-issues, its
parent and relations, its comment thread and its history. The board daemon runs
it when a reader opens an issue page; an agent in a session can run the same
script.

It is deliberately **one Linear call**. Every paged connection is asked for once
at `HERDR_LINEAR_DETAIL_PAGE_SIZE` (50) and never drained: what did not fit is
named in `truncated` and the status becomes `partial`. An issue with a thousand
comments therefore costs the same as one with none, which is what keeps the read
inside the daemon's per-call deadline.

## Rules that hold for every document

- `schema` is `1`. A reader refuses any other value.
- **An absent key never means null.** `schema`, `status`, `message`, `issue` and
  `truncated` are present in every document. Inside `issue`, every key below is
  present: a property Linear has no value for is `null`, and a connection with no
  rows is `[]`.
- `status` carries the read's own outcome. Exit 0 means a document was printed,
  never that Linear answered.
- Every string that came from Linear has display controls stripped (the codepoint
  table of `HERDR_LINEAR_SANITIZE_JQ_DEF` in `lib/sanitize.sh`) before it is
  printed.
- Keys are sorted; rows keep Linear's own order.

## Exit codes

| Exit | Meaning | stdout |
|---|---|---|
| 0 | a document was printed | the document |
| 2 | the argument was refused (empty, or not `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`) | empty |
| other | the script crashed | empty |

A reachability failure is **not** an exit code: Linear being down, rate limiting,
or refusing the credential each print a document with `status: "unavailable"` and
`issue: null`, so a reader can tell "this issue could not be read" from "this
script is missing" — which the board needs, because the two have different
remedies.

## Status

| `status` | Meaning |
|---|---|
| `ok` | the issue was read whole |
| `partial` | the issue was read; at least one connection stopped at its page cap, and `truncated` names which |
| `unavailable` | Linear could not be read: no credential, a refused credential, an unreachable API, rate limiting, or no such issue. `message` says which |
| `unknown` | the read ended without an answer this script recognises |

## The document

```json
{
  "schema": 1,
  "status": "ok",
  "message": null,
  "truncated": [],
  "issue": {
    "id": "…", "identifier": "WEB-3308", "title": "…", "url": "…",
    "description": "markdown, or null",
    "updated_at": "…", "due_date": "2026-09-30", "estimate": 3, "priority": 2,
    "state":     {"id": "…", "name": "In Progress", "type": "started"},
    "assignee":  {"id": "…", "name": "…"},
    "labels":    ["Bug"],
    "project":   {"id": "…", "name": "…"},
    "milestone": {"id": "…", "name": "M2"},
    "cycle":     {"id": "…", "number": 14, "name": "Cycle 14"},
    "parent":    {"id": "…", "identifier": "WEB-2670", "title": "…", "state": {…}},
    "children":  [{"id": "…", "identifier": "…", "title": "…", "state": {…}}],
    "relations": [{"type": "blocks", "direction": "outward", "issue": {…}}],
    "comments":  [{"id": "…", "body": "…", "created_at": "…", "author": "…", "parent_id": null}],
    "history":   [{"id": "…", "created_at": "…", "actor": "…",
                   "from_state": "Backlog", "to_state": "In Progress",
                   "from_assignee": null, "to_assignee": null,
                   "from_priority": null, "to_priority": null,
                   "added_labels": [], "removed_labels": []}]
  }
}
```

### Rules a reader can rely on

- **Every linked issue row — `parent`, each `children` row, each `relations`
  row's `issue` — carries `id`, `identifier`, `title` and `state`.** That is the
  minimum the board needs to open that issue's own page from the row alone,
  without a second read.
- **`relations` carries both directions.** `direction: "outward"` is what this
  issue points at, `"inward"` what points at it; `type` is Linear's own
  (`blocks`, `related`, `duplicate`). Linear draws both on one page, so both are
  read, and the direction is what separates "blocks" from "blocked by".
- **A comment reply names its parent** in `parent_id`; a thread root has `null`.
- **`history` carries only rows that changed something in this document.** Linear
  returns history for fields the board does not show, and such a row has nothing
  a timeline could phrase.
- **`truncated`** holds any of `children`, `relations`, `comments`, `history`.
  Its presence is what makes the status `partial`.

## Testing

`tests/unit/issue-detail.bats` covers the full, empty and truncated shapes, the
refused argument, and each reachability failure. Nothing reaches Linear: the
detail query is answered by `tests/fixtures/fake-linear.sh`, which routes on
`inverseRelations` and prunes its reply to the fields the query selected, so a
field dropped from the query disappears from the answer too.
