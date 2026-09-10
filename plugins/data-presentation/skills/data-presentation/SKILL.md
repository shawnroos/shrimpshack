---
name: data-presentation
description: Present structured numbers you already hold so a person reading the transcript can see what the data does. Picks the form the data earns — a Markdown table by default, a line chart when there are enough points and real variation — validates the values, renders, and reports what it left out. Use it when you are about to show someone a series of numbers and want the picture to be honest rather than hand-rolled. It does not fetch data and does not interpret what the numbers mean. Invoked by name only; do not trigger it from conversational phrasing on your own.
allowed-tools: Bash, Read
---

# Data presentation

You already have the numbers. This turns them into something a person can read, and tells
you what it left out.

## Call it

Send a JSON request on stdin:

```bash
echo '{
  "title": "Weekly signups",
  "units": "users",
  "x": ["Mon","Tue","Wed","Thu","Fri","Sat","Sun","Mon"],
  "series": {"Signups": [42, 57, 51, 74, 68, 71, 80, 77]},
  "source": {"Period": "2026-09-01 to 2026-09-08"}
}' | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/present.py"
```

Fields: `x` and `series` are required. `title`, `units`, and `source` are optional and are
rendered into a caption inside the block. `type` may be `table` or `chart` to ask for a
form; the rule below still decides, and the notes say if you did not get what you asked
for. A zero is always treated as a real measurement; only `null` or an empty string counts as missing, so a gap can never be silently rendered as a zero.

Use `null` for a missing value. Never substitute a zero yourself.

## Relay the block exactly

The response has a `block`. Reproduce it **verbatim** inside a plain fence with no
language tag:

```
```

Do not retype it, do not summarise it, and do not describe it instead of showing it. A
language tag invites syntax highlighting that reflows the character grid and destroys the
chart. Put the block before any explanation, and keep your reading of it short and after
it.

If the response `status` is `refused`, relay the `message` to the person. Do not improvise
a rendering to fill the gap — the refusal names a real problem with the data.

## When not to call this

Do not call this skill for:

- A single number, or two or three that belong in a sentence. Say them.
- Data you are about to act on rather than show a person.
- A destination you do not believe renders a monospace grid. Ask for `"type": "table"`
  instead; a table survives without character alignment, a chart does not.

## What it will and will not do

It chooses a table unless there are at least eight plottable points, at most three series,
and real variation in the series. A chart carries exactly one series; several become
several charts, because the renderer cannot tell two lines apart without colour and colour
is unusable inside a fence.

It never invents a missing value. It refuses rather than rendering something misleading,
and it says so in plain language. Read the `notes`: they carry what was omitted, which
positions were missing, and why you got the form you got.

It renders no SVG, no heatmap, and no sparkline.

It does not tell you what the numbers mean. That reading is yours, and a chart shows
correlation, never cause.
