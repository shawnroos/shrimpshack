# token-bridge

A config-driven bridge between one codebase's CSS custom-property design tokens and one [Paper](https://paper.design) file. Tokens flow **both ways**; components harvest one way. Point it at any codebase with `--repo` — nothing is hardcoded to a particular design system.

## What it does

| You want to…                        | Use                                 | Direction    |
| ----------------------------------- | ----------------------------------- | ------------ |
| Bind a codebase to a Paper file     | `/token-bridge:connect`             | setup        |
| See where code and design disagree  | `/token-bridge:status`              | read-only    |
| Make the design match the code      | `/token-bridge:normalize-to-code`   | code → Paper |
| Make the code match the design      | `/token-bridge:normalize-to-design` | Paper → code |
| Pull rendered components into Paper | `/token-bridge:refresh-components`  | code → Paper |

- **`connect`** scaffolds the codebase's `token-bridge.config.json`, binding it to one Paper file — reference an existing file (by id or URL) or create a fresh one. The one-time setup the rest depends on.
- **`status`** reports the drift between code and design in both directions (tokens only in code, only in design, or differing), writing nothing, then offers the two normalize directions. This is the "which way should I reconcile?" view.
- **`normalize-to-code`** (code is source of truth) reconciles the codebase's CSS tokens into the Paper file: new tokens created, changed values updated, removed tokens deleted (within the prefix), retyped tokens recreated. Idempotent — an unchanged source writes nothing.
- **`normalize-to-design`** (design is source of truth) reads the Paper file's tokens and writes a CSS file at `emitTarget` — a base `:root` block plus a dark override block in your declared theme convention. The round-trip is stable: CSS emitted from a file already in sync re-parses to the same token model.
- **`refresh-components`** harvests a component's rendered structure and computed styles from a running dev server, maps the values back to token references, and writes it into Paper — replacing any prior copy.

The two `normalize-*` verbs are the same token engine pointed in opposite directions; `status` shows you which way you need it before you commit to one.

## The theme model

v1 is **base + one "dark" theme**. Paper has no per-token theme mode, so the two themes are written as two separately named Paper tokens: the base value keeps the token's name (`--accent`), and a theme-varying token's dark value gets a `-dark` twin (`--accent-dark`). `emit` inverts this exactly.

You declare **how the dark scope is expressed** in your source, via `themeConventions`:

| Convention       | Source shape it matches                               | Status    |
| ---------------- | ----------------------------------------------------- | --------- |
| `data-attribute` | `:root[data-theme="dark"] { … }`                      | supported |
| `media-query`    | `@media (prefers-color-scheme: dark) { :root { … } }` | supported |
| scoped-class     | `.dark { … }`                                         | deferred  |

The base is always the top-level, unscoped `:root`.

## Configuration

Each bridged codebase carries a `token-bridge.config.json` at its root. The plugin is pointed at it with `--repo <path>`; all paths resolve relative to that root.

```json
{
  "fileId": "01KXXXXXXXXXXXXXXXXXXXXXXX",
  "paperDaemonUrl": "http://127.0.0.1:29979/mcp",
  "source": {
    "path": "src/styles/tokens.css",
    "ref": null,
    "prefix": "--brand-"
  },
  "emitTarget": "src/styles/tokens.generated.css",
  "primitivePattern": null,
  "themeConventions": [
    {
      "type": "data-attribute",
      "attr": "data-theme",
      "value": "dark",
      "primary": true
    }
  ],
  "harvest": {
    "themeSignal": {
      "type": "data-attribute",
      "attr": "data-theme",
      "value": "dark"
    },
    "batch": []
  }
}
```

- **`fileId`** — the segment after `/file/` in the Paper URL. **The token commands refuse to run while `fileId` is empty** — a destructive reconcile must never fall back to whatever file happens to be open.
- **`source.path`** — the CSS/SCSS file, relative to `--repo`. **`source.ref`** (optional) reads the file from a git ref (e.g. `origin/main`) instead of the working tree. **`source.prefix`** filters custom properties; `null`/`""` takes all of them.
- **`emitTarget`** — where `normalize-to-design` writes. It refuses to write in place over a source that declares more than one convention (it would drop the non-primary block).
- **`primitivePattern`** (optional) — a regex overriding how the component-harvest mapper distinguishes a Tier-1 primitive (`--green-500`) from a semantic token in the value-collision tie-break (semantic wins). Default (`null`) treats a trailing `-<digits>` scale step as primitive; set e.g. `"-base$"` when your primitives are named `--blue-base`.
- **`themeConventions`** — one or more (see above). With more than one, exactly one must be `"primary": true`; parse reads the primary's dark scope and emit writes only the primary's block, warning if the conventions disagree.
- **`harvest.themeSignal`** — how the live page reports dark (a data-attribute read off the root, or a media query via `matchMedia`). **`harvest.batch`** — the components to harvest, each `{ name, selector, route, trigger? }`.

## Prerequisites

- The Paper desktop app running (its daemon at `http://127.0.0.1:29979/mcp`).
- `python3`, `jq`, `bats` (tests), `agent-browser` (harvest).
- For `refresh-components`: a running, logged-in dev server for the target codebase.

## Honest about what it doesn't do

- **One codebase ↔ one Paper file.** No many-to-one or one-to-many; the config binds a single codebase to a single `fileId`.
- **No Paper → component code-gen.** The reverse direction is tokens only. Components stay a one-way harvest — faithful code-gen from a canvas is fuzzy and fights the "Paper is the derived side" invariant.
- **No motion, no shadows as tokens.** Paper has no transition/easing type (it drops `transition`) and silently corrupts a shadow written as a token (stores `#000000`), so both are excluded from token sync with a reason. Shadows still work as component styles.
- **One base + one dark theme.** Multiple named themes, scoped-class conventions, and multi-file (`light.css`/`dark.css`) inputs are deferred.
- **Harvest needs a live server.** Token sync and emit work from the daemon (and the source file/git ref); component harvest requires a running, logged-in dev server.
- **No auto-sync.** No hook, watcher, or CI job — you run the commands.

## Where things live

- `lib/` — the deterministic Python/JS engines: `connect` (config scaffolder), `status` (bidirectional drift), `parse_tokens` (theme-scope parser), `classify_tokens`, `sync_tokens` (the code → Paper reconcile behind `normalize-to-code`), `emit_tokens` (the Paper → CSS emitter behind `normalize-to-design`), `harvest`/`harvest_extract.js`/`write_component`/`map_to_tokens` (component harvest), `paper_client` (the SSE JSON-RPC daemon client + `read_config`).
- `token-bridge.config.json` — the plugin-local template; the real config lives in each target codebase's root.
- `lib/harvest_batch.json` — the fallback component batch when the config declares none.
- `tests/` — bats suite (`./tests/run-tests.sh unit`) and fixtures.
