---
name: remove-linter
description: Remove or disable a linter or a whole profile from lint-router's routing. Use when the user says "remove the ruff linter", "stop linting python here", "drop the acme profile", or "disable lint-router for this context". Writes through the registry helper; leaves config files unless orphaned.
---

# remove-linter

Take a linter or profile out of routing.

## Remove

```bash
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/registry.sh list                  # confirm the exact names first
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/registry.sh remove <profile>.<linter>   # one linter
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/registry.sh remove <profile>            # a whole profile
```

- Removing the **last linter** in a profile leaves an empty profile — which routes to
  "run nothing" (a deliberate skip). If the user wants the profile gone entirely, remove
  the profile itself.
- **Don't remove the `personal` default catch-all** unless the user explicitly wants no
  fallback — without a `default:true` profile, a repo matching nothing has no route and
  `match` errors. Warn before removing it.

## Config cleanup

`remove` only edits `routes.json`; it leaves the linter's config file in the state dir
(`configs/…`) so a re-add is cheap. Offer to delete an orphaned config only if the user asks.

## Confirm

After removing, run `bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/run.sh --explain` in an
affected repo to confirm the new routing is what they intended.

Never hand-edit `routes.json` — always go through `registry.sh`.
