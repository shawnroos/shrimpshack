#!/usr/bin/env bash
#
# harness.sh — pre-merge tests for the reflect-qmd-store work. Runs entirely
# against an ISOLATED qmd config (a temp dir with its own `qmd init` .qmd, which
# shadows the global ~/.config/qmd) and isolated memory/doc-store fixtures. It
# NEVER touches the operator's live qmd config, live MEMORY.md, or live settings.
#
# Exits non-zero on the first failed assertion (set -e + explicit fails).
#
# Why this exists: the edited skill/hooks only go live after merge, so the
# value-carrying behaviors (reconciler idempotency + foreign-safety, the hook's
# once-per-session/bounded/fail-safe behavior, lint budget enforcement, the
# migration) can't be exercised via a real /reflect in-worktree. This harness
# exercises the scripts directly so they're verified before merge.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # tests/ is one level under plugin root
SCRIPTS="$REPO/scripts"
HOOKS="$REPO/hooks"
PASS=0; FAIL=0
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/reflect-harness.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1" >&2; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# qmd reads can transiently lag under heavy sequential load (sqlite); retry the
# existence check so a qmd timing hiccup isn't reported as a logic failure.
has_collection(){ local n; for n in 1 2 3 4 5; do qmd collection list 2>/dev/null | grep -q "$1" && return 0; sleep 1; done; return 1; }

if ! command -v qmd >/dev/null 2>&1; then
  echo "harness: qmd not on PATH — skipping qmd-dependent tests" >&2
fi

# ------------------------------------------------------------------ reconciler
echo "== reconciler =="
if command -v qmd >/dev/null 2>&1; then
  R="$ROOT/recon"; mkdir -p "$R"; cd "$R"
  qmd init >/dev/null 2>&1
  mkdir -p mem doc-store/brainstorms doc-store/handoffs foreign
  printf '# m\nalpha memory\n' > mem/m1.md
  printf '# b\nbeta brainstorm\n' > doc-store/brainstorms/b1.md
  printf '# h\nhandoff note\n' > doc-store/handoffs/h1.md
  printf '# f\nforeign content\n' > foreign/f1.md
  # seed a foreign (non-claude-) collection that must remain untouched
  qmd collection add ./foreign >/dev/null 2>&1
  qmd collection rename foreign keepme-foreign >/dev/null 2>&1

  export QMD_RECONCILE_MEMORY_DIR="$R/mem"
  export QMD_RECONCILE_DOC_STORE="$R/doc-store"
  export QMD_RECONCILE_NO_EMBED=1
  bash "$SCRIPTS/qmd-reconcile-collections.sh" >/dev/null 2>&1
  check "claude-memory created"      "has_collection 'claude-memory'"
  check "claude-brainstorms created" "has_collection 'claude-brainstorms'"
  check "claude-handoffs created"    "has_collection 'claude-handoffs'"
  check "foreign collection untouched" "has_collection 'keepme-foreign'"

  # Compare the SET of collection NAMES (the list output also carries volatile
  # "Updated: Ns ago" timestamps, which is not a state change).
  names() { qmd collection list 2>/dev/null | grep '(qmd://' | awk '{print $1}' | sort; }
  BEFORE="$(names)"
  bash "$SCRIPTS/qmd-reconcile-collections.sh" >/dev/null 2>&1
  AFTER="$(names)"
  check "idempotent: second run adds no collections" '[ "$BEFORE" = "$AFTER" ]'
  N_CLAUDE_MEM="$(echo "$AFTER" | grep -c 'claude-memory' || true)"
  check "no duplicate claude-memory" '[ "$N_CLAUDE_MEM" = "1" ]'

  mkdir -p doc-store/solutions; printf '# s\ngamma solution\n' > doc-store/solutions/s1.md
  bash "$SCRIPTS/qmd-reconcile-collections.sh" >/dev/null 2>&1
  check "new doc-type auto-registers (claude-solutions)" "has_collection 'claude-solutions'"
  unset QMD_RECONCILE_MEMORY_DIR QMD_RECONCILE_DOC_STORE QMD_RECONCILE_NO_EMBED
  cd "$REPO"
fi
# qmd-absent fallback (runs regardless of env): reconciler skips cleanly, exit 0
if PATH="/usr/bin:/bin" bash "$SCRIPTS/qmd-reconcile-collections.sh" >/dev/null 2>&1; then
  ok "reconciler skips cleanly when qmd is absent (exit 0)"
else
  bad "reconciler exits non-zero when qmd is absent (should skip)"
fi

# --------------------------------------------------------------- seeded recall
echo "== seeded-recall hook =="
if command -v qmd >/dev/null 2>&1; then
  H="$ROOT/recall"; mkdir -p "$H/mem"; cd "$H"
  qmd init >/dev/null 2>&1
  printf '# Widget pipeline\nThe widget pipeline batches frobnicators nightly.\n' > mem/widget.md
  printf '# Unrelated\nCats and dogs and weather.\n' > mem/other.md
  qmd collection add ./mem >/dev/null 2>&1
  qmd collection rename mem claude-memory >/dev/null 2>&1

  FLAG="$H/flags"
  export SEEDED_RECALL_COLLECTION=claude-memory SEEDED_RECALL_FLAG_DIR="$FLAG" SEEDED_RECALL_K=3 SEEDED_RECALL_TIMEOUT=20
  # BM25 is lexical/exact-term — the seed query must share literal terms with the
  # body (the accepted lexical-seed tradeoff; natural-language prompts with
  # morphological variants under-recall and the hook then stays silent by design).
  OUT1="$(printf '{"prompt":"widget pipeline batches frobnicators","session_id":"S1"}' | bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  check "recall injects the relevant body" "echo \"\$OUT1\" | grep -qi 'widget pipeline batches frobnicators'"
  check "recall emits the wrapper tag" "echo \"\$OUT1\" | grep -q 'recalled-memories'"
  OUT2="$(printf '{"prompt":"widget pipeline again","session_id":"S1"}' | bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  check "once-per-session: same session_id re-fires nothing" '[ -z "$OUT2" ]'
  OUT3="$(printf '{"prompt":"widget pipeline","session_id":"S2"}' | bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  check "new session_id fires again" "echo \"\$OUT3\" | grep -qi 'widget'"
  # fail-safe: qmd not on PATH
  OUT4="$(printf '{"prompt":"widget","session_id":"S3"}' | PATH="/usr/bin:/bin" SEEDED_RECALL_FLAG_DIR="$FLAG" bash "$HOOKS/seeded-recall.sh" 2>/dev/null; echo "EXIT:$?")"
  check "fail-safe when qmd absent: exit 0, no output" "echo \"\$OUT4\" | grep -q '^EXIT:0$' && [ \"\$(echo \"\$OUT4\" | grep -v '^EXIT:')\" = '' ]"
  # cumulative wall-budget exhausted -> exit 0, no output (never blocks the prompt)
  OUT5="$(printf '{"prompt":"widget pipeline","session_id":"S5"}' | SEEDED_RECALL_TIMEOUT=0.01 SEEDED_RECALL_FLAG_DIR="$FLAG" bash "$HOOKS/seeded-recall.sh" 2>/dev/null; echo "EXIT:$?")"
  check "budget exhausted: exit 0, no output" "echo \"\$OUT5\" | grep -q '^EXIT:0$' && [ \"\$(echo \"\$OUT5\" | grep -v '^EXIT:')\" = '' ]"
  # empty first prompt must NOT set the flag -> a later matching prompt still fires
  OUT6A="$(printf '{"prompt":"zzznomatchxyz","session_id":"SR"}' | SEEDED_RECALL_FLAG_DIR="$FLAG" SEEDED_RECALL_TIMEOUT=20 bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  OUT6B="$(printf '{"prompt":"widget pipeline batches frobnicators","session_id":"SR"}' | SEEDED_RECALL_FLAG_DIR="$FLAG" SEEDED_RECALL_TIMEOUT=20 bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  check "empty first prompt does not burn the session (retry fires)" '[ -z "$OUT6A" ] && echo "$OUT6B" | grep -qi widget'
  unset SEEDED_RECALL_COLLECTION SEEDED_RECALL_FLAG_DIR SEEDED_RECALL_K SEEDED_RECALL_TIMEOUT
  cd "$REPO"
fi

# ----------------------------------------------------------------------- lint
echo "== memory-index-lint =="
L="$ROOT/lint"; mkdir -p "$L"; cd "$L"
# clean, in-budget, parity-clean index
printf 'a body\n' > a.md; printf 'b body\n' > b.md
printf '# Memory Index\n\n- [a](a.md) — hook a\n- [b](b.md) — hook b\n' > MEMORY.md
if MEMORY_INDEX="$L/MEMORY.md" MEMORY_DIR="$L" bash "$SCRIPTS/memory-index-lint.sh" >/dev/null 2>&1; then
  ok "lint passes a clean in-budget index"
else
  bad "lint passes a clean in-budget index"
fi
# over the line budget
{ echo '# Memory Index'; echo; for i in $(seq 1 250); do echo "- [x$i](a.md) — h"; done; } > BIG.md
if MEMORY_INDEX="$L/BIG.md" MEMORY_DIR="$L" MAX_LINES=200 bash "$SCRIPTS/memory-index-lint.sh" >/dev/null 2>&1; then
  bad "lint fails an over-line-budget index"
else
  ok "lint fails an over-line-budget index"
fi
# over the byte budget
{ echo '# Memory Index'; echo; python3 -c "print('- [x](a.md) — ' + 'z'*30000)"; } > FAT.md
if MEMORY_INDEX="$L/FAT.md" MEMORY_DIR="$L" MAX_BYTES=25600 bash "$SCRIPTS/memory-index-lint.sh" >/dev/null 2>&1; then
  bad "lint fails an over-byte-budget index"
else
  ok "lint fails an over-byte-budget index"
fi
cd "$REPO"

# ------------------------------------------------------------------ migration
echo "== migration =="
G="$ROOT/migrate"; mkdir -p "$G"; cd "$G"
for i in $(seq 1 40); do
  printf 'body %d\n' "$i" > "feedback_topic_$i.md"
done
printf 'orphan body\n' > "feedback_orphan.md"           # body with NO index entry
{ echo '# Memory Index'; echo; for i in $(seq 1 40); do
    echo "## Topic $i heading"
    echo "- See [feedback_topic_$i.md](feedback_topic_$i.md) — $(python3 -c "print('verbose '*40)") see also [other.md](feedback_topic_1.md)"
    echo
  done
  echo "## Dead one"; echo "- See [feedback_gone.md](feedback_gone.md) — body was deleted"; } > MEMORY.md
MEMORY_DIR="$G" python3 "$SCRIPTS/migrate-memory-index.py" "$G/MEMORY.md" >/dev/null 2>&1
B="$(wc -c < MEMORY.md | tr -d ' ')"; LN="$(wc -l < MEMORY.md | tr -d ' ')"
check "migrated index under 25600 bytes" '[ "$B" -lt 25600 ]'
check "migrated index under/eq 200 lines" '[ "$LN" -le 200 ]'
check "migration drops the dead pointer (no body file)" "! grep -q 'feedback_gone.md' MEMORY.md"
check "migration adds the orphan body file" "grep -q 'feedback_orphan.md' MEMORY.md"
check "migrated index parity-clean" "MEMORY_INDEX=\"$G/MEMORY.md\" MEMORY_DIR=\"$G\" bash \"$SCRIPTS/memory-index-lint.sh\" >/dev/null 2>&1"
# idempotency: a second run reproduces byte-for-byte
CK1="$(md5 -q MEMORY.md 2>/dev/null || md5sum MEMORY.md | awk '{print $1}')"
MEMORY_DIR="$G" python3 "$SCRIPTS/migrate-memory-index.py" "$G/MEMORY.md" >/dev/null 2>&1
CK2="$(md5 -q MEMORY.md 2>/dev/null || md5sum MEMORY.md | awk '{print $1}')"
check "migration is idempotent (second run byte-stable)" '[ "$CK1" = "$CK2" ]'
# strict-lint must NOT false-positive on the in-hook markdown link
check "strict lint clean despite in-hook link" "MEMORY_INDEX=\"$G/MEMORY.md\" MEMORY_DIR=\"$G\" bash \"$SCRIPTS/memory-index-lint.sh\" --strict >/dev/null 2>&1"
# gut-guard: populated index + empty memory dir -> ABORT, original unchanged
GG="$ROOT/migrate-gut"; mkdir -p "$GG/idx" "$GG/empty"
printf '# Memory Index\n\n- [a](a.md) — h\n- [b](b.md) — h\n' > "$GG/idx/MEMORY.md"
GK1="$(md5 -q "$GG/idx/MEMORY.md" 2>/dev/null || md5sum "$GG/idx/MEMORY.md" | awk '{print $1}')"
if MEMORY_DIR="$GG/empty" python3 "$SCRIPTS/migrate-memory-index.py" "$GG/idx/MEMORY.md" >/dev/null 2>&1; then
  bad "migration aborts when memory dir is empty but index has entries"
else
  ok "migration aborts when memory dir is empty but index has entries"
fi
GK2="$(md5 -q "$GG/idx/MEMORY.md" 2>/dev/null || md5sum "$GG/idx/MEMORY.md" | awk '{print $1}')"
check "gut-guard leaves the original index untouched" '[ "$GK1" = "$GK2" ]'
cd "$REPO"

# ------------------------------------------------- opt-in setup (/reflect-setup)
# The plugin wires hooks declaratively; setup.sh does only the opt-in live edits
# (doc-store scaffold + MEMORY.md migration + CLAUDE.md patch + collections). Run
# it fully isolated: isolated CLAUDE_HOME, memory dir, doc-store, and (via a
# project-local qmd index in cwd) an isolated qmd config — never the live one.
echo "== opt-in setup (isolated) =="
S="$ROOT/live"; MEM="$S/projects/slug/memory"; mkdir -p "$MEM" "$S/qmdcwd"
( cd "$S/qmdcwd" && qmd init >/dev/null 2>&1 ) 2>/dev/null
printf '# Guidelines\n\n## Memory Protocol\n\nold protocol prose.\n\n## Workflow\n\nkeep me.\n' > "$S/CLAUDE.md"
printf 'body a\n' > "$MEM/a.md"
printf '# Memory Index\n\n## A heading\n- See [a.md](a.md) — %s\n' "$(python3 -c 'print("verbose "*60)')" > "$MEM/MEMORY.md"
run_setup() { ( cd "$S/qmdcwd" && CLAUDE_HOME="$S" REFLECT_MEMORY_DIR="$MEM" REFLECT_DOC_STORE="$S/doc-store" QMD_RECONCILE_NO_EMBED=1 bash "$SCRIPTS/setup.sh" >/dev/null 2>&1 ); }
run_setup
check "setup scaffolds the doc-store" "[ -d '$S/doc-store/brainstorms' ] && [ -d '$S/doc-store/solutions' ]"
check "setup migrates MEMORY.md under budget" "[ \"\$(wc -c < '$MEM/MEMORY.md' | tr -d ' ')\" -lt 25600 ]"
check "setup patches CLAUDE.md Memory Protocol" "grep -q 'QMD is the recall layer' '$S/CLAUDE.md'"
check "setup preserves the following CLAUDE.md section" "grep -q '## Workflow' '$S/CLAUDE.md' && grep -q 'keep me' '$S/CLAUDE.md'"
PC1="$(md5 -q "$S/CLAUDE.md" 2>/dev/null || md5sum "$S/CLAUDE.md" | awk '{print $1}')"
MC1="$(md5 -q "$MEM/MEMORY.md" 2>/dev/null || md5sum "$MEM/MEMORY.md" | awk '{print $1}')"
run_setup
PC2="$(md5 -q "$S/CLAUDE.md" 2>/dev/null || md5sum "$S/CLAUDE.md" | awk '{print $1}')"
MC2="$(md5 -q "$MEM/MEMORY.md" 2>/dev/null || md5sum "$MEM/MEMORY.md" | awk '{print $1}')"
check "setup is idempotent (CLAUDE.md + index byte-stable on re-run)" '[ "$PC1" = "$PC2" ] && [ "$MC1" = "$MC2" ]'
# ambiguous CLAUDE.md (two Memory Protocol headings) -> skip, unchanged
A="$ROOT/ambig"; mkdir -p "$A"
printf '## Memory Protocol\n\none\n\n## X\n\n## Memory Protocol\n\ntwo\n' > "$A/CLAUDE.md"
B4="$(md5 -q "$A/CLAUDE.md" 2>/dev/null || md5sum "$A/CLAUDE.md" | awk '{print $1}')"
CLAUDE_MD="$A/CLAUDE.md" bash "$SCRIPTS/apply-memory-protocol.sh" "$REPO/docs/memory-protocol-update.md" >/dev/null 2>&1
AF="$(md5 -q "$A/CLAUDE.md" 2>/dev/null || md5sum "$A/CLAUDE.md" | awk '{print $1}')"
check "ambiguous CLAUDE.md left untouched (manual)" '[ "$B4" = "$AF" ]'
# fence-aware: a '## ' INSIDE a code fence within the section must not truncate the splice
FC="$ROOT/fence"; mkdir -p "$FC"
printf '## Memory Protocol\n\nintro\n\n```\n## not a heading\n```\n\nmore protocol\n\n## RealNext\n\nkeep me\n' > "$FC/CLAUDE.md"
CLAUDE_MD="$FC/CLAUDE.md" bash "$SCRIPTS/apply-memory-protocol.sh" "$REPO/docs/memory-protocol-update.md" >/dev/null 2>&1
check "fence-aware patch replaces the whole section" "grep -q 'QMD is the recall layer' '$FC/CLAUDE.md'"
check "fence-aware patch preserves the following section" "grep -q 'keep me' '$FC/CLAUDE.md' && grep -q '## RealNext' '$FC/CLAUDE.md'"
check "fence-aware patch consumed the fenced pseudo-heading" "! grep -q 'not a heading' '$FC/CLAUDE.md'"
# unbalanced fence inside the section -> skip (must NOT silently delete the trailing section)
UF="$ROOT/unfence"; mkdir -p "$UF"
printf '## Memory Protocol\n\nintro\n\n```\nunclosed fence\n\n## RealNext\n\nkeep me\n' > "$UF/CLAUDE.md"
UK1="$(md5 -q "$UF/CLAUDE.md" 2>/dev/null || md5sum "$UF/CLAUDE.md" | awk '{print $1}')"
CLAUDE_MD="$UF/CLAUDE.md" bash "$SCRIPTS/apply-memory-protocol.sh" "$REPO/docs/memory-protocol-update.md" >/dev/null 2>&1
UK2="$(md5 -q "$UF/CLAUDE.md" 2>/dev/null || md5sum "$UF/CLAUDE.md" | awk '{print $1}')"
if [ "$UK1" = "$UK2" ] && grep -q 'keep me' "$UF/CLAUDE.md"; then
  ok "unbalanced fence: file left untouched (no silent deletion)"
else
  bad "unbalanced fence: file left untouched (no silent deletion)"
fi

# ---------------------------------------------------------------------- report
echo
echo "harness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
