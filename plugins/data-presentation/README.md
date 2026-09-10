# data-presentation

Turn numbers an agent already has into something a person can actually read in a chat
transcript.

The plugin is three things:

1. **A rule for what form the data earns.** A Markdown table by default. A line chart only
   when there are at least eight points, one series per chart, and the series actually
   varies. Below that, a table shows every exact value in the same vertical space and
   loses nothing.
2. **A validation gate that refuses rather than renders badly.** Mismatched lengths,
   non-numeric values, non-finite values, and empty series are named and refused. A missing
   value is never quietly turned into a zero.
3. **A renderer that checks its own output.** The chart library returns an empty string on
   two inputs and raises nothing, so a completed call is not proof anything was drawn.

## Use it

The skill is invoked by name. It reads a JSON request on stdin and writes a JSON response
on stdout:

```bash
echo '{"title":"Weekly signups","x":["Mon","Tue","Wed","Thu","Fri","Sat","Sun","Mon"],
       "series":{"Signups":[42,57,51,74,68,71,80,77]}}' \
  | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/present.py"
```

The response carries the rendered block, the form used, metadata, and notes saying what was
left out. Reproduce the block verbatim inside a plain fenced code block; do not retype or
summarise it.

## What it does not do

It does not fetch data, and it does not tell you what the numbers mean. Both are the
caller's job. It renders no SVG, no heatmap, and no sparkline; see the plan's Scope
Boundaries for why.

## Tests

```bash
bash plugins/data-presentation/tests/harness.sh
```

No install step, no virtual environment, no third-party package. The chart renderer is a
single vendored MIT file; see `scripts/vendor/VENDOR.md`.
