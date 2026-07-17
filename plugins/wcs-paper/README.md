# wcs-paper

Mirror the Web Creation Studio (WCS) design system into a [Paper](https://paper.design) file, so mockups of new editor tools are built against values that are actually true in code — not hand-copied and quietly stale.

## What it does

Two commands, both one-way (code → Paper, never the reverse):

| You want to…                                       | Use                             |
| -------------------------------------------------- | ------------------------------- |
| Get the current `--wcs-*` design tokens into Paper | `/wcs-paper:sync-tokens`        |
| Get rendered WCS components into Paper             | `/wcs-paper:refresh-components` |

`sync-tokens` reads the tokens from the merged `develop` ref of `web-app` and reconciles them into the Paper file: new tokens created, changed values updated, removed tokens deleted, retyped tokens recreated. Re-running with an unchanged source writes nothing.

`refresh-components` harvests a component's rendered structure and computed styles from a running dev server, maps the values back to token references, and writes it into Paper — replacing any prior copy.

## Prerequisites

- The Paper desktop app running (its daemon at `http://127.0.0.1:29979/mcp`).
- `python3`, `jq`, `bats` (tests), `agent-browser` (harvest).
- For `refresh-components`: a running `web-app` dev server and a logged-in browser profile.

## Configuration

Set the target Paper file in `wcs-paper.config.json`:

```json
{ "fileId": "01KXXXXXXXXXXXXXXXXXXXXXXX" }
```

The `fileId` is the segment after `/file/` in the Paper URL. **Both commands refuse to run while `fileId` is empty** — a destructive reconcile must never fall back to whatever file happens to be open.

## Honest about what it doesn't do

- **No motion.** Paper has no transition/easing token type and drops `transition` even as a style. WCS motion tokens are simply not represented.
- **No shadows as tokens.** Paper silently corrupts a shadow value written as a token (it stores `#000000`), so shadows are excluded from token sync and expressed on components instead.
- **No Paper → code.** Designs authored in Paper do not flow back into the repo. Paper is always the derived side.
- **No auto-sync.** There is no hook, watcher, or CI job. You run the commands.
- **Harvest needs a live server.** Token sync works offline from the git ref; component harvest requires a running, logged-in dev server.

## Where things live

- `lib/` — the deterministic Python/JS scripts (parser, classifier, sync, harvester, writer, Paper client).
- `wcs-paper.config.json` — the target `fileId` (committed with an empty value; set it locally).
- `harvest_batch.json` — the component batch: per entry a `selector`, `route`, and any `trigger` steps.
- `tests/` — bats suite (`./tests/run-tests.sh unit`) and fixtures.
