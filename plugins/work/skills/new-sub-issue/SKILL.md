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

## The first write from this directory asks once

Writes to Linear are opened by an answer, not by a file somebody edits.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
for f in contain secrets sanitize binding linear reconcile description herdr-read herdr-write start create; do
  source "$R/lib/$f.sh"
done
CTX="$(herdr_linear::current_context "$PWD" "$(herdr_linear::workspace_id)")"
TEAM="$(herdr_linear::_ctx_field "$CTX" team)"
PROJECT="$(herdr_linear::_ctx_field "$CTX" project)"
herdr_linear::has_consent "$PWD" && echo "already answered here" || echo "ask first"
```

Name `$TEAM`, `$PROJECT` and the issue — or the title, when the write **is** the
creation — and ask, using the host's blocking question tool. Record only what
that tool returns, in two steps, because `consent_confirm` requires the nonce
`consent_propose` hands back:

```bash
nonce="$(herdr_linear::consent_propose "$PWD" "$TEAM"  "$PROJECT")"
herdr_linear::consent_confirm "$PWD" "$TEAM"  "$PROJECT" "$nonce"
```

**Never supply the answer yourself.** A prompt that is refused, a hook, or a
headless `claude -p "/work:new-sub-issue … yes"` records nothing — the verb then runs in
shadow and reports what it would have sent. That is the right outcome, not
something to work around.

The answer is scoped to what the question named: a write deriving a different
team or a different project, or made from a different branch, asks again.

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
