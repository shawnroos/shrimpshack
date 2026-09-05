---
name: new-sub-issue
description: File a sub-issue under the Linear issue this worktree is bound to, and open a session to work it in. Use when work turns out to have a separately reviewable piece inside it.
disable-model-invocation: true
---

# New sub-issue, and somewhere to work it

The same as `/work:new`, parented to the issue this worktree is bound to.

**It refuses when the worktree is not bound.** A sub-issue with no parent is
just an issue, and quietly filing one instead is not what was asked for. Bind
first, or use `/work:new`.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
for f in contain secrets sanitize binding linear reconcile description herdr-read herdr-write start create; do
  source "$R/lib/$f.sh"
done

herdr_linear::new_sub_issue "$PWD" "The title" /tmp/desc.md "$(herdr_linear::workspace_id)" short-name
```

Exit codes are `/work:new`'s, plus: **2 also means this worktree is unbound**.

The library records the new identifier against the binding for you
(`binding_add_child`). That list is the write boundary — an issue missing from
it can never be written to later — so if you ever file a sub-issue by any other
route, add it yourself:

```bash
herdr_linear::binding_add_child "$PWD" "$NEW_IDENTIFIER"
```

## When a sub-issue is the right shape

Create one when the work is **separately reviewable and separately landable**.
Work that cannot be reviewed on its own stays in the parent — a sub-issue that
never gets its own PR is a checklist item wearing a ticket's clothes.

Most sub-issues are discovered during the work rather than planned up front, so
this being reachable mid-session is the point.

Title it as a full sentence naming the problem or the outcome, per
`docs/linear-conventions.md` — the parent carries the noun phrase.
