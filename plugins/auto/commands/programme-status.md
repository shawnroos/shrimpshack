---
description: Show an auto programme's working model, items and rules in force
argument-hint: "[<run>]"
allowed-tools: Bash
---

Show where an auto programme stands: what the PM is doing now, its queue, what it
watches and why, who waits on whom, the decisions waiting on Shawn, what it just
did, acceptance, the rules in force, and every item with its deliverables,
evidence, owner pane and session state. For an ended programme it also shows
the resources still owed, the dispositions, and whether it is archived or which
archive check last failed.

With no argument it shows the programme this session drives. Pass a run id to show
another programme. It reads only; for an active programme whose live view file is
missing, it writes the view again.

Run the dispatch line below and print its output as it is:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" status "$ARGUMENTS"`

For a live view that updates on every programme write, the driving session runs
`/programme-view`.
