# The space snapshot

`bin/work-snapshot.sh <workspace-id>` prints one JSON document that describes a
herdr space as this plugin sees it: the workspace record, the Linear project
and view it names, the issues the view admits, and the worktrees, tabs and
panes bound to those issues. The board daemon runs it; an agent in a session
can run the same script, so both see the same document.

The canonical documents live in `tests/fixtures/snapshot/`. The board vendors
copies with a sha256 per file (`crates/board-core/tests/fixtures/linear-snapshot/VERSION`),
and both suites check the hashes, so the contract cannot drift on one side
without a failing test on the other.

## Rules that hold for every document

- `schema` is `1`. A reader refuses any other value.
- **An absent key never means null.** Every top-level key is present in every
  document: `schema`, `workspace`, `mapping`, `record`, `project`, `view`,
  `linear`, `herdr`, `groups`, `issues`, `unmapped`. A chosen-none view is
  `view.status: "none"` with `id`, `name` and `layout` set to `null`, never a
  missing `view`.
- Every source carries its own `status`. Exit 0 means a document was printed,
  never that every source was reachable. A reader renders a partial document
  as partial.
- Every string that came from Linear or herdr has display controls stripped
  (the codepoint table of `HERDR_LINEAR_SANITIZE_JQ_DEF` in `lib/sanitize.sh`)
  before it is printed.
- Keys are sorted; values from the same source keep the source's order
  (`groups`, `column_order`, `panes`).

## Exit codes

| Exit | Meaning | stdout |
|---|---|---|
| 0 | a document was printed | the document |
| 2 | the argument was refused (empty, or not `[A-Za-z0-9_:-]+`) | empty |
| 3 | herdr answered and lists no such space, and no record exists | empty |
| other | the script crashed | empty |

With no record and no herdr answer the script cannot tell an unknown id from
an unbound live space, so it prints an unbound document with
`herdr.status: "unavailable"` and exits 0.

## Sections

### `workspace`

| Key | Value |
|---|---|
| `id` | the argument |
| `label` | the label herdr reports; the id when herdr is unavailable |
| `live` | `true` when herdr lists the space, `false` when it does not, `null` when herdr is unavailable |

### `mapping`

`{"status": "ok", "source": "default", "space": "project", "tab": "work", "pane": "session"}`.
The default mapping, reported as a constant. No plugin surface reports another
mapping today; a reader renders any other value as the default with a warning.

### `record`

| Key | Value |
|---|---|
| `status` | `ok`, `missing` (no file), `unreadable` (a file the loader refuses: wrong mode, wrong owner, wrong shape, or a future version) |
| `state` | `bound`, `proposed` or `unbound` when `status` is `ok`; `unbound` when `missing`; `null` when `unreadable` |
| `project_id` | the Linear project id the record names, else `null` |

Only a `bound` record reaches Linear. `proposed`, `unbound`, `missing` and
`unreadable` stop with `linear.status: "unknown"` and empty `groups`, `issues`
and `unmapped`.

### `project`

`id`, `name`, `team_key`, `url`; each `null` when unknown. With Linear
unavailable, `name` comes from the cache when any cached issue names the
project, and `team_key` and `url` are `null`.

### `view`

| `status` | Meaning |
|---|---|
| `ok` | the recorded view was read and its grouping is one the board renders |
| `none` | the record names no view |
| `not_found` | Linear answered that the id does not exist |
| `archived` | the view is archived |
| `not_in_project` | the view was read, and its filter does not name the space's project; the board falls back to the project's issues |
| `unreadable` | Linear could not be asked (see `linear.status`) or the answer could not be parsed. A view already found `not_found`, `archived` or `not_in_project` keeps that status when a later read fails |
| `unsupported_grouping` | the view groups by something the board does not render |

`id` and `name` are the record's values whenever the record names a view, so a
reader can still say which view failed. `layout` is
`{"grouping", "column_order", "hidden"}` when the view was read, else `null`.
`grouping` is one of `workflowState`, `assignee`, `priority`, `label`,
`project`, or the unsupported name as Linear spells it. `column_order` and
`hidden` hold group keys.

Groups follow the view only when `status` is `ok`. For every other status the
groups are the fallback: the workflow states of the project's first team, in
the team's order, with the canceled state omitted.

### `linear`

| `status` | Meaning |
|---|---|
| `ok` | every Linear read answered |
| `truncated` | the issue listing hit the page cap; `issues` is incomplete |
| `unavailable` | a read failed; `issues` holds what the cache had for the identifiers the bindings name, each marked `stale: true` |
| `unknown` | no call was made (the record is not bound, or the argument stopped the script before Linear) |

`cache_age_seconds` is the age of the oldest cache entry used, else `null`.
`truncated` is a boolean and is `true` only with `status: "truncated"`.

### `herdr`

`status` is `ok` or `unavailable`; `version` is the version the snapshot
reports (`0.9.0`), else `null`. When herdr is unavailable every tab label is
`null`, every `panes` list is empty, and `unmapped` is empty.

### `groups`

An ordered list of `{"key", "label", "issues"}`. `issues` holds identifiers
that are keys of the `issues` map. Under `workflowState` the key is the state
id; under `assignee` the assignee id or `unassigned`; under `priority` the
priority number as a string; under `label` the label id (an issue can sit in
several groups) or `nolabel` for an issue with none; under `project` the
project id or `noproject` for an issue in none. With Linear unavailable the
key is the cached status name.

### `issues`

A map from identifier to issue:

| Key | Value |
|---|---|
| `id` | Linear's id, `null` from the cache |
| `identifier` | `WEB-3312` |
| `title` | sanitised |
| `url` | `null` from the cache |
| `state` | `{"id", "name", "type"}`; `id` and `type` are `null` from the cache |
| `assignee` | `{"id", "name"}` or `null` |
| `priority` | `0`–`4`, `null` from the cache |
| `labels` | label names |
| `stale` | `true` when the issue came from the cache |
| `bindings` | see below |

Only issues the view admits (or, with no usable view, every non-canceled issue
of the project) appear. A binding whose identifier is not among them is not
reported.

### `bindings`

Each binding is `{"worktree_path", "state", "tab", "panes"}`.

| `state` | Meaning |
|---|---|
| `bound`, `proposed`, `misplaced`, `stale` | the effective state `binding_read` reports |
| `worktree_missing` | the record exists and its directory does not; `worktree_path` is still reported |

`tab` is the record's tab enriched from the herdr snapshot: `{"id", "label"}`,
or `null` when the record's `tab` is `""`, `null` or absent (the three empty
forms every record can carry). `label` is `null` when herdr is unavailable or
no longer lists the tab. `panes` are the pane ids herdr lists in that tab, in
snapshot order. Nothing is inferred from a pane's cwd: a card with no recorded
tab has no panes.

### `unmapped`

Live tabs of the space that no binding claims:
`{"tab_id", "label", "reason", "panes"}`. `reason` is `no_binding` when no
record names the tab, else the binding state of a record whose issue is not
in the project's listing (`bound`, `worktree_missing`, `misplaced`, `stale`,
`proposed`, `unbound`). Empty when herdr is unavailable or the record is not
bound.

## Fixtures

| File | Setup |
|---|---|
| `bound-with-view.json` | bound record, view read, grouped by workflow state, one binding with a tab and two panes, one unmapped tab |
| `bound-no-view.json` | bound record, no view: team workflow-state columns |
| `bound-view-unsupported-grouping.json` | the view groups by cycle: fallback columns, grouping named |
| `unbound.json` | no record; herdr lists the space; no Linear call |
| `record-unreadable.json` | a record file the loader refuses |
| `linear-unavailable.json` | Linear down, cache warm: one cached card, stale |
| `herdr-unavailable.json` | herdr down: label falls back to the id, no panes |
| `worktree-missing.json` | the binding's directory is gone |

Two values are normalised before a fixture is compared with live output: the
sandbox prefix of every `worktree_path` is written as `$SANDBOX`, and
`linear.cache_age_seconds` is written as `0` whenever it is a number.
