---
name: lint-router
description: Run the right linters for the current repo, chosen by WHO the work is for, from a routes.json profile registry. In a Slate web-app it layers a curated unicorn subset on the repo's own eslint (composes with ng lint; footguns off); in your own repos it runs the full unicorn suite standalone; in another team's repo it does nothing. Use before committing/PR-ing to catch bugs and dated idioms in the .ts/.js you changed. A SessionStart hook prepares routing automatically; invoke this to run the check. Manage routing with the discover-linters / add-linter / configure-linter / remove-linter / explain-routing skills. Triggers: finishing a code change, "run the lint check", "lint my changes", "run lint-router".
---

# lint-router

Routing is driven by a **profile registry** (`routes.json` in the state dir): ordered
profiles, first match wins; a profile bundles linters that each self-gate, so "run
nothing" emerges when none apply. It reports findings on the JS/TS **you changed** —
never touching any repo's committed config, deps, or CI (gitignored overlays or nothing).

## Run the check

```bash
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/run.sh          # lint your changed files
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/run.sh <file…>  # or specific files
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/run.sh --explain # which linters run here + why (no lint)
```

## Seeded profiles (editable)

| Profile | Matches | Runs |
| --- | --- | --- |
| **work** | a repo you do work for — origin `*slateteams/*`, or an `@angular-eslint` `eslint.config.mjs` | a **curated** unicorn subset **layered on the repo's own eslint** (overlay); footguns off. In a team repo with no eslint of its own, nothing runs. |
| **personal** (default) | anything else — your own repos | the **full unicorn suite** (`flat/all`), self-contained via the bundled eslint. |

`work` ships pre-configured with today's Slate behavior but is named generally — extend
it, or add a profile per employer/client, with **add-linter**.

## Manage routing (sibling skills)

- **discover-linters** — what linters are installed / in this repo; adopt a repo's own config.
- **add-linter** — install/register a linter + define when it runs.
- **configure-linter** — edit a registered linter/profile's rules, severity, mode, or `when`.
- **remove-linter** — remove/disable a linter or profile.
- **explain-routing** — dry-run: which linters run here and why.

## Acting on findings

- **ERRORS** — verified-safe correctness (e.g. `parseInt`→`Number.parseInt`). Fix them.
  `isNaN`/`isFinite` aren't auto-fixable — hand-fix `Number.isNaN(Number(x))`.
- **WARNINGS** — real but the fix can change behavior; review case by case.
- **Never blanket `eslint --fix`.** Some `off` rules are auto-fixes that corrupt code
  (e.g. `prefer-https` on the SVG namespace URI). Fix deliberately, then re-typecheck.
  Footgun details: memory `reference_unicorn_autofix_footguns_slate`.

## Deps location (configurable)

Deps + rule configs live in a stable runtime dir — default
`${XDG_STATE_HOME:-~/.claude/state}/lint-router`, override with `LINT_ROUTER_STATE_DIR`
— so they survive plugin updates. The tool installs its `node_modules` there once.
