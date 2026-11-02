# Upstream report, drafted and not yet filed: herdr

herdr accepts an agent session id and never gives it back, which is why auto cannot re-find a Programme driver
whose recorded pane id has gone stale. Auto guards the stale id rather than dropping it, and says in its denial
that it could not confirm the pane, but no workaround can recover a session whose first recorded pane was already
wrong — so the upstream fix is the real one.

This is kept in the repo because it could not be filed from the session that wrote it: any `gh` command naming the
herdr repository is refused by auto's own send-guard, because the repo slug's last segment matches a host program
name. That false positive is tracked in #166 and predates #162. Filing upstream is a human step for now, left
deliberately un-routed-around.

Observed on herdr 0.9.5 (Homebrew, `homebrew/core`). Check the current release before filing; the session that
drafted this could not reach the repository to look.

The title and body below are ready to paste.

---

## Title

api snapshot and agent list do not report the agent session id that pane report-agent-session recorded

## Body

`herdr pane pane report-agent-session` accepts an agent session id:

```
herdr pane report-agent-session --source <tool> --agent claude --agent-session-id <id> <pane-id>
```

No read API appears to return that id, so a tool that records it cannot later ask herdr which pane a given agent
session is in. Both read paths I tried omit it:

- `herdr api snapshot` — each entry under `panes` and under `agents` carries `agent`, `agent_status`, `cwd`,
  `focused`, `foreground_cwd`, `pane_id`, `revision`, `state_change_seq`, `tab_id`, `terminal_id`,
  `terminal_title`, `terminal_title_stripped`, `workspace_id`, and sometimes `completion_seq`. There is no
  `agent_session` or equivalent.
- `herdr agent list` — same fields, same omission, on every agent row.

### Why it matters

A tool that drives several agents needs to find the pane a known session is in *now*. Today the only durable
handle is the pane id, and a pane id is not stable: `herdr pane move` gives the pane a new id. A tool that
recorded the old id has no way to re-resolve it, because the one identifier it owns — the agent session id it
reported to herdr — never comes back out.

The `terminal_id` is stable across a move and does let a caller follow a pane. That covers the case where the
caller saw the pane at least once. It does not cover a session whose first sighting was already wrong, which
happens when a process inherits `HERDR_PANE_ID` from a parent in a different pane: the caller then holds an id
that was never that session's, and nothing it can query will correct it.

### Reproduce

1. Report a session against a pane:
   `herdr pane report-agent-session --source test --agent claude --agent-session-id abc123 <pane-id>`
2. Ask for it back: `herdr api snapshot` and `herdr agent list`.
3. Neither response contains `abc123`, nor any field keyed to it.

### What would help

Any one of these would be enough:

- Include the reported agent session id on the `agents` rows (and on `panes` rows that have one), under a stable
  key such as `agent_session`.
- Or add a lookup: `herdr agent get --agent-session-id <id>` returning that agent's current pane and terminal.
- Or document that the id is write-only and name the intended way to re-resolve a moved pane, if there already is
  one I missed.

Happy to test a build.
