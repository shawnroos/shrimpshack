---
description: Save the report you just built in this conversation as a named template, so asking for it later re-runs it on fresh data.
argument-hint: "<name> [what it shows]"
allowed-tools: Bash, Read, Write, AskUserQuestion
---

Save the report built in this conversation as a template. The template records the
exact calls you already made, how their results map to rows, and how the report is
shown. Later, a plain request for it re-runs those calls and shows what changed.

## 1. Draft it from calls you already made

Write a draft JSON file to a path of your choosing under
`~/.claude/data-presentation/drafts/`. Name it after the report. The draft is a
template without a fingerprint:

- `name`: lowercase letters, digits and hyphens, at most 24 characters.
- `purpose`: one line saying what the report shows.
- `caveats`: standing notes the person gave, for example who the data covers.
- `blocks`: one per chart or table. Each has:
  - `source`: the call exactly as you made it in this conversation.
    - A tool call: `{"kind": "tool", "tool": "<full tool name>", "args": {...}}`.
      Copy the arguments you actually sent. Do not tidy, reorder values, or drop
      any argument.
    - A shell command: `{"kind": "command", "command": "... {output} ...", "output": "<path you wrote to>"}`.
      The command must write its result to `{output}` and a `curl` command must
      use `-f`. A credential appears only as `$NAME`, never as its value. Run it
      in the foreground, never in the background.
    - A local file: `{"kind": "file", "path": "/absolute/path.json"}`.
  - `mapping`: `{"adapter": "amplitude-segmentation", "chart": "<chart id>"}` for an
    Amplitude chart result, `{"adapter": "paths", "paths": {...}}` for other JSON, or
    `{"adapter": "identity"}` for data already shaped as `x` and `series`. Add
    `series` (a list, or `"all"`) and `aliases` (short names) when the person asked
    for them.

    A `paths` mapping has exactly three dotted paths. A segment is a key, a
    whole-number index, or `*`. `x` holds at most one `*`, `names` exactly one (one per
    series), and `values` exactly two (the series, then the x positions). For a result
    shaped `{"weeks": ["2026-01-05", ...], "rows": [{"name": "a", "counts": [3, ...]}]}`:

    ```json
    {"adapter": "paths", "paths": {"x": "weeks", "names": "rows.*.name", "values": "rows.*.counts.*"}}
    ```
  - `present`: always include it, even as `{}`. Add `title`, `units`, and `type` when
    the person asked for them.

Only calls made in this conversation, on its current branch, can be saved. If a call
was made before the conversation was compacted or cleared, make it again first.

## 2. Preview it

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/report.py" save --draft "<absolute draft path>"
```

When `status` is `ok`, relay the `block` verbatim inside a plain fence with no
language tag. For any other status, relay `message` instead and show no numbers.
Follow `next`:

- `confirm_save`: ask the person whether this is the report to save.
- `make_calls`: a drafted call was not found in this conversation. Make it again
  exactly as drafted, then preview again.
- `run_save_again`: a call's result had not arrived yet. Run save again in a later
  message, without making the calls again.
- `ask_snapshot_or_relative`: a call holds fixed dates, so re-running it would show
  the same window forever. Ask the person to choose: keep it as a fixed snapshot, or
  make the call again with a relative range and redraft.
- A stop saying a report of that name already exists: ask the person whether to
  replace it. Only if they say yes, add `--replace` to the save.
- Anything else: relay `message` to the person and stop. Do not work around it.

## 3. Save it

After the person confirms:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/report.py" save --draft "<absolute draft path>" --confirm
```

Add `--snapshot` only when the person chose a fixed snapshot. Add `--replace` only
when the person asked to update an existing report of that name. Then tell the
person the name to ask for.
