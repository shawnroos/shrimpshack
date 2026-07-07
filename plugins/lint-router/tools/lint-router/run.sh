#!/usr/bin/env bash
# lint-router — pick a lint config by WHO the work is for (agent code-quality feedback).
# Two profiles today, extensible:
#
#   • slate     — Slate web-app: layer a vetted, curated unicorn subset ON TOP of Slate's own
#                 eslint.config.mjs (composes with `ng lint`; footguns off; never touches shared config/CI).
#   • personal  — your own repos: the FULL unicorn suite (flat/all) as a self-contained lint, using this
#                 tool's own eslint/parser/unicorn — runs on repos that have no eslint of their own.
#   • (skip)    — a Slate team repo that isn't web-app → do nothing (never impose a lint on team code).
#
# Add a new org/profile in classify_profile() below — that's the single extension point.
#
# Usage:  bash <plugin>/tools/lint-router/run.sh [--setup-only] [file ...]
#         no files → lints the JS/TS you changed (vs the repo's default branch + working tree + untracked).
#         --setup-only → prepare the profile's config (for the SessionStart hook); no linting.
#
# Deps + synced rule files live in a STABLE, configurable runtime dir (NOT the versioned plugin dir),
# so they survive plugin updates and the generated repo-config path stays valid:
#   LINT_ROUTER_STATE_DIR  (default: ${XDG_STATE_HOME:-~/.claude/state}/lint-router)
set -uo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # shipped source (versioned plugin dir)
STATE_DIR="${LINT_ROUTER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.claude/state}/lint-router}"   # stable runtime

SETUP_ONLY=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --setup-only) SETUP_ONLY=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# --- Locate the repo -----------------------------------------------------------
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { [ "$SETUP_ONLY" = 1 ] && exit 0; echo "✗ not in a git repo"; exit 2; }
cd "$ROOT" || exit 2

has_angular_config() { [ -f eslint.config.mjs ] && grep -q "@angular-eslint" eslint.config.mjs 2>/dev/null; }

# --- Classify the repo into a profile (THE extension point) --------------------
# Returns: slate | personal | skip
classify_profile() {
  local origin; origin="$(git remote get-url origin 2>/dev/null || true)"
  if has_angular_config; then
    echo slate; return                       # Slate web-app → curated overlay
  fi
  case "$origin" in
    *slateteams/*|*Slate-WebApp*)
      echo skip; return ;;                    # other Slate team repo → hands off (no imposed lint)
    # --- add future org/profile branches here, e.g.  *someorg/*) echo someprofile ;;  ---
  esac
  echo personal                               # your repos / anything else → full unicorn
}

PROFILE="$(classify_profile)"

# --- Ensure deps + synced configs in the STABLE runtime dir (idempotent) -------
# Sync the shipped rule/dep files from the (versioned) plugin dir into $STATE_DIR,
# then npm-install there. Re-syncs + reinstalls only when the shipped files change
# (a plugin update), so a version bump doesn't force a needless reinstall, and the
# generated repo config (which points at $STATE_DIR) keeps working across updates.
ensure_deps() {
  mkdir -p "$STATE_DIR"
  local f deps_changed=0
  for f in package.json package-lock.json overlay-rules.mjs personal-config.mjs; do
    if [ -f "$TOOL_DIR/$f" ] && ! cmp -s "$TOOL_DIR/$f" "$STATE_DIR/$f" 2>/dev/null; then
      cp "$TOOL_DIR/$f" "$STATE_DIR/$f"
      case "$f" in package.json|package-lock.json) deps_changed=1 ;; esac
    fi
  done
  if [ "$deps_changed" = 1 ] || [ ! -x "$STATE_DIR/node_modules/.bin/eslint" ] || [ ! -d "$STATE_DIR/node_modules/eslint-plugin-unicorn" ]; then
    [ "$SETUP_ONLY" = 1 ] || echo "→ installing lint deps (one-time) in $STATE_DIR …"
    ( cd "$STATE_DIR" && npm install --no-audit --no-fund >/dev/null 2>&1 ) || { echo "✗ lint deps install failed"; exit 2; }
  fi
}

# --- Per-profile setup ---------------------------------------------------------
setup_slate() {
  ensure_deps
  if [ ! -f eslint.unicorn.mjs ]; then
    cat > eslint.unicorn.mjs <<EOF
// AUTO-GENERATED personal overlay (gitignored) — Slate's linting + a vetted unicorn correctness subset.
// Managed by the lint-router plugin. Safe to delete; regenerated on next run. Do NOT commit.
import base from './eslint.config.mjs';
import unicornOverlay from '$STATE_DIR/overlay-rules.mjs';
export default [...base, ...unicornOverlay];
EOF
  fi
  # Keep it out of git without touching the shared .gitignore (worktree-safe: .git may be a file).
  local exclude; exclude="$(git rev-parse --git-path info/exclude 2>/dev/null)"
  if [ -n "$exclude" ]; then
    mkdir -p "$(dirname "$exclude")"
    grep -qxF 'eslint.unicorn.mjs' "$exclude" 2>/dev/null || echo 'eslint.unicorn.mjs' >> "$exclude"
  fi
}
setup_personal() { ensure_deps; }   # standalone: nothing written into the repo

case "$PROFILE" in
  slate)    setup_slate ;;
  personal) setup_personal ;;
  skip)     [ "$SETUP_ONLY" = 1 ] || echo "✓ Slate team repo (not web-app) — no personal lint imposed."; exit 0 ;;
esac

if [ "$SETUP_ONLY" = 1 ]; then exit 0; fi

# --- Resolve target files (args, else changed JS/TS vs default branch + working tree + untracked) ---
resolve_base() {
  local b
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"     # e.g. origin/main, origin/develop
  [ -n "$b" ] && { echo "$b"; return; }
  local c; for c in origin/develop origin/main origin/master main master; do
    git rev-parse --verify --quiet "$c" >/dev/null 2>&1 && { echo "$c"; return; }
  done
  echo HEAD
}

# Profile-specific file filter: Slate lints src/*.ts (CI's scope); personal lints any JS/TS.
case "$PROFILE" in
  slate)    FILTER='^src/.*\.ts$' ;;
  personal) FILTER='\.(ts|tsx|js|jsx|mjs|cjs)$' ;;
esac

FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
  BASE="$(resolve_base)"; MB="$(git merge-base HEAD "$BASE" 2>/dev/null || echo HEAD)"
  FILES=()
  while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(
    { git diff --name-only --diff-filter=d "$MB" HEAD;
      git diff --name-only --diff-filter=d;
      git diff --cached --name-only --diff-filter=d;
      git ls-files --others --exclude-standard; } 2>/dev/null \
    | sort -u | grep -E "$FILTER" | grep -vE '(^|/)(node_modules|dist|build|out|coverage|vendor)/'
  )
fi
if [ ${#FILES[@]} -eq 0 ]; then echo "✓ no changed ${PROFILE/slate/src\/*.ts}${PROFILE/personal/JS\/TS} files to check."; exit 0; fi

# --- Lint per profile ----------------------------------------------------------
echo "→ [$PROFILE] unicorn lint on ${#FILES[@]} changed file(s)…"
OUT="$(mktemp)"
if [ "$PROFILE" = slate ]; then
  NODE_OPTIONS=--max-old-space-size=6144 npx eslint --config eslint.unicorn.mjs --format json "${FILES[@]}" > "$OUT" 2>/dev/null
else
  NODE_OPTIONS=--max-old-space-size=6144 "$STATE_DIR/node_modules/.bin/eslint" \
    --no-config-lookup --config "$STATE_DIR/personal-config.mjs" --format json "${FILES[@]}" > "$OUT" 2>/dev/null
fi

PROFILE="$PROFILE" node - "$OUT" <<'NODE'
const fs = require('fs');
const profile = process.env.PROFILE;
let data; try { data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')); }
catch { console.log('(eslint produced no parseable output — check the config/paths)'); process.exit(0); }
let uni = [], otherErr = 0;
for (const f of data) for (const m of f.messages) {
  if (m.ruleId && m.ruleId.startsWith('unicorn/')) uni.push({ file: f.filePath.replace(process.cwd() + '/', ''), line: m.line, sev: m.severity, rule: m.ruleId.replace('unicorn/', ''), msg: m.message });
  else if (m.severity === 2) otherErr++;
}
if (!uni.length) { console.log('✓ no unicorn findings on the changed files.'); }
else {
  const err = uni.filter(u => u.sev === 2), warn = uni.filter(u => u.sev === 1);
  console.log(`\nunicorn: ${err.length} error(s), ${warn.length} warning(s)\n`);
  const show = (list, label) => { if (!list.length) return; console.log(label); for (const u of list) console.log(`  ${u.file}:${u.line}  [${u.rule}] ${u.msg}`); console.log(''); };
  if (profile === 'slate') {
    show(err, 'ERRORS (verified-safe correctness — fix these; isNaN/isFinite need Number.isNaN by hand):');
    show(warn, "WARNINGS (review, don't blind --fix — the fix can change behavior):");
  } else {
    show(err, 'ERRORS (full unicorn suite — your repo, your call):');
    show(warn, 'WARNINGS:');
  }
}
if (otherErr) console.log(`(also ${otherErr} non-unicorn eslint error(s).)`);
if (profile === 'slate') {
  console.log("\nReminder: apply fixes deliberately, re-run `pnpm run typecheck`. Never blanket `eslint --fix` —");
  console.log('the OFF rules in this overlay are auto-fixes that break this codebase (e.g. prefer-https corrupts the SVG namespace).');
} else {
  console.log('\nThis is your repo\'s full unicorn lint (flat/all). `eslint --fix` via this tool can auto-fix many of these,');
  console.log('but review DOM/URL rewrites (e.g. prefer-https on a namespace/real http URL) before accepting.');
}
NODE
rm -f "$OUT"
