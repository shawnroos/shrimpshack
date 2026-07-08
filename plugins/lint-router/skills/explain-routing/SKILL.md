---
name: explain-routing
description: Show which linters lint-router will run in the current repo and WHY — a dry-run of the routing registry against this repo. Use when the user asks "why did/didn't lint-router run here", "what linters apply here", "which profile matches this repo", "explain lint-router routing", or is debugging unexpected (or missing) lint output. Read-only; never lints, never writes.
---

# explain-routing

Answer "what runs here and why" without linting anything. It shares the exact match
function the linter uses, so the explanation can't drift from real behavior.

## Run it

```bash
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/run.sh --explain
```

Output (per repo): the **matched profile**, the **predicate that matched** it, and for
each linter in that profile whether it **RUNS or is skipped here** — with the reason a
skip happened (e.g. an `overlay` linter whose base config isn't present). Example:

```
profile:    work
matched by: {"any":[{"origin":"*slateteams/*"},{"has_file":{"path":"eslint.config.mjs","contains":"@angular-eslint"}}]}
  [skip] eslint (overlay) files='^src/.*\.ts$' -- overlay base config 'eslint.config.mjs' not present
```

That `[skip]` line is how today's "no lint on this team repo" behavior shows up: the
`work` profile matched by origin, but its overlay linter needs a base config the repo
doesn't have, so nothing runs.

## Use it to debug

- **Lint didn't run and you expected it to** → `--explain` shows which linter is `skip`
  and why (wrong files glob, missing base config, wrong profile matched first).
- **Wrong profile matched** → the `matched by` line shows the predicate; a more specific
  profile may need to come earlier in the registry (order = precedence). Fix with
  `configure-linter` / `add-linter --at`.
- **Nothing matched** → the registry has no `default:true` catch-all; `personal` is the
  seeded default.

Never edits the registry — for changes use `add-linter` / `configure-linter` / `remove-linter`.
