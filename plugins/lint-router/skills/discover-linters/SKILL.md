---
name: discover-linters
description: Find the linters available on this machine and in the current repo, and offer to register (adopt) what's found into a lint-router profile. Use when the user asks "what linters do I have", "discover linters", "what could lint-router use here", or before add-linter to see options. Inventories global installs, project-local node_modules/.bin, and repo-local linter configs; a repo's own eslint/ruff/etc. config can be adopted as a profile's linter instead of installing fresh.
---

# discover-linters

Inventory what's available, then offer to adopt it. Read-only until the user says adopt.

## What to scan

1. **Installed linters** — for each known linter, `command -v <bin>`:
   `eslint biome prettier stylelint ruff black mypy flake8 pylint clippy golangci-lint gofmt shellcheck rubocop`.
   Also check the current repo's `node_modules/.bin/` for project-local copies.
2. **Repo-local configs** — look in the repo root for config files that mean "this repo
   already has a linter": `eslint.config.*` / `.eslintrc*`, `biome.json`, `.prettierrc*`,
   `stylelint.config.*`, `ruff.toml` / `pyproject.toml` (`[tool.ruff]`), `.rubocop.yml`, etc.
3. **Current routing** — run `bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/run.sh --explain`
   (or `registry.sh match <repo>`) so the inventory is shown next to what already routes here.

## Present

A short table: linter → installed? (global / project / no) → repo config found? → already in a profile?
Then, for each **repo-local config found that isn't yet registered**, offer to **adopt** it:
"this repo has its own `eslint.config.mjs` — register it as the `work` profile's eslint in
**overlay** mode?" Adopting means the linter runs against the repo's *own* config rather than
installing a fresh one — hand off to **add-linter** in adopt mode (mode `overlay`,
`requires_file` = that config, `config` = the repo's config path or an overlay that imports it).

## Rules

- **Read-only by default.** Never install or write a route without the user choosing to.
- Prefer **adopt** over install when the repo already has a linter config — don't reinstall what's there.
- Non-JS/TS linters are inventory-only until `add-linter` registers them (registration is a route write; install is npm-only per add-linter).
- Pure shell/Python repos with nothing installed → say so; nothing to do.

Registry writes go through `bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/registry.sh` — never hand-edit `routes.json`.
