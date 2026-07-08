---
name: configure-linter
description: Edit a linter or profile already registered in lint-router — change its rules, severity, mode (overlay vs standalone), the files it lints, or the "when" that routes to it. Use when the user says "configure lint-router", "change the unicorn rules", "make this a warning not an error", "make the work profile match another origin", or "edit the personal linter". Writes only through the registry helper; never hand-edits routes.json or a repo's committed config.
---

# configure-linter

Change an existing registered linter/profile. Two layers you may edit:

## 1. The route (in `routes.json`)
The profile's `when` (origin glob / `has_file` / `path` / `default` / `any` / `all`), or a
linter's `mode` (`overlay`|`standalone`), `files` glob, `config` path, or `requires_file`.
Do this via the registry helper — read current state, then rewrite the entry:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/registry.sh list                 # see current
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/registry.sh remove <profile>.<linter>
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/registry.sh add-linter <profile> '<new-json>'
```
(There's no in-place edit verb by design — remove + re-add keeps every write validated.)

## 2. The rules (the config file in the state dir)
Rule/severity changes live in the linter's config under
`${LINT_ROUTER_STATE_DIR:-~/.claude/state/lint-router}/configs/<file>` (e.g. the unicorn
overlay `work-eslint.mjs` or the standalone `personal-eslint.mjs`). Edit that file directly.

## Rules & footguns

- **Never hand-edit `routes.json`** — go through `registry.sh` so every change is validated.
- **Never edit a repo's committed config** (`eslint.config.mjs`, `ruff.toml`, …). lint-router
  is personal and zero-footprint: it edits only the state-dir configs or a gitignored overlay.
- For the unicorn rule set, respect the footgun rules — some `off` rules are auto-fixes that
  corrupt code (e.g. `prefer-https` on the SVG namespace URI). See memory
  `reference_unicorn_autofix_footguns_slate` before promoting an `off` rule.
- After a change, confirm with `run.sh --explain` (what routes) and a run on a changed file.
