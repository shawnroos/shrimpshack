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
- **`normalize-to-code`** (code is source of truth) reconciles the codebase's CSS tokens into the Paper file: new tokens created, changed values updated, retyped tokens recreated. Idempotent — an unchanged source writes nothing. **It does not delete.** A live token absent from the parse is reported as `prunable` and left alone; `--prune` removes them.
- **`normalize-to-design`** (design is source of truth) reads the Paper file's tokens and writes a CSS file at `emitTarget` — a base `:root` block plus a dark override block in your declared theme convention. The round-trip is stable: CSS emitted from a file already in sync re-parses to the same token model.
- **`refresh-components`** harvests a component's rendered structure and computed styles from a running dev server, maps the values back to token references, and writes it into Paper — replacing any prior copy.

The two `normalize-*` verbs are the same token engine pointed in opposite directions; `status` shows you which way you need it before you commit to one.

## Why sync doesn't delete

A live token missing from the parse could mean two things — you removed it, or
the parser failed to read it — and those are indistinguishable from inside. Every
CSS shape the parser hasn't met yet looks exactly like a deletion: `@layer`,
nesting, a base64 `//` inside a data URI, a class-scoped theme file, an
unresolved `@import`, an unterminated string. Twelve separate data-loss defects
in this codebase were all that one ambiguity, and each fix guarded a symptom
rather than the inference.

So the inference is gone. `normalize-to-code` creates and updates; removal is
`--prune`, which reports exactly what it will remove first:

```
$ token-bridge normalize-to-code          # prunable: ["--brand-legacy"] — nothing removed
$ token-bridge normalize-to-code --prune  # removes them
```

The parser can be as incomplete as CSS demands and the worst outcome is a stale
token, which you can see in `status` and clear whenever you like. A deleted one
is not recoverable. `--prune` still refuses to remove anything the tool merely
failed to read.

## The theme model

v1 is **base + one "dark" theme**. Paper has no per-token theme mode, so the two themes are written as two separately named Paper tokens: the base value keeps the token's name (`--accent`), and a theme-varying token's dark value gets a `-dark` twin (`--accent-dark`). `emit` inverts this exactly.

A property declared **only** in the dark scope (no base declaration) is legal and
common — Tailwind's typography plugin does it for `--prose-*`. It lands in Paper
as a `-dark` twin with no base token beside it, which looks odd in the Paper file
but is correct and stable: re-syncing an unchanged source is a no-op, the
round-trip is a fixed point, and if the source later gains a base declaration the
base token is simply created.

You declare **how the dark scope is expressed** in your source, via `themeConventions`:

| Convention       | Source shape it matches                               | Status    |
| ---------------- | ----------------------------------------------------- | --------- |
| `data-attribute` | `:root[data-theme="dark"] { … }`                      | supported |
| `media-query`    | `@media (prefers-color-scheme: dark) { :root { … } }` | supported |
| `class`          | `.wcs-dark { … }`, `html.wcs-dark`, `:root.wcs-dark`  | supported |
| `file`           | dark lives in a **separate file**, same selector       | supported |

`class` matches on class-token boundaries, so `.wcs-dark` does **not** match
`.wcs-darker`, a `.wcs-dark\:*` escaped utility (Tailwind's `dark` toggle class
generates a lot of these), or the string appearing inside a quoted attribute
value.

The base is a top-level, unscoped **document scope** — `:root`, `html`, or `body`
(`html, body` counts). A component selector is never the base, however many custom
properties it declares: `.tooltip { --bs-tooltip-bg: … }` is component-local, not a
design token. Multiple base blocks merge in tiers (html < :root < body, as a browser resolves them). Scopes are found at any nesting
depth: `@layer` is transparent, so a bare `:root` inside one **is** the base,
while `@media`/`@supports`/`@container` are conditional — a `:root` inside one is
never the base, only a dark candidate. Declarations are read block-locally, so
CSS/SCSS nesting (`:root { &[data-theme="dark"] { … } }`) resolves correctly
rather than folding the child's values into the parent.

### When dark is a separate file

Some codebases don't put the dark theme in a scope at all — they put it in another
file, with the *same* selector:

```
themes/light.scss    :root { --primary-text-color: #21242e;      … }
themes/dark.scss     :root { --primary-text-color: #{$shade100}; … }
```

No selector predicate can tell those apart, because the distinguishing fact is the
filename. That's what `file` is for:

```json
"source":           { "path": "src/styles/themes/light.scss", "prefix": "--" },
"emitTarget":       "src/styles/themes/light.generated.scss",
"themeConventions": [ { "type": "file",
                        "path": "src/styles/themes/dark.scss",
                        "emitTarget": "src/styles/themes/dark.generated.scss",
                        "primary": true } ]
```

The dark scope is that file's own document scope, the same rule as the base. Two
things it refuses rather than guessing:

- **A missing or unreadable theme file refuses.** An empty dark scope would read as
  "no token varies by theme", and sync applies that by deleting every `-dark` twin.
- **Emit writes both halves or neither.** A `file` convention needs its own
  `emitTarget`; without one, emit refuses and writes nothing. Emitting just the base
  would leave the dark file stale and drift the pair apart.

**It does not make uncompiled Sass syncable.** A dark file interpolating Sass
(`#{$shade100}`) still needs a compile step — those tokens are declined with a
reason, and a token whose dark half can't be typed still syncs its base — only the twin is skipped.

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
- **`source.path`** — the CSS or SCSS file, relative to `--repo`. **`source.followImports`** (optional, default off) follows `@use`/`@import`/`@forward` from that entry file and parses the whole graph — see **Sass** below. **`source.ref`** (optional) reads the file from a git ref (e.g. `origin/main`) instead of the working tree. **`source.prefix`** filters custom properties.

  **`prefix` also decides what the bridge OWNS**, which is why `connect` no longer
  scaffolds it as `null`. Ownership is what makes a token eligible for deletion:
  with a prefix, a sync only ever deletes tokens in that namespace; with
  `null`/`""` it takes — and can delete — every token in the Paper file, including
  ones you created by hand there. `connect` now infers a prefix from your source's
  own properties, and if it can't find a dominant one it says so loudly instead of
  quietly claiming the whole file. `null` remains legal to read, so configs written
  before this keep working unchanged.
- **`emitTarget`** — where `normalize-to-design` writes. It refuses to write in place over a source that declares more than one convention (it would drop the non-primary block).
- **`primitivePattern`** (optional) — a regex overriding how the component-harvest mapper distinguishes a Tier-1 primitive (`--green-500`) from a semantic token in the value-collision tie-break (semantic wins). Default (`null`) treats a trailing `-<digits>` scale step as primitive; set e.g. `"-base$"` when your primitives are named `--blue-base`.
- **`themeConventions`** — one or more (see above). With more than one, exactly one must be `"primary": true`; parse reads the primary's dark scope and emit writes only the primary's block, warning if the conventions disagree.
- **`harvest.themeSignal`** — how the live page reports dark: a data-attribute read off the root, a media query via `matchMedia`, or a class checked with `classList.contains` on `<html>`/`<body>` (whole-token, so `dark` is not satisfied by `darker`). **`harvest.batch`** — the components to harvest, each `{ name, selector, route, trigger? }`.

## Prerequisites

- The Paper desktop app running (its daemon at `http://127.0.0.1:29979/mcp`).
- `python3`, `jq`, `bats` (tests), `agent-browser` (harvest).
- For `refresh-components`: a running, logged-in dev server for the target codebase.

## Sass

Nesting and interpolation are handled: `:root { &[data-theme="dark"] { … } }`
resolves correctly, and `--accent: #{$brand-blue}` is read as a value rather than
mistaken for a nested rule.

**Sass variables and mixins are not evaluated, and deliberately so.** `$brand-blue`
is a build-time construct — it has no runtime existence and no CSS scope, so the
base/dark model has nothing to attach it to, and it can't round-trip (Paper → Sass
would have to invent variable placement and mixin structure). A repo with a live
theme toggle is already using custom properties for the theme layer, because Sass
has no runtime and can't switch themes on its own. That layer is what this reads.

So a token whose value is still uncompiled Sass is **declined**, with the reason
shown — never guessed at and never synced:

```
--brand-accent -> value '#{$brand-blue}' matches no Paper token type
```

If you want those values in Paper, compile first and point at the output:

```
sass src/tokens.scss build/tokens.css
"source": { "path": "build/tokens.css", "prefix": "--brand-" }
```

dart-sass resolves variables, mixins, `@use` namespaces and `color.adjust`
correctly; re-implementing that here would be a large surface for values the
compiler already computes.

Two limits found testing this against a real Angular/Bootstrap SCSS app:

- **Sass load paths are not resolved** — only paths relative to the importing
  file. `@import 'bootstrap/scss/bootstrap'` (a `node_modules` package) and
  anything relying on `loadPaths`/`includePaths` won't resolve. Each one warns by
  name rather than being skipped quietly.
- **The base scope is a bare `:root`.** A codebase that declares its custom
  properties on `html`, `html, body`, or a component class has no base scope as
  far as this is concerned, and parses to zero tokens. That is a *refusal*, not a
  wipe — the empty-parse backstop catches it — but it does mean token-bridge
  currently can't read such a codebase at all.

**`followImports`** is the exception worth having, for a source split across files
without a build step. It follows `@use`/`@import`/`@forward` from the entry file,
resolving Sass partials (`_name.scss`, `name/_index.scss`) and skipping `sass:*`
built-ins and remote URLs. Dependencies are concatenated **before** the file that
imports them, so an importing file overriding a token it pulled in wins — matching
the cascade. Cycles terminate; an unresolved import warns loudly rather than
quietly shrinking the token set, because a token missing from a parse looks like a
deletion to sync. It is **opt-in** so an existing config keeps reading exactly one
file — silently widening the token set would change what sync owns, and therefore
what it can delete.

## Honest about what it doesn't do

- **Sass variables, mixins and functions are not evaluated.** Compile first and point at the output (see **Sass** above). Uncompiled values are declined, not guessed.
- **One codebase ↔ one Paper file.** No many-to-one or one-to-many; the config binds a single codebase to a single `fileId`.
- **No Paper → component code-gen.** The reverse direction is tokens only. Components stay a one-way harvest — faithful code-gen from a canvas is fuzzy and fights the "Paper is the derived side" invariant.
- **No motion, no shadows as tokens.** Paper has no transition/easing type (it drops `transition`) and silently corrupts a shadow written as a token (stores `#000000`), so both are excluded from token sync with a reason. Shadows still work as component styles.
- **One base + one dark theme.** Multiple named themes are deferred. Two-file light/dark IS supported — see `file` above.
- **Compound-class scopes are not user-declarable.** A convention takes one class. A dark scope requiring two classes together (`body.theme.theme-dark`) can't be expressed yet — the engine supports it internally, but the config surface deliberately does not, so it isn't frozen before a real repo needs it.
- **`-dark` is a reserved suffix.** A genuine `--border-dark` in your source is read as the dark twin of `--border` and round-trips lossily. Rename it if you have one.
- **`light-dark()` is split, but not nested.** `light-dark(#fff, #000)` resolves into both themes; a nested `light-dark(light-dark(…), …)` is not split and warns. A malformed call (not exactly two arguments) is left as a literal, which classify then declines — check the `declined` list, because a declined token that is already live in Paper gets deleted on the next sync.
- **Harvest needs a live server.** Token sync and emit work from the daemon (and the source file/git ref); component harvest requires a running, logged-in dev server.
- **No auto-sync.** No hook, watcher, or CI job — you run the commands.

## Where things live

- `lib/` — the deterministic Python/JS engines: `connect` (config scaffolder), `status` (bidirectional drift), `parse_tokens` (theme-scope parser), `classify_tokens`, `sync_tokens` (the code → Paper reconcile behind `normalize-to-code`), `emit_tokens` (the Paper → CSS emitter behind `normalize-to-design`), `harvest`/`harvest_extract.js`/`write_component`/`map_to_tokens` (component harvest), `paper_client` (the SSE JSON-RPC daemon client + `read_config`).
- `token-bridge.config.json` — the plugin-local template; the real config lives in each target codebase's root.
- `lib/harvest_batch.json` — the fallback component batch when the config declares none.
- `tests/` — bats suite (`./tests/run-tests.sh unit`) and fixtures.
