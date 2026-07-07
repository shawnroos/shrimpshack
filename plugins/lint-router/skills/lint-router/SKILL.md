---
name: lint-router
description: Route to a different lint config based on WHO the work is for. In a Slate web-app checkout it layers a vetted, curated eslint-plugin-unicorn subset ON TOP of Slate's own linting (composes with ng lint; footguns off; never touches shared config/CI). In one of your OWN repos it runs the full unicorn suite (flat/all) as a self-contained lint. In another Slate team repo it does nothing. Use before committing/PR-ing to catch bugs and dated idioms in the .ts/.js you changed. A SessionStart hook already prepares the right profile automatically; invoke this to actually run the check. Triggers: finishing a code change, "run the lint check", "lint my changes", "run lint-router".
---

# lint-router

One tool, routed by **who the work is for**. It reports findings on the JS/TS **you changed** — never
touching any repo's committed config, deps, or CI. Everything it writes is gitignored or nothing at all.

## How to run

```bash
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/run.sh          # lints your changed files
bash ${CLAUDE_PLUGIN_ROOT}/tools/lint-router/run.sh <file…>  # or specific files
```

It classifies the repo and picks a profile automatically:

| Repo | Profile | What runs |
| --- | --- | --- |
| **Slate web-app** (has an `@angular-eslint` `eslint.config.mjs`) | `slate` | A **curated** unicorn subset *layered on Slate's own config* — composes with `ng lint`, footguns off. Writes a gitignored `eslint.unicorn.mjs`. |
| **Any repo of yours / non-Slate** | `personal` | The **full unicorn suite** (`flat/all`) as a *self-contained* lint, using the tool's own bundled eslint + parser (works even if the repo has no eslint). Writes nothing into the repo. |
| **A Slate team repo that isn't web-app** | `skip` | Nothing — never impose a lint on team code. |

Repos with no JS/TS (pure shell/Python) are a silent no-op — unicorn is JS/TS only.

## When to run

Near the **end** of a code task, before committing or opening a PR — like running tests. A `SessionStart`
hook (and a `PostToolUse` hook on `EnterWorktree`) already runs `--setup-only` to prepare the profile, so
the Slate overlay is present and the personal deps are installed the moment you need them; you just invoke
the command above to get the report.

## How to act on findings

**Slate profile** (curated, layered on Slate's rules):
- **ERRORS** — verified-safe correctness (e.g. `parseInt`→`Number.parseInt`). Fix them. `isNaN`/`isFinite`
  are not auto-fixable — hand-fix `Number.isNaN(x)` where `x` is provably numeric, else `Number.isNaN(Number(x))`.
- **WARNINGS** — real value but the fix can change behavior; review case by case.
- **Never blanket `eslint --fix`.** The overlay's OFF rules are exactly the auto-fixes that break Slate's
  Angular/Pixi code (e.g. `prefer-https` corrupts the SVG namespace URI). Fix deliberately, then `pnpm run typecheck`.

**Personal profile** (your repo, full `flat/all`):
- It's your code and your call — the full opinionated suite (including idiom-fighters like `no-null`,
  `prevent-abbreviations`). `eslint --fix` via this tool auto-fixes many, but still review DOM/URL rewrites
  (e.g. `prefer-https` on a namespace or a real http URL) before accepting.

## Where its deps live (configurable)

Deps and the synced rule files live in a **stable runtime dir**, NOT the versioned plugin dir, so they
survive plugin updates and the generated repo-config path stays valid:

- Default: `${XDG_STATE_HOME:-~/.claude/state}/lint-router`
- Override: set `LINT_ROUTER_STATE_DIR` to any path.

The tool installs its `node_modules` there once (and re-installs only when a plugin update changes the deps).

## Extending it

The router is one function — `classify_profile()` in `tools/lint-router/run.sh`. Add an org/profile branch
there and point it at a rules module (`overlay-rules.mjs` = curated Slate subset; `personal-config.mjs` =
full `flat/all`). Editing those two files changes the ruleset for every repo of that profile on the next run.

## What it is / isn't

- **Is:** a personal, local, per-repo lint layer for agent feedback. Gitignored or zero-footprint.
- **Isn't:** a change to any repo's committed config/CI. It never edits `eslint.config.mjs`, adds deps, runs a
  bulk migration, or affects a team gate. Proposing any ruleset to a team repo is a separate, explicit decision.

Footgun details + the vetted Slate curation rationale: memory `reference_unicorn_autofix_footguns_slate`;
setup/architecture: memory `project_slate_unicorn_personal_overlay`.
