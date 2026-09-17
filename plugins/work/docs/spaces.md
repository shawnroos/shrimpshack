# The space list

`bin/work-spaces.sh` prints every herdr space with its binding state, as one
JSON envelope. The board runs it for `board linear space list` and for the
strip of unbound spaces. An agent in a session can run the same script. It
takes no argument and makes no Linear call.

## The envelope

| Key | Value |
|---|---|
| `status` | `ok`, `unavailable` or `unknown` |
| `message` | a short reason when `status` is not `ok`, else `null` |
| `rows` | one row per space when `status` is `ok`, else `[]` |

`rows` is empty whenever `status` is not `ok`. A reader must not read an
empty list under `unavailable` as "every space is bound". It says the list is
unavailable.

| `status` | Meaning |
|---|---|
| `ok` | herdr listed its spaces and the space records were read. An empty `rows` means no space and no record |
| `unavailable` | herdr is not running, or its space list failed or could not be parsed |
| `unknown` | herdr answered, and the space records could not be read |

The list has no `partial` status: herdr returns its spaces in one answer.

## A row

| Key | Value |
|---|---|
| `id` | the herdr workspace id |
| `label` | the label herdr reports; the id for a space herdr does not list |
| `live` | `true` when herdr lists the space, `false` for a record with no live space |
| `state` | the record's state: `bound`, `proposed`, `unbound`, `misplaced` or `stale`. `unbound` when no record exists, or when the loader refuses the record (wrong mode, wrong owner, wrong shape, or a future version) |
| `project_id` | the Linear project id the record names, else `null` |
| `project_name` | the `project_name` string in the space record, else `null`. It never comes from Linear. No writer records it today, so it is `null` until the bind records a name |

Live spaces come first, in herdr's order. Records with no live space follow,
sorted by id.

## What is cleaned

- The display controls of `HERDR_LINEAR_STRIP_RANGES` in `lib/sanitize.sh`
  are removed from every label, project id and project name. Tab, newline
  and carriage return are removed too, because a picker row is one line.
- The script reads herdr's JSON answer itself. A label that carries a newline
  cannot add a row.
- A space id must match `[A-Za-z0-9][A-Za-z0-9._:-]{0,127}`. A live space or a
  record with any other id is left out, so no id starting with `-` reaches a
  bind.

## Exit codes

| Exit | Meaning | stdout |
|---|---|---|
| 0 | an envelope was printed, whatever its `status` | the envelope |
| 2 | an argument was given | empty |
| other | a library is missing or the script crashed | empty |

The canonical envelopes live in `tests/fixtures/spaces/`.
