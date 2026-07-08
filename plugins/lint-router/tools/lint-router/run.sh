#!/usr/bin/env bash
# lint-router — pick a lint config by WHO the work is for, driven by a routes.json
# registry (ordered profiles, first match wins; a profile bundles linters that each
# self-gate, so "run nothing" emerges naturally when none apply). Manage routing with
# the discover-linters / add-linter / configure-linter / remove-linter /
# explain-routing skills — do NOT hand-edit routing here.
#
# Usage:  run.sh [--setup-only] [file ...]
#   no files    → lints the JS/TS you changed (vs default branch + working tree + untracked)
#   --setup-only → seed the registry + prepare configs (SessionStart hook); no linting
#
# Deps + configs live in a STABLE, configurable runtime dir (not the versioned plugin dir):
#   LINT_ROUTER_STATE_DIR  (default: ${XDG_STATE_HOME:-~/.claude/state}/lint-router)
set -uo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${LINT_ROUTER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.claude/state}/lint-router}"
REG="$TOOL_DIR/registry.sh"
PY="/usr/bin/python3"; command -v "$PY" >/dev/null 2>&1 || PY="$(command -v python3)"

SETUP_ONLY=0; EXPLAIN=0; ARGS=()
for a in "$@"; do case "$a" in --setup-only) SETUP_ONLY=1 ;; --explain) EXPLAIN=1 ;; *) ARGS+=("$a") ;; esac; done
set -- ${ARGS[@]+"${ARGS[@]}"}

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { [ "$SETUP_ONLY" = 1 ] && exit 0; echo "✗ not in a git repo"; exit 2; }
cd "$ROOT" || exit 2

# --- Stable runtime dir: seed registry, migrate configs, install deps (idempotent) ---
_sync_file() { local src="$TOOL_DIR/$1" dst="$STATE_DIR/$2"; [ -f "$src" ] || return 0; mkdir -p "$(dirname "$dst")"; cmp -s "$src" "$dst" 2>/dev/null || cp "$src" "$dst"; }
ensure_deps() {
  mkdir -p "$STATE_DIR" "$STATE_DIR/configs"
  [ -f "$STATE_DIR/routes.json" ] || cp "$TOOL_DIR/seeds/routes.json" "$STATE_DIR/routes.json"
  _sync_file overlay-rules.mjs configs/work-eslint.mjs
  _sync_file personal-config.mjs configs/personal-eslint.mjs
  local f deps_changed=0
  for f in package.json package-lock.json; do
    if [ -f "$TOOL_DIR/$f" ] && ! cmp -s "$TOOL_DIR/$f" "$STATE_DIR/$f" 2>/dev/null; then cp "$TOOL_DIR/$f" "$STATE_DIR/$f"; deps_changed=1; fi
  done
  if [ "$deps_changed" = 1 ] || [ ! -x "$STATE_DIR/node_modules/.bin/eslint" ] || [ ! -d "$STATE_DIR/node_modules/eslint-plugin-unicorn" ]; then
    [ "$SETUP_ONLY" = 1 ] || echo "→ installing lint deps (one-time) in $STATE_DIR …"
    ( cd "$STATE_DIR" && npm install --no-audit --no-fund >/dev/null 2>&1 ) || { echo "✗ lint deps install failed"; exit 2; }
  fi
}

# Generate the gitignored eslint overlay for an overlay-mode eslint linter:
# the repo's own base config + the state-dir unicorn rule set.
gen_overlay() {  # <state-relative-config>
  if [ ! -f eslint.unicorn.mjs ]; then
    cat > eslint.unicorn.mjs <<EOF
// AUTO-GENERATED overlay (gitignored) — the repo's linting + a vetted unicorn subset.
// Managed by the lint-router plugin. Safe to delete; regenerated on next run. Do NOT commit.
import base from './eslint.config.mjs';
import unicornOverlay from '$STATE_DIR/$1';
export default [...base, ...unicornOverlay];
EOF
  fi
  local exclude; exclude="$(git rev-parse --git-path info/exclude 2>/dev/null)"
  [ -n "$exclude" ] && { mkdir -p "$(dirname "$exclude")"; grep -qxF 'eslint.unicorn.mjs' "$exclude" 2>/dev/null || echo 'eslint.unicorn.mjs' >> "$exclude"; }
}

# Runner dispatch: invoke a linter, writing an eslint-style JSON array to <out>. eslint
# overlay/standalone are built in; other linters get a generic runner in a later unit.
run_linter() {  # <linter> <mode> <config> <out> <files...>
  local ln="$1" mode="$2" cfg="$3" out="$4"; shift 4
  case "$ln:$mode" in
    eslint:overlay)
      NODE_OPTIONS=--max-old-space-size=6144 npx eslint --config eslint.unicorn.mjs --format json "$@" > "$out" 2>/dev/null || true ;;
    eslint:standalone)
      NODE_OPTIONS=--max-old-space-size=6144 "$STATE_DIR/node_modules/.bin/eslint" \
        --no-config-lookup --config "$STATE_DIR/$cfg" --format json "$@" > "$out" 2>/dev/null || true ;;
    *)
      echo "  ⚠ no runner for linter '$ln' (mode $mode) — skipped" >&2; echo '[]' > "$out" ;;
  esac
  [ -s "$out" ] || echo '[]' > "$out"
}

ensure_deps

# --- --explain: dry-run the registry against this repo, then exit (U9) ----------
if [ "$EXPLAIN" = 1 ]; then
  "$REG" explain "$ROOT" 2>/dev/null | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("no profile matched this repo (no default catch-all in routes.json?)"); sys.exit(0)
print("profile:    " + str(d["profile"]))
print("matched by: " + json.dumps(d["matched_by"]))
lin = d.get("linters", [])
if not lin:
    print("linters:    (none) -> nothing runs here")
for ln in lin:
    mark = "RUNS" if ln.get("applies") else "skip"
    print("  [" + mark + "] " + str(ln.get("linter")) + " (" + str(ln.get("mode")) +
          ") files=" + repr(ln.get("files")) + " -- " + str(ln.get("reason")))
' || echo "✗ no profile matched this repo"
  exit 0
fi

# --- Match a profile from the registry -----------------------------------------
MATCH="$("$REG" match "$ROOT" 2>/dev/null)"; MSTATUS=$?
case "$MSTATUS" in
  0) : ;;
  3) if [ "$SETUP_ONLY" != 1 ]; then
       PN="$(printf '%s' "$MATCH" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["profile"])' 2>/dev/null)"
       echo "✓ profile '${PN:-?}' matched but no linter applies here — nothing to lint."
     fi
     exit 0 ;;
  *) [ "$SETUP_ONLY" = 1 ] && exit 0; echo "✗ no lint-router profile matched this repo (no default catch-all in routes.json?)"; exit 2 ;;
esac
PROFILE="$(printf '%s' "$MATCH" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["profile"])')"

# Setup pass: generate overlays for any applicable overlay-mode eslint linter.
printf '%s' "$MATCH" | "$PY" -c '
import json, sys
for ln in json.load(sys.stdin)["linters"]:
    if ln.get("linter") == "eslint" and ln.get("mode") == "overlay":
        print(ln.get("config", ""))
' | while IFS= read -r cfg; do [ -n "$cfg" ] && gen_overlay "$cfg"; done

[ "$SETUP_ONLY" = 1 ] && exit 0

# --- Resolve the changed-file set ----------------------------------------------
resolve_base() {
  local b; b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  [ -n "$b" ] && { echo "$b"; return; }
  local c; for c in origin/develop origin/main origin/master main master; do
    git rev-parse --verify --quiet "$c" >/dev/null 2>&1 && { echo "$c"; return; }
  done
  echo HEAD
}
CHANGED=()
if [ "$#" -gt 0 ]; then
  CHANGED=("$@")
else
  BASE="$(resolve_base)"; MB="$(git merge-base HEAD "$BASE" 2>/dev/null || echo HEAD)"
  while IFS= read -r f; do [ -n "$f" ] && CHANGED+=("$f"); done < <(
    { git diff --name-only --diff-filter=d "$MB" HEAD;
      git diff --name-only --diff-filter=d;
      git diff --cached --name-only --diff-filter=d;
      git ls-files --others --exclude-standard; } 2>/dev/null \
    | sort -u | grep -vE '(^|/)(node_modules|dist|build|out|coverage|vendor)/' )
fi

# --- Run each applicable linter over its matching files; merge findings ---------
MERGED="$(mktemp)"; echo '[]' > "$MERGED"
ran=0
while IFS=$'\t' read -r LNAME LMODE LCFG LFILES; do
  [ -n "$LNAME" ] || continue
  SEL=()
  for f in ${CHANGED[@]+"${CHANGED[@]}"}; do [[ "$f" =~ $LFILES ]] && SEL+=("$f"); done
  [ ${#SEL[@]} -eq 0 ] && continue
  OUT="$(mktemp)"
  run_linter "$LNAME" "$LMODE" "$LCFG" "$OUT" "${SEL[@]}"
  "$PY" - "$MERGED" "$OUT" <<'MERGE' 2>/dev/null
import json, sys
try:
    a = json.load(open(sys.argv[1]))
    b = json.load(open(sys.argv[2]))
except Exception:
    b = []
json.dump(a + (b if isinstance(b, list) else []), open(sys.argv[1], "w"))
MERGE
  rm -f "$OUT"; ran=1
done < <(printf '%s' "$MATCH" | "$PY" -c '
import json, sys
for ln in json.load(sys.stdin)["linters"]:
    print("\t".join([ln.get("linter",""), ln.get("mode",""), ln.get("config",""), ln.get("files","")]))
')

if [ "$ran" = 0 ]; then echo "✓ no changed files matched the linters for '$PROFILE'."; rm -f "$MERGED"; exit 0; fi
echo "→ [$PROFILE] lint on changed file(s)…"

PROFILE="$PROFILE" node - "$MERGED" <<'NODE'
const fs = require('fs');
const profile = process.env.PROFILE;
let data; try { data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')); }
catch { console.log('(no parseable lint output — check the config/paths)'); process.exit(0); }
let uni = [], otherErr = 0;
for (const f of data) for (const m of (f.messages || [])) {
  if (m.ruleId && m.ruleId.startsWith('unicorn/')) uni.push({ file: f.filePath.replace(process.cwd() + '/', ''), line: m.line, sev: m.severity, rule: m.ruleId.replace('unicorn/', ''), msg: m.message });
  else if (m.severity === 2) otherErr++;
}
if (!uni.length) { console.log('✓ no unicorn findings on the changed files.'); }
else {
  const err = uni.filter(u => u.sev === 2), warn = uni.filter(u => u.sev === 1);
  console.log(`\nunicorn: ${err.length} error(s), ${warn.length} warning(s)\n`);
  const show = (list, label) => { if (!list.length) return; console.log(label); for (const u of list) console.log(`  ${u.file}:${u.line}  [${u.rule}] ${u.msg}`); console.log(''); };
  show(err, 'ERRORS (fix these; isNaN/isFinite need Number.isNaN by hand):');
  show(warn, "WARNINGS (review — the fix can change behavior; never blanket `eslint --fix`):");
}
if (otherErr) console.log(`(also ${otherErr} non-unicorn eslint error(s).)`);
console.log('\nApply fixes deliberately. Never blanket `eslint --fix` — some OFF rules are auto-fixes that corrupt code (e.g. prefer-https on the SVG namespace URI).');
NODE
rm -f "$MERGED"
