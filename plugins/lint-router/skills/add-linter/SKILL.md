---
name: add-linter
description: Add a linter to lint-router and define WHEN it runs (which profile / audience, matched by origin, marker files, or a new profile). Installs npm/node linters into the state dir; registers pre-installed non-npm linters. Use when the user says "add a linter", "set up eslint/ruff/prettier for this context", "lint python here too", "add a profile for <client/employer>", or "make lint-router run <X> when <Y>". Writes routes through the registry helper; never touches a repo's committed config.
---

# add-linter

Register a linter + the rule for when it applies. Two halves: get the linter available,
then write a route.

## 1. Get the linter available

- Run `discover-linters` first (or `command -v <bin>`) to see what's installed.
- **npm/node linters** (eslint and its plugin family): auto-installed into the state dir
  by `run.sh`'s `ensure_deps` — add the package to
  `${CLAUDE_PLUGIN_ROOT}/tools/lint-router/package.json` and let the next run install it.
- **Non-npm linters** (ruff, clippy, shellcheck, gofmt…): **register only if already
  installed** (discover found them). If missing, print the ecosystem's install command
  for the user to run — do NOT shell out a multi-package-manager installer.

## 2. Write the route

Decide the **when** (which audience) and add it via the registry helper:

```bash
# add a linter to an existing profile:
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/registry.sh add-linter personal \
  '{"linter":"eslint","mode":"standalone","config":"configs/personal-eslint.mjs","files":"\\.(ts|js)$"}'

# or a whole new profile (e.g. a new employer), placed before the default catch-all:
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/registry.sh add-profile \
  '{"name":"acme","when":{"origin":"*acme/*"},"linters":[{"linter":"eslint","mode":"overlay","config":"configs/acme-eslint.mjs","files":"^src/.*\\.ts$","requires_file":"eslint.config.mjs"}]}'
```

Linter fields: `linter`, `mode` (`overlay` = layer on the repo's own config, needs
`requires_file`; `standalone` = self-contained via the bundled eslint), `config` (a file
under the state-dir `configs/`), `files` (a regex the changed files must match).
`when` predicates: `origin` glob, `has_file` {path, contains?}, `path` glob, `default`,
or `any`/`all` of those. **Order is precedence** — a specific profile must come before
the `personal` default.

## Scope (v1)

- **Fully supported: eslint-family linters** (overlay + standalone) — these run today.
- **Other linters** can be *registered*, but running a non-eslint linter awaits the
  external-runner fast-follow; until then `run.sh` notes and skips an unknown linter
  rather than failing. Use `explain-routing` to see what will actually run.

## Rules

- **Never hand-edit `routes.json`** — go through `registry.sh` so writes are validated.
- **Never edit a repo's committed config/deps/CI.** Everything lives in the state dir or
  a gitignored overlay.
- After adding, confirm with `run.sh --explain` in a matching repo, then a real run.
