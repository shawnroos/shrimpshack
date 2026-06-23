#!/usr/bin/env bash
#
# smoke.sh — fast, dependency-free checks for spinoff.sh's arg-validation,
# session-transcript passthrough, and back-compat. Exercises everything that
# runs BEFORE the cmux automation (which is gated on CMUX_WORKSPACE_ID, unset
# here), so it needs no cmux and no real Claude session — just git.
#
# Run: bash smoke.sh   →   exits 0 if all checks pass, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SPINOFF="$HERE/spinoff.sh"
PASS=0 FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

# Isolated git repo + a handoff fixture; cmux automation disabled.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && git init -q && git config user.email s@s.s && git config user.name s \
    && git commit -q --allow-empty -m init ) || { echo "git setup failed"; exit 1; }
HANDOFF="$WORK/handoff.md"
printf '# Spinoff: smoke\n## Source session\n<!-- SESSION -->\n' > "$HANDOFF"
run() { ( cd "$WORK" && unset CMUX_WORKSPACE_ID && bash "$SPINOFF" "$@" 2>&1 ); }

echo "spinoff.sh smoke checks:"

# 1. Arg validation (each must exit non-zero).
run --handoff "$HANDOFF" >/dev/null 2>&1 && bad "missing --name should fail" || ok "missing --name rejected"
run --name a >/dev/null 2>&1 && bad "missing --handoff should fail" || ok "missing --handoff rejected"
run --name a --handoff /no/such/file >/dev/null 2>&1 && bad "missing handoff file should fail" || ok "missing handoff file rejected"
out="$(run --name a --handoff "$HANDOFF" --target bogus)"
echo "$out" | grep -q "invalid --target" && ok "invalid --target rejected with message" || bad "invalid --target not rejected: $out"

# 2. Explicit session passthrough → resume line uses the passed cwd + UUID.
touch "$WORK/sess.jsonl"
out="$(run --name feat-pass --handoff "$HANDOFF" --session-transcript "$WORK/sess.jsonl" --session-cwd /tmp/originating)"
resume="$(grep -h 'Resume:' "$WORK/worktrees/feat-pass/docs/handoff.md" 2>/dev/null)"
echo "$resume" | grep -q "cd /tmp/originating && claude -r sess" \
  && ok "resume line uses --session-cwd and transcript UUID" \
  || bad "resume line wrong: ${resume:-<none>}"

# 3. Missing --session-transcript file → warns (does not silently fall through).
out="$(run --name feat-warn --handoff "$HANDOFF" --session-transcript /tmp/nope-$$.jsonl)"
echo "$out" | grep -q "not found — falling back to auto-discovery" \
  && ok "missing --session-transcript warns loudly" \
  || bad "missing --session-transcript did not warn"

# 4. Back-compat: old-only flags still produce a worktree + handoff.
run --name feat-compat --handoff "$HANDOFF" >/dev/null 2>&1
[ -f "$WORK/worktrees/feat-compat/docs/handoff.md" ] \
  && ok "old-only flags still create worktree + handoff" \
  || bad "back-compat worktree/handoff missing"

# 5. Label default → "<repo-basename>/<name>" when --label omitted.
repo_base="$(basename "$WORK")"
out="$(run --name feat-deflabel --handoff "$HANDOFF")"
echo "$out" | grep -q "label:       $repo_base/feat-deflabel" \
  && ok "label defaults to <repo>/<name>" \
  || bad "default label wrong: $(echo "$out" | grep -i 'label:' || echo '<none>')"

# 6. Explicit --label is used verbatim.
out="$(run --name feat-label --handoff "$HANDOFF" --label 'smoke·work')"
echo "$out" | grep -q "label:       smoke·work" \
  && ok "explicit --label used verbatim" \
  || bad "explicit label wrong: $(echo "$out" | grep -i 'label:' || echo '<none>')"

echo "-------------------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
