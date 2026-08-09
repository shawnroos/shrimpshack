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
trap 'rm -rf "$ROOT" "${RR:-/nonexistent-xyzzy}"' EXIT   # RR: a real repo the backfill test makes outside $ROOT

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
  # seeded-recall now uses `qmd vsearch` (vector) — the Phase B spike showed BM25
  # under-recalls realistic prompts. Vector search needs embeddings, so embed the
  # isolated test collection first. qmd loads the embedding model PER PROCESS, and
  # each hook invocation is a fresh process, so every recall assertion below pays a
  # cold model load (seconds, up to ~20s on a busy machine). The tests run with a
  # generous wall budget (60s) so the cold-load tail can't flake the suite. (In
  # production this per-process cold load is the case for the warm-daemon upgrade —
  # see scripts/spikes/RESULTS.md.)
  qmd embed -c claude-memory >/dev/null 2>&1 || true

  FLAG="$H/flags"
  export SEEDED_RECALL_COLLECTION=claude-memory SEEDED_RECALL_FLAG_DIR="$FLAG" SEEDED_RECALL_K=3 SEEDED_RECALL_TIMEOUT=60
  # vsearch is semantic, so the seed prompt need not share literal terms with the
  # body — a paraphrase recalls (the whole point of the Phase B switch).
  OUT1="$(printf '{"prompt":"widget pipeline batches frobnicators","session_id":"S1"}' | bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  check "recall injects the relevant body" "echo \"\$OUT1\" | grep -qi 'widget pipeline batches frobnicators'"
  check "recall emits the wrapper tag" "echo \"\$OUT1\" | grep -q 'recalled-memories'"
  OUT2="$(printf '{"prompt":"widget pipeline again","session_id":"S1"}' | bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  check "once-per-session: same session_id re-fires nothing" '[ -z "$OUT2" ]'
  OUT3="$(printf '{"prompt":"widget pipeline","session_id":"S2"}' | bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  check "new session_id fires again" "echo \"\$OUT3\" | grep -qi 'widget'"
  # fail-safe: qmd not on PATH. Isolated FLAG_DIR: this is a deliberate qmd-health
  # failure, and the (correct) cooldown stamp it writes would otherwise arm and
  # suppress the later real-qmd success assertions that share $FLAG.
  OUT4="$(printf '{"prompt":"widget","session_id":"S3"}' | PATH="/usr/bin:/bin" SEEDED_RECALL_FLAG_DIR="$FLAG-absent" bash "$HOOKS/seeded-recall.sh" 2>/dev/null; echo "EXIT:$?")"
  check "fail-safe when qmd absent: exit 0, no output" "echo \"\$OUT4\" | grep -q '^EXIT:0$' && [ \"\$(echo \"\$OUT4\" | grep -v '^EXIT:')\" = '' ]"
  # cumulative wall-budget exhausted -> exit 0, no output (never blocks the prompt).
  # Isolated FLAG_DIR for the same reason (a timeout is a health failure that stamps).
  OUT5="$(printf '{"prompt":"widget pipeline","session_id":"S5"}' | SEEDED_RECALL_TIMEOUT=0.01 SEEDED_RECALL_FLAG_DIR="$FLAG-budget" bash "$HOOKS/seeded-recall.sh" 2>/dev/null; echo "EXIT:$?")"
  check "budget exhausted: exit 0, no output" "echo \"\$OUT5\" | grep -q '^EXIT:0$' && [ \"\$(echo \"\$OUT5\" | grep -v '^EXIT:')\" = '' ]"
  # A no-output first prompt must NOT set the flag -> a later matching prompt still
  # fires. Vector search always returns nearest neighbours (no BM25-style empty),
  # so "no output" is forced via a score floor: the distant prompt scores below it
  # (filtered to nothing), the strong prompt clears it.
  OUT6A="$(printf '{"prompt":"zzznomatchxyz","session_id":"SR"}' | SEEDED_RECALL_FLAG_DIR="$FLAG" SEEDED_RECALL_MIN_SCORE=0.6 SEEDED_RECALL_TIMEOUT=60 bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  OUT6B="$(printf '{"prompt":"widget pipeline batches frobnicators","session_id":"SR"}' | SEEDED_RECALL_FLAG_DIR="$FLAG" SEEDED_RECALL_MIN_SCORE=0.6 SEEDED_RECALL_TIMEOUT=60 bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  check "no-output first prompt does not burn the session (retry fires)" '[ -z "$OUT6A" ] && echo "$OUT6B" | grep -qi widget'

  # U6 activation floor — proves the floor ENGAGES (the activation module actually
  # loads via SCOPED_MEMORY_DIR and filters), not just fails open. A fresh body
  # (last_used today -> activation ~1.3) and a faded body (last_used 2020 ->
  # activation ~0.3) both match the query; with an aggressive span the faded one's
  # required floor (~1.5) exceeds any vector score and it is dropped, while the
  # fresh one (required ~0.0) survives. Regression guard against the floor silently
  # reverting to dead code.
  printf -- '---\nlast_used: %s\n---\nThe widget pipeline batches frobnicators nightly FRESHTOKEN.\n' "$(date +%F)" > mem/wfresh.md
  printf -- '---\nlast_used: 2020-01-01\n---\nThe widget pipeline batches frobnicators nightly FADEDTOKEN.\n' > mem/wfaded.md
  qmd update >/dev/null 2>&1; qmd embed -c claude-memory >/dev/null 2>&1 || true  # re-scan: new files aren't indexed until update
  OUT7="$(printf '{"prompt":"widget pipeline batches frobnicators","session_id":"U6"}' | SEEDED_RECALL_FLAG_DIR="$FLAG" SEEDED_RECALL_MEMORY_DIR="$H/mem" SEEDED_RECALL_FLOOR_BASE=0.0 SEEDED_RECALL_FLOOR_SPAN=2.0 SEEDED_RECALL_K=5 SEEDED_RECALL_TIMEOUT=60 bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
  check "U6 floor engages: fresh (high-activation) memory surfaces" "echo \"\$OUT7\" | grep -q FRESHTOKEN"
  check "U6 floor engages: faded (low-activation) memory is filtered out" "! echo \"\$OUT7\" | grep -q FADEDTOKEN"

  unset SEEDED_RECALL_COLLECTION SEEDED_RECALL_FLAG_DIR SEEDED_RECALL_K SEEDED_RECALL_TIMEOUT
  cd "$REPO"
fi

# ------------------------------------------------ seeded-recall degrade (wedged qmd)
# These use a STUB `qmd` on PATH (no real qmd needed), so they run even when qmd is
# absent — and deterministically, without the cold-load flake real vsearch carries.
# Cover the failure-memory guard (cooldown stamp + threshold-2), the process-group
# kill (no orphans on timeout), and the shipped default budget firing on a healthy qmd.
echo "== seeded-recall degrade (wedged/healthy stubs) =="
SR="$ROOT/recall-degrade"; mkdir -p "$SR/bin" "$SR/flags" "$SR/mem"
# A wedged stub: hangs forever and spawns two long-lived grandchildren, recording
# their PIDs so the orphan test can check survival by PID. (macOS pgrep -f can't
# match a marker — /bin/sh exec-rewrites the sleep's argv — so PID + `kill -0` is
# the reliable probe.) The stub then `wait`s on them, so run()'s wall budget times
# out here. SR_PIDFILE is passed via env; it is truncated by whichever test cares.
export SR_PIDFILE="$SR/child-pids"; : > "$SR_PIDFILE"
cat > "$SR/bin/qmd" <<'STUB'
#!/usr/bin/env bash
sleep 300 & echo $! >> "$SR_PIDFILE"
sleep 300 & echo $! >> "$SR_PIDFILE"
wait
STUB
chmod +x "$SR/bin/qmd"
# A healthy stub: instant valid vsearch JSON + get body + empty status. Emits a
# unique token so the recall assertion is unambiguous.
cat > "$SR/bin/qmd-healthy" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  vsearch) printf '[{"file":"recall_stub_body.md","title":"Recall Stub","score":0.9}]' ;;
  get)     printf 'HEALTHYSTUBTOKEN body content\n' ;;
  status)  printf 'QMD Status\nPending: 0 need embedding\n' ;;
  *)       exit 0 ;;
esac
STUB
chmod +x "$SR/bin/qmd-healthy"
SR_WEDGED_PATH="$SR/bin:/usr/bin:/bin"
# count recorded child PIDs still alive
sr_alive() { local n=0 p; while read -r p; do [ -n "$p" ] && kill -0 "$p" 2>/dev/null && n=$((n+1)); done < "$1"; echo "$n"; }
sr_killall() { local p; [ -f "$SR_PIDFILE" ] && while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$SR_PIDFILE"; }
sr_elapsed_gt() { python3 -c 'import sys;sys.exit(0 if float(sys.argv[2])-float(sys.argv[1])>0.5 else 1)' "$1" "$2"; }
sr_elapsed_lt() { python3 -c 'import sys;sys.exit(0 if float(sys.argv[2])-float(sys.argv[1])<0.5 else 1)' "$1" "$2"; }
sr_now() { python3 -c 'import time;print(time.time())'; }

# --- U1: failure-memory guard (cooldown stamp + threshold-2) ---
F1="$SR/flags-cooldown"; mkdir -p "$F1"
# 1st wedged prompt: probes, times out, exits 0/no output, records failure #1
OUTW1="$(printf '{"prompt":"anything","session_id":"W1"}' | PATH="$SR_WEDGED_PATH" SEEDED_RECALL_FLAG_DIR="$F1" SEEDED_RECALL_TIMEOUT=1 bash "$HOOKS/seeded-recall.sh" 2>/dev/null; echo "EXIT:$?")"
check "wedged 1st prompt: exit 0, no output" "echo \"\$OUTW1\" | grep -q '^EXIT:0$' && [ \"\$(echo \"\$OUTW1\" | grep -v '^EXIT:')\" = '' ]"
# 2nd wedged prompt (different session): count==1 < threshold 2 -> still PROBES (not instant)
T1=$(sr_now)
printf '{"prompt":"anything","session_id":"W2"}' | PATH="$SR_WEDGED_PATH" SEEDED_RECALL_FLAG_DIR="$F1" SEEDED_RECALL_TIMEOUT=1 bash "$HOOKS/seeded-recall.sh" >/dev/null 2>&1
T2=$(sr_now)
check "wedged 2nd prompt still probes (transient tolerance, not suppressed)" "sr_elapsed_gt $T1 $T2"
# 3rd wedged prompt (different session): count>=2 -> suppressed INSTANTLY, no qmd call
T3=$(sr_now)
OUTW3="$(printf '{"prompt":"anything","session_id":"W3"}' | PATH="$SR_WEDGED_PATH" SEEDED_RECALL_FLAG_DIR="$F1" SEEDED_RECALL_TIMEOUT=1 bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
T4=$(sr_now)
check "cooldown armed on 2nd failure: 3rd prompt suppressed instantly" "[ -z \"\$OUTW3\" ] && sr_elapsed_lt $T3 $T4"
# FORCE bypasses an armed cooldown (still attempts qmd -> takes ~budget, not instant)
T5=$(sr_now)
printf '{"prompt":"anything","session_id":"W4"}' | PATH="$SR_WEDGED_PATH" SEEDED_RECALL_FLAG_DIR="$F1" SEEDED_RECALL_FORCE=1 SEEDED_RECALL_TIMEOUT=1 bash "$HOOKS/seeded-recall.sh" >/dev/null 2>&1
T6=$(sr_now)
check "cooldown: SEEDED_RECALL_FORCE=1 bypasses an armed stamp (still probes)" "sr_elapsed_gt $T5 $T6"

# --- U1: self-heal — a healthy probe clears a not-yet-armed stamp ---
# (An ARMED cooldown correctly suppresses even a healthy call until TTL — that's the
# circuit-breaker. The success-clear self-heal is exercised at count=1, before arming:
# one blip followed by a healthy prompt fully resets the streak.)
HEALPATH="$SR/healthybin"; mkdir -p "$HEALPATH"; cp "$SR/bin/qmd-healthy" "$HEALPATH/qmd"; chmod +x "$HEALPATH/qmd"
F2="$SR/flags-heal"; mkdir -p "$F2"
# one failure -> count=1 (not armed)
printf '{"prompt":"x","session_id":"H1"}' | PATH="$SR_WEDGED_PATH" SEEDED_RECALL_FLAG_DIR="$F2" SEEDED_RECALL_TIMEOUT=1 bash "$HOOKS/seeded-recall.sh" >/dev/null 2>&1
check "self-heal: a single failure records but does not arm" "[ -f \"$F2/qmd-failure-stamp\" ]"
# a healthy prompt is NOT suppressed at count=1 -> fires recall AND clears the stamp
OUTHEAL="$(printf '{"prompt":"x","session_id":"H2"}' | PATH="$HEALPATH:/usr/bin:/bin" SEEDED_RECALL_FLAG_DIR="$F2" SEEDED_RECALL_MEMORY_DIR="$SR/mem" bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
check "self-heal: healthy probe fires recall despite a not-yet-armed stamp" "echo \"\$OUTHEAL\" | grep -q HEALTHYSTUBTOKEN"
check "self-heal: healthy success clears the failure stamp" "[ ! -f \"$F2/qmd-failure-stamp\" ]"
# self-heal via TTL: an armed stamp older than COOLDOWN=0 is treated as expired -> probes
F3="$SR/flags-ttl"; mkdir -p "$F3"
printf '{"prompt":"x","session_id":"T1"}' | PATH="$SR_WEDGED_PATH" SEEDED_RECALL_FLAG_DIR="$F3" SEEDED_RECALL_TIMEOUT=1 bash "$HOOKS/seeded-recall.sh" >/dev/null 2>&1
printf '{"prompt":"x","session_id":"T2"}' | PATH="$SR_WEDGED_PATH" SEEDED_RECALL_FLAG_DIR="$F3" SEEDED_RECALL_TIMEOUT=1 bash "$HOOKS/seeded-recall.sh" >/dev/null 2>&1
T9=$(sr_now)
printf '{"prompt":"x","session_id":"T3"}' | PATH="$SR_WEDGED_PATH" SEEDED_RECALL_FLAG_DIR="$F3" SEEDED_RECALL_COOLDOWN=0 SEEDED_RECALL_TIMEOUT=1 bash "$HOOKS/seeded-recall.sh" >/dev/null 2>&1
T10=$(sr_now)
check "self-heal via TTL: expired stamp (COOLDOWN=0) re-probes" "sr_elapsed_gt $T9 $T10"
# fail-open on unwritable flag dir: point at a path under a regular FILE (can't mkdir)
printf 'x' > "$SR/notadir"
OUTFO="$(printf '{"prompt":"x","session_id":"FO"}' | PATH="$SR_WEDGED_PATH" SEEDED_RECALL_FLAG_DIR="$SR/notadir/sub" SEEDED_RECALL_TIMEOUT=1 bash "$HOOKS/seeded-recall.sh" 2>/dev/null; echo "EXIT:$?")"
check "fail-open: unwritable stamp dir still exits 0, no crash" "echo \"\$OUTFO\" | grep -q '^EXIT:0$'"

# --- U2: process-group kill — no orphaned qmd descendants after a timeout ---
F4="$SR/flags-orphan"; mkdir -p "$F4"
SR_BEFORE="$(grep -c . "$SR_PIDFILE" 2>/dev/null || echo 0)"   # snapshot ledger offset
printf '{"prompt":"x","session_id":"O1"}' | PATH="$SR_WEDGED_PATH" SEEDED_RECALL_FLAG_DIR="$F4" SEEDED_RECALL_TIMEOUT=1 bash "$HOOKS/seeded-recall.sh" >/dev/null 2>&1
sleep 0.5   # give any orphans a moment — if not group-killed they are still alive
tail -n +"$((SR_BEFORE+1))" "$SR_PIDFILE" > "$SR/orphan-new-pids" 2>/dev/null || : > "$SR/orphan-new-pids"
RECORDED="$(grep -c . "$SR/orphan-new-pids" 2>/dev/null || echo 0)"
ALIVE="$(sr_alive "$SR/orphan-new-pids")"
check "process-group kill: stub actually spawned children (test is live)" '[ "$RECORDED" -ge 1 ]'
check "process-group kill: no orphaned qmd descendants after timeout" '[ "$ALIVE" = "0" ]'

# --- U4: shipped default budget fires recall on a healthy qmd (no pinned TIMEOUT) ---
F5="$SR/flags-default"; mkdir -p "$F5"
OUTDEF="$(printf '{"prompt":"x","session_id":"D1"}' | PATH="$HEALPATH:/usr/bin:/bin" SEEDED_RECALL_FLAG_DIR="$F5" SEEDED_RECALL_MEMORY_DIR="$SR/mem" bash "$HOOKS/seeded-recall.sh" 2>/dev/null)"
check "shipped default budget: healthy recall fires with TIMEOUT unset" "echo \"\$OUTDEF\" | grep -q HEALTHYSTUBTOKEN"
check "shipped default budget: healthy success writes NO failure stamp" "[ ! -f \"$F5/qmd-failure-stamp\" ]"
sr_killall   # reap any grandchildren left by the wedged-stub tests above
cd "$REPO"

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

# ------------------------------------------------ activation + render unit tests
# Pure-Python suites (isolated tempdirs of their own): the activation arithmetic
# (U2) and the activation-ranked index render (U5 — hot/cold split, no-delete,
# idempotency, AE2 re-promotion, AE6 pin).
echo "== activation + render unit tests =="
if python3 "$REPO/tests/activation_test.py" >/dev/null 2>&1; then
  ok "activation_test.py passes"
else
  bad "activation_test.py passes"
fi
if python3 "$REPO/tests/render_test.py" >/dev/null 2>&1; then
  ok "render_test.py passes"
else
  bad "render_test.py passes"
fi

# Render integration: an over-budget index of many bodies renders to a hot/cold
# split that passes the (recalibrated) lint, with every body preserved on disk.
echo "== render integration =="
RN="$ROOT/render"; mkdir -p "$RN"; cd "$RN"
for i in $(seq 1 120); do
  printf -- '---\nlast_used: 2026-06-%02d\n---\nbody %d with a reasonably long hook sentence here\n' \
    "$(( (i % 28) + 1 ))" "$i" > "feedback_m$i.md"
done
printf '# Memory Index\n\n' > MEMORY.md
MEMORY_DIR="$RN" MAX_BYTES=4096 python3 "$SCRIPTS/memory-index-render.py" "$RN/MEMORY.md" >/dev/null 2>&1
HOT="$(grep -c '^- ' MEMORY.md)"
check "render produces a hot/cold split (fewer hot than total bodies)" '[ "$HOT" -lt 120 ] && [ "$HOT" -gt 0 ]'
check "every body file survives the render (none deleted)" '[ "$(ls feedback_m*.md | wc -l | tr -d " ")" = "120" ]'
check "rendered hot index passes the lint at the same budget" \
  "MEMORY_INDEX=\"$RN/MEMORY.md\" MEMORY_DIR=\"$RN\" MAX_BYTES=4096 bash \"$SCRIPTS/memory-index-lint.sh\" >/dev/null 2>&1"
RC1="$(md5 -q MEMORY.md 2>/dev/null || md5sum MEMORY.md | awk '{print $1}')"
MEMORY_DIR="$RN" MAX_BYTES=4096 python3 "$SCRIPTS/memory-index-render.py" "$RN/MEMORY.md" >/dev/null 2>&1
RC2="$(md5 -q MEMORY.md 2>/dev/null || md5sum MEMORY.md | awk '{print $1}')"
check "render is idempotent on the live-shaped fixture" '[ "$RC1" = "$RC2" ]'
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
# Regression lock (plan 003): a flat, repo-resolving, non-pointered body must NOT be
# moved by setup step 6 — proving step 6 runs the backfill DRY (never --apply).
SRR="$(mktemp -d "${TMPDIR:-/tmp}/srrXXXXXX")"; ( cd "$SRR" && git init -q )
SRSLUG="$(python3 "$REPO/scripts/scoped-memory/scope.py" "$SRR")"; SSID="33333333-3333-3333-3333-333333333333"
mkdir -p "$S/projects/$SRSLUG"; touch "$S/projects/$SRSLUG/$SSID.jsonl"
printf -- '---\nname: cand\nmetadata:\n  originSessionId: %s\n---\nflat repo-resolving body\n' "$SSID" > "$MEM/cand.md"
run_setup() { ( cd "$S/qmdcwd" && CLAUDE_HOME="$S" REFLECT_MEMORY_DIR="$MEM" REFLECT_DOC_STORE="$S/doc-store" QMD_RECONCILE_NO_EMBED=1 bash "$SCRIPTS/setup.sh" >/dev/null 2>&1 ); }
run_setup
check "setup step 6 creates _scope/ but moves NO bodies (backfill is dry, not --apply)" \
  "[ -d '$MEM/_scope' ] && [ -f '$MEM/cand.md' ] && [ ! -f '$MEM/_scope/$SRSLUG/cand.md' ]"
rm -rf "$SRR"
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

# ------------------------------------------------------- auto-memory dir pin
# setup.sh step 5 pins Claude Code's native auto-memory dir (autoMemoryDirectory)
# to the canonical store via $LIVE/settings.json. Run fully isolated (CLAUDE_HOME
# = $S) so the real ~/.claude/settings.json is never touched. run_setup discards
# stdout+stderr, so caveat/warning assertions use a capturing variant -> $PINOUT.
echo "== auto-memory pin =="
SET="$S/settings.json"
REAL="$HOME/.claude/settings.json"
REAL_BEFORE="$(md5 -q "$REAL" 2>/dev/null || md5sum "$REAL" 2>/dev/null | awk '{print $1}')"
pin_setup() { PINOUT="$( cd "$S/qmdcwd" && CLAUDE_HOME="$S" REFLECT_MEMORY_DIR="$MEM" REFLECT_DOC_STORE="$S/doc-store" QMD_RECONCILE_NO_EMBED=1 bash "$SCRIPTS/setup.sh" 2>&1 )"; }
pin_val() { python3 -c "import json,sys
try:
    print(json.load(open(sys.argv[1])).get('autoMemoryDirectory',''))
except Exception:
    print('')" "$SET" 2>/dev/null; }
pin_norm() { python3 -c "import os,sys;print(os.path.expanduser(sys.argv[1]).rstrip('/'))" "$1" 2>/dev/null; }
md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | awk '{print $1}'; }

# (a) writes the key when settings.json has other keys but no pin; preserves them;
#     backs up the pre-write file
printf '{\n  "$schema": "x",\n  "permissions": {"allow": []}\n}\n' > "$SET"
PRE_BAK="$(md5of "$SET")"
pin_setup
check "pin: writes key (normalizes to MEMDIR)" '[ "$(pin_norm "$(pin_val)")" = "$(pin_norm "$MEM")" ]'
check "pin: preserves existing keys" 'grep -q permissions "$SET" && grep -q schema "$SET"'
check "pin: caveat printed to stdout" 'echo "$PINOUT" | grep -q "effective on Claude Code >= 2.1.74"'
check "pin: backup created matching pre-write content" '[ -f "$SET.pre-auto-memory-pin.bak" ] && [ "$(md5of "$SET.pre-auto-memory-pin.bak")" = "$PRE_BAK" ]'

# (b) idempotent: settings.json byte-stable on re-run
PK1="$(md5 -q "$SET" 2>/dev/null || md5sum "$SET" | awk '{print $1}')"
pin_setup
PK2="$(md5 -q "$SET" 2>/dev/null || md5sum "$SET" | awk '{print $1}')"
check "pin: idempotent (settings byte-stable on re-run)" '[ "$PK1" = "$PK2" ]'

# (c) creates the file when missing
rm -f "$SET"
pin_setup
check "pin: creates settings.json when missing" '[ -f "$SET" ] && [ -n "$(pin_val)" ]'

# (d) empty / whitespace-only file treated as missing (not skipped as malformed)
printf '   \n' > "$SET"
pin_setup
check "pin: empty file treated as missing (key written)" '[ -n "$(pin_val)" ]'

# (e) no-clobber: a foreign value is preserved and a warning is emitted
printf '{\n  "autoMemoryDirectory": "/some/other/dir"\n}\n' > "$SET"
pin_setup
check "pin: no-clobber preserves foreign value" '[ "$(pin_val)" = "/some/other/dir" ]'
check "pin: no-clobber warns" 'echo "$PINOUT" | grep -qi "not the canonical store"'

# (f) normalized equality: a trailing-slash variant of the same dir is NOT clobbered
python3 -c "import json,sys;open(sys.argv[1],'w').write(json.dumps({'autoMemoryDirectory':sys.argv[2]+'/'}))" "$SET" "$MEM"
PN1="$(md5 -q "$SET" 2>/dev/null || md5sum "$SET" | awk '{print $1}')"
pin_setup
PN2="$(md5 -q "$SET" 2>/dev/null || md5sum "$SET" | awk '{print $1}')"
check "pin: normalized equality (trailing slash not clobbered/warned)" '[ "$PN1" = "$PN2" ] && ! echo "$PINOUT" | grep -qi "not the canonical store"'

# (g) malformed JSON: left unchanged, warned
printf '{ not json ' > "$SET"
MB1="$(md5 -q "$SET" 2>/dev/null || md5sum "$SET" | awk '{print $1}')"
pin_setup
MB2="$(md5 -q "$SET" 2>/dev/null || md5sum "$SET" | awk '{print $1}')"
check "pin: malformed JSON left unchanged + warned" '[ "$MB1" = "$MB2" ] && echo "$PINOUT" | grep -qi "not valid JSON"'

# (h) valid-but-non-object JSON: left unchanged (byte-stable), warned
printf '[]\n' > "$SET"
NO1="$(md5of "$SET")"
pin_setup
NO2="$(md5of "$SET")"
check "pin: non-object JSON left unchanged + warned" '[ "$NO1" = "$NO2" ] && echo "$PINOUT" | grep -qi "not an object"'

# (i) honors REFLECT_MEMORY_DIR override (a different target dir)
rm -f "$SET"; ALT="$ROOT/altmem"; mkdir -p "$ALT"
PINOUT="$( cd "$S/qmdcwd" && CLAUDE_HOME="$S" REFLECT_MEMORY_DIR="$ALT" REFLECT_DOC_STORE="$S/doc-store" QMD_RECONCILE_NO_EMBED=1 bash "$SCRIPTS/setup.sh" 2>&1 )"
check "pin: honors REFLECT_MEMORY_DIR override" '[ "$(pin_norm "$(pin_val)")" = "$(pin_norm "$ALT")" ]'

# Direct-helper invocations for path-form cases — fixtures live under $HOME via a
# synthetic HOME, which the full-setup runs (rooted in a temp dir outside $HOME)
# can't exercise. These prove the ~/-portability branch, not just normalization.
# (k) target under $HOME -> stores the ~/-prefixed RAW form (no hardcoded username)
HT="$ROOT/fakehome"; mkdir -p "$HT/.claude" "$HT/mem"
HOME="$HT" python3 "$SCRIPTS/pin-auto-memory-dir.py" "$HT/.claude/settings.json" "$HT/mem" >/dev/null 2>&1
pin_raw() { python3 -c "import json,sys
try: print(json.load(open(sys.argv[1])).get('autoMemoryDirectory',''))
except Exception: print('')" "$1" 2>/dev/null; }
check "pin: stores ~/-form when target under \$HOME" '[ "$(pin_raw "$HT/.claude/settings.json")" = "~/mem" ]'

# (l) prefix-but-not-subdir is kept absolute (HOME=/x/fakehome, target=/x/fakehomeSIB/mem)
HOME="$HT" python3 "$SCRIPTS/pin-auto-memory-dir.py" "$ROOT/sib.json" "${HT}sib/mem" >/dev/null 2>&1
check "pin: prefix-not-subdir kept absolute (no bogus ~)" '[ "$(pin_raw "$ROOT/sib.json")" = "${HT}sib/mem" ]'

# (m) stored ~/-form vs absolute target of the SAME dir -> no clobber, no warning
python3 -c "import json,sys;open(sys.argv[1],'w').write(json.dumps({'autoMemoryDirectory':'~/mem'}))" "$HT/.claude/settings.json"
MM1="$(md5of "$HT/.claude/settings.json")"
PINOUT2="$(HOME="$HT" python3 "$SCRIPTS/pin-auto-memory-dir.py" "$HT/.claude/settings.json" "$HT/mem" 2>&1)"
MM2="$(md5of "$HT/.claude/settings.json")"
check "pin: ~/-form vs absolute same dir not clobbered/warned" '[ "$MM1" = "$MM2" ] && ! echo "$PINOUT2" | grep -qi "not the canonical store"'

# (n) non-UTF-8 settings.json: fail-open (exit 0), unchanged, warned (never crashes)
printf '\xff\xfe not utf8 ' > "$SET"
NU1="$(md5of "$SET")"
PINOUT3="$(python3 "$SCRIPTS/pin-auto-memory-dir.py" "$SET" "$MEM" 2>&1)"; NUEXIT=$?
NU2="$(md5of "$SET")"
check "pin: non-UTF-8 fail-open (exit 0, unchanged, warned)" '[ "$NUEXIT" = "0" ] && [ "$NU1" = "$NU2" ] && echo "$PINOUT3" | grep -qi "could not read"'

# (o) live config untouched: the real ~/.claude/settings.json was never modified
REAL_AFTER="$(md5 -q "$REAL" 2>/dev/null || md5sum "$REAL" 2>/dev/null | awk '{print $1}')"
check "pin: real ~/.claude/settings.json untouched" '[ "$REAL_BEFORE" = "$REAL_AFTER" ]'

# ----------------------------------------------------- scope module (U1/U2, plan 003)
# The shared resolver + qmd-path scope parser the recall match depends on. The F-A
# fixture is the REAL qmd-output format (underscore + leading-dash stripped, qmd://
# prefix) — verified in plan 003 round 3, so the match is asserted against what qmd
# actually emits, not a synthetic path.
echo "== scope module (U1/U2) =="
SCOPE="$REPO/scripts/scoped-memory/scope.py"
scope_py() { python3 -c "import sys; sys.path.insert(0,'$REPO/scripts/scoped-memory'); import scope; $1"; }
check "scope: F-A — real qmd-output path matches resolver slug" \
  "scope_py \"sys.exit(0 if scope.scope_matches('qmd://fa/scope/Users-shawnroos-projects-slate-web-app/conv.md','-Users-shawnroos-projects-slate-web-app') else 1)\""
check "scope: flat-root (global) body does not match a repo slug" \
  "scope_py \"sys.exit(0 if not scope.scope_matches('qmd://fa/global.md','-Users-shawnroos-projects-slate-web-app') else 1)\""
check "scope: parses scope slug from a _scope path too (unmangled)" \
  "scope_py \"sys.exit(0 if scope.scope_of_qmd_file('mem/_scope/-Users-x-proj/a.md')=='-Users-x-proj' else 1)\""
# The expected root is DERIVED, not hardcoded: `worktree list --porcelain`'s first
# entry is the MAIN checkout, which is what a worktree must fold to. Deriving it via
# --git-common-dir (what repo_root itself uses) would be tautological.
MAIN_CHECKOUT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')"
check "scope: resolver folds this checkout to the main repo root (derived)" \
  "scope_py \"sys.exit(0 if scope.repo_root('$REPO')=='$MAIN_CHECKOUT' and '/worktrees/' not in scope.repo_root('$REPO') else 1)\""
check "scope: outside a git repo resolves to global" \
  "scope_py \"sys.exit(0 if scope.resolve_repo_slug('/tmp')=='global' else 1)\""
check "scope: home slug is an ancestor of a repo slug; siblings are not" \
  "scope_py \"sys.exit(0 if scope.is_ancestor_scope('-Users-shawnroos','-Users-shawnroos-projects-slate-web-app') and not scope.is_ancestor_scope('-Users-shawnroos-projects-slate-web-app','-Users-shawnroos-projects-ai-editor-backend') else 1)\""

# U4 selection logic — deterministic (synthetic qmd results, no flaky search):
# in-repo boost (current-repo front), no global displacement, repo-floor gate,
# home-session suppression, K+1 shape. Lives in its own file to dodge nested quoting.
check "select_scoped: boost / no-displacement / floor / home-suppression / K+1" \
  "python3 '$REPO/tests/scope_select_test.py' >/dev/null 2>&1"

# ----------------------------------------------------- scoped re-import (U6, plan 003)
echo "== scoped re-import =="
RIA="$ROOT/ri/archive"; RIS="$ROOT/ri/store"
mkdir -p "$RIA/-Users-x-slate/memory" "$RIA/-Users-x-acme/memory" "$RIS"
printf -- '---\nname: slate conv\n---\nSlate uses pnpm in the web app.\n' > "$RIA/-Users-x-slate/memory/conv.md"
printf -- '---\nname: gen pref\ncross-project: yes\n---\nPrefer rebase over merge everywhere.\n' > "$RIA/-Users-x-acme/memory/pref.md"
printf -- '---\nname: t\n---\nx\n' > "$RIA/-Users-x-acme/memory/cruft.md"
printf '# idx\n' > "$RIA/-Users-x-slate/memory/MEMORY.md"
REIMPORT_TODAY=2026-06-27 python3 "$REPO/scripts/scoped-memory/reimport.py" "$RIA" "$RIS" --apply >/dev/null 2>&1
check "reimport: repo memory lands under _scope/<slug>/ with its scope stamped" \
  "[ -f '$RIS/_scope/-Users-x-slate/conv.md' ] && grep -q 'scope: repo:-Users-x-slate' '$RIS/_scope/-Users-x-slate/conv.md'"
# Reimport must NOT pin. A pin bypasses the index budget outright, and retirement
# never deletes for capacity anyway — a memory past the cut stays on disk, in QMD,
# and recallable — so "prune-protection" protected against nothing. This assertion
# exists because the opposite one shipped: 281 pinned re-imports would have evicted
# 82 of 84 global entries and blown the index to 4.2x budget the moment recursive
# enumeration made them visible.
check "reimport: does NOT pin (a pin would bypass the index budget)" \
  "! grep -q 'pin: true' '$RIS/_scope/-Users-x-slate/conv.md'"
check "reimport: cross-cutting memory lands FLAT (global), not scoped" \
  "[ -f '$RIS/pref.md' ] && [ ! -f '$RIS/_scope/-Users-x-acme/pref.md' ]"
check "reimport: trivial body dropped; MEMORY.md not imported" \
  "[ ! -f '$RIS/_scope/-Users-x-acme/cruft.md' ] && [ ! -f '$RIS/MEMORY.md' ]"
RI_BEFORE="$(find "$RIS" -name '*.md' | wc -l | tr -d ' ')"
REIMPORT_TODAY=2026-06-27 python3 "$REPO/scripts/scoped-memory/reimport.py" "$RIA" "$RIS" --apply >/dev/null 2>&1
RI_AFTER="$(find "$RIS" -name '*.md' | wc -l | tr -d ' ')"
check "reimport: idempotent (no duplicate bodies on re-run)" '[ "$RI_BEFORE" = "$RI_AFTER" ]'
check "reimport: archive left untouched (non-destructive)" "[ -f '$RIA/-Users-x-slate/memory/conv.md' ]"
# collision: two cross-cutting same-name bodies from different origins -> both kept
RIC="$ROOT/ric"; mkdir -p "$RIC/archive/-A/memory" "$RIC/archive/-B/memory" "$RIC/store"
printf -- '---\nname: x\ncross-project: yes\n---\nfrom A general one here\n' > "$RIC/archive/-A/memory/feedback.md"
printf -- '---\nname: y\ncross-project: yes\n---\nfrom B general two here\n' > "$RIC/archive/-B/memory/feedback.md"
python3 "$REPO/scripts/scoped-memory/reimport.py" "$RIC/archive" "$RIC/store" --apply >/dev/null 2>&1
check "reimport: same-name cross-cutting bodies disambiguated (no clobber)" \
  "[ -f '$RIC/store/feedback.md' ] && [ -f '$RIC/store/feedback__B.md' ]"

# ----------------------------------------------------- scoped CLI tools (U5, plan 003)
echo "== scoped CLI =="
CS="$ROOT/cli"; mkdir -p "$CS"; CP="$REPO/scripts/scoped-memory/reflect_cli.py"
REFLECT_MEMORY_DIR="$CS" python3 "$CP" save --scope global --name "g pref" "prefer rebase" >/dev/null 2>&1
REFLECT_MEMORY_DIR="$CS" python3 "$CP" save --scope repo:-Users-x-slate --name "slate b" "build pnpm" >/dev/null 2>&1
check "cli save: global -> flat root with scope:global" \
  "[ -f '$CS/g-pref.md' ] && grep -q '^scope: global' '$CS/g-pref.md'"
check "cli save: repo -> _scope/<slug>/ with scope:repo:<slug>" \
  "[ -f '$CS/_scope/-Users-x-slate/slate-b.md' ] && grep -q '^scope: repo:-Users-x-slate' '$CS/_scope/-Users-x-slate/slate-b.md'"
check "cli list --scope: filters to that scope" \
  "REFLECT_MEMORY_DIR='$CS' python3 '$CP' list --scope repo:-Users-x-slate 2>/dev/null | grep -q 'slate-b.md'"
REFLECT_MEMORY_DIR="$CS" python3 "$CP" promote slate-b.md >/dev/null 2>&1
check "cli promote: repo memory -> flat/global (escape hatch)" \
  "[ -f '$CS/slate-b.md' ] && grep -q '^scope: global' '$CS/slate-b.md' && [ ! -f '$CS/_scope/-Users-x-slate/slate-b.md' ]"
REFLECT_MEMORY_DIR="$CS" python3 "$CP" rescope slate-b.md repo:-Users-x-acme >/dev/null 2>&1
check "cli rescope: global -> repo (file moves, frontmatter updated)" \
  "[ -f '$CS/_scope/-Users-x-acme/slate-b.md' ] && grep -q '^scope: repo:-Users-x-acme' '$CS/_scope/-Users-x-acme/slate-b.md'"
check "cli promote: idempotent noop when already global" \
  "REFLECT_MEMORY_DIR='$CS' python3 '$CP' promote g-pref.md 2>/dev/null | grep -qi noop"
# collision: rescoping into an existing same-name body errors instead of clobbering
CC="$ROOT/clitest"; mkdir -p "$CC"
REFLECT_MEMORY_DIR="$CC" python3 "$CP" save --scope global --name dup "GLOBAL keep" >/dev/null 2>&1
REFLECT_MEMORY_DIR="$CC" python3 "$CP" save --scope repo:-r-x --name dup "SCOPED one" >/dev/null 2>&1
check "cli promote: collision errors, existing body not clobbered" \
  "! REFLECT_MEMORY_DIR='$CC' python3 '$CP' promote _scope/-r-x/dup.md >/dev/null 2>&1 && grep -q 'GLOBAL keep' '$CC/dup.md'"

# ----------------------------------------------------- scope backfill (U3, plan 003)
# Conservative: tags only when the session cwd reconstructs to an on-disk path that
# resolve_repo_slug confirms is the EXACT repo root. Use a real no-hyphen git repo so
# slug reconstruction is lossless; a hyphenated/worktree/gone path stays global.
echo "== scope backfill =="
BF="$ROOT/bf"; mkdir -p "$BF/store"
RR="$(mktemp -d "${TMPDIR:-/tmp}/bfXXXXXX")"; ( cd "$RR" && git init -q )
RSLUG="$(python3 "$REPO/scripts/scoped-memory/scope.py" "$RR")"
HSLUG="-Users-home"
mkdir -p "$BF/projects/$RSLUG" "$BF/projects/$HSLUG"
BU1="11111111-1111-1111-1111-111111111111"; BU2="22222222-2222-2222-2222-222222222222"
touch "$BF/projects/$RSLUG/$BU1.jsonl" "$BF/projects/$HSLUG/$BU2.jsonl"
printf -- '---\nname: a\nmetadata:\n  originSessionId: %s\n---\nrepo body\n' "$BU1" > "$BF/store/a.md"
printf -- '---\nname: b\nmetadata:\n  originSessionId: %s\n---\nhome body\n' "$BU2" > "$BF/store/b.md"
printf -- '---\nname: c\n---\nno-origin body\n' > "$BF/store/c.md"
printf -- '---\nname: d\nscope: repo:-Users-x-acme\n---\nscoped body\n' > "$BF/store/d.md"
# p.md is index-referenced AND repo-resolving — must NOT be moved (U3 invariant)
printf -- '---\nname: p\nmetadata:\n  originSessionId: %s\n---\npointered body\n' "$BU1" > "$BF/store/p.md"
printf '# Memory Index\n- [p](p.md) — pointered, always-loaded\n' > "$BF/store/MEMORY.md"
python3 "$REPO/scripts/scoped-memory/backfill.py" "$BF/store" "$BF/projects" --home-slug "$HSLUG" --apply >/dev/null 2>&1
check "backfill: repo-session memory tagged into _scope/<confirmed-slug>/" \
  "[ -f '$BF/store/_scope/$RSLUG/a.md' ] && grep -q 'scope: repo:$RSLUG' '$BF/store/_scope/$RSLUG/a.md'"
check "backfill: MEMORY.md-pointered memory NOT moved (no demotion)" \
  "[ -f '$BF/store/p.md' ] && [ ! -f '$BF/store/_scope/$RSLUG/p.md' ]"
check "backfill: home-session memory stays flat/global" "[ -f '$BF/store/b.md' ]"
check "backfill: no-origin memory stays flat/global" "[ -f '$BF/store/c.md' ]"
check "backfill: already-scoped memory untouched" "[ -f '$BF/store/d.md' ]"
BF_A="$(find "$BF/store" -name '*.md' | wc -l | tr -d ' ')"
python3 "$REPO/scripts/scoped-memory/backfill.py" "$BF/store" "$BF/projects" --home-slug "$HSLUG" --apply >/dev/null 2>&1
BF_B="$(find "$BF/store" -name '*.md' | wc -l | tr -d ' ')"
check "backfill: idempotent (file count stable on re-run)" '[ "$BF_A" = "$BF_B" ]'

# ------------------------------------------- hook input contract (U0, plan 004)
# Claude Code delivers hook input as JSON on STDIN; no CLAUDE_TOOL*/$TOOL_INPUT env
# var exists. These assertions run the SHIPPED command extracted straight out of
# hooks.json (never copy-pasted) so they bind to what the harness actually executes.
# reflect-trigger.sh writes to $HOME/.claude/.reflect-pending, so HOME is stubbed.
echo "== hook input contract =="
HKJSON="$REPO/.claude/hooks/hooks.json"
HKHOME="$ROOT/hookhome"; mkdir -p "$HKHOME/.claude"
HKFLAG="$HKHOME/.claude/.reflect-pending"
# $1 = event (PostToolUse/PreToolUse), $2 = matcher -> the command string as shipped
# Fatal on a miss, deliberately: a silent miss returns "" and `/bin/bash -c ""`
# exits 0 writing no flag, which SATISFIES every negative-space assertion below.
# Four of the seven would then pass vacuously and the suite would report a partial
# green pointing at neither end. Drift in hooks.json must fail loudly instead.
hk_cmd() {
  python3 - "$HKJSON" "$1" "$2" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for entry in cfg["hooks"].get(sys.argv[2], []):
    if entry.get("matcher") == sys.argv[3]:
        print(entry["hooks"][0]["command"])
        sys.exit(0)
sys.exit("hooks.json: no %s entry with matcher %r" % (sys.argv[2], sys.argv[3]))
PY
}
# $1 = command, $2 = stdin payload, $3 = PATH override ("" keeps the current PATH).
# /bin/bash is spelled absolutely so a stripped PATH can't make the shell itself
# unfindable — that would fake a pass on the fail-open assertion.
hk_run() {
  rm -f "$HKFLAG"
  printf '%s' "$2" | env HOME="$HKHOME" CLAUDE_PLUGIN_ROOT="$REPO" \
    ${3:+PATH="$3"} /bin/bash -c "$1" >/dev/null 2>&1
  echo "$?"
}
HK_BASH="$(hk_cmd PostToolUse Bash)" || { echo "  FAIL - hooks.json shape drifted (PostToolUse/Bash)"; FAIL=$((FAIL+1)); }
HK_TODO="$(hk_cmd PreToolUse TodoWrite)" || { echo "  FAIL - hooks.json shape drifted (PreToolUse/TodoWrite)"; FAIL=$((FAIL+1)); }
check "hook: both matchers were actually found in hooks.json (guards the rest)" \
  '[ -n "$HK_BASH" ] && [ -n "$HK_TODO" ]'
check "hook: matchers no longer read the nonexistent \$TOOL_INPUT env var" \
  '! printf "%s%s" "$HK_BASH" "$HK_TODO" | grep -q "TOOL_INPUT"'

HK_E1="$(hk_run "$HK_BASH" '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 29 --squash"},"tool_response":{"stdout":""},"tool_use_id":"t1","duration_ms":12}')"
check "hook: Bash matcher fires PR_event on a 'gh pr merge' stdin payload" \
  '[ -f "$HKFLAG" ] && grep -q PR_event "$HKFLAG" && [ "$HK_E1" = "0" ]'

HK_E2="$(hk_run "$HK_BASH" '{"tool_name":"Bash","tool_input":{"command":"git status --short"},"tool_response":{"stdout":""},"tool_use_id":"t2"}')"
check "hook: Bash matcher writes no flag on a non-matching command (exit 0)" \
  '[ ! -f "$HKFLAG" ] && [ "$HK_E2" = "0" ]'

# jq is installed in BOTH /opt/homebrew/bin and /usr/bin here, so the usual
# PATH="/usr/bin:/bin" idiom does not strip it — point PATH at an empty dir instead
# and verify jq really is unreachable before trusting the assertion.
HKNOJQ="$ROOT/nojq-bin"; mkdir -p "$HKNOJQ"
check "hook: jq-absent fixture actually hides jq (guards the next assertion)" \
  '! PATH="$HKNOJQ" command -v jq >/dev/null 2>&1'
HK_E3="$(hk_run "$HK_BASH" '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 29 --squash"}}' "$HKNOJQ")"
check "hook: jq absent -> fail-open (exit 0, no flag written)" \
  '[ ! -f "$HKFLAG" ] && [ "$HK_E3" = "0" ]'

# The jq-absent assertion above passes with OR WITHOUT the `command -v jq || exit 0`
# guard: with jq unreachable the substitution is empty, grep fails, and the trailing
# `exit 0` gives an identical outcome. Absence of a flag cannot distinguish "guard
# worked" from "everything downstream quietly no-opped", so that assertion pins the
# outcome but not the mechanism.
#
# This one pins the mechanism from the other side, with a jq SHIM that records having
# run. It proves the matcher genuinely SHELLS OUT to jq and CONSUMES its stdout —
# delete the jq call, or stop reading its output, and the sentinel or the flag stops
# appearing. That is the property the absent-jq test cannot see.
HKSHIM="$ROOT/jqshim-bin"; mkdir -p "$HKSHIM"
HKSENT="$ROOT/jq-was-invoked"
printf '#!/bin/sh\ntouch "%s"\ncat >/dev/null 2>&1\nprintf "gh pr merge 29"\n' "$HKSENT" > "$HKSHIM/jq"
chmod +x "$HKSHIM/jq"
rm -f "$HKSENT"
# Payload carries a NON-matching command; only the shim's stdout matches. So a flag
# can only appear if jq's output — not the raw payload — is what gets grepped.
# PREPEND, never replace: the hook also needs grep/printf, and the shim needs touch.
# Replacing PATH outright strips coreutils and the whole thing no-ops into a false
# result — the same failure shape this assertion exists to catch.
HK_E3B="$(hk_run "$HK_BASH" '{"tool_name":"Bash","tool_input":{"command":"git status"}}' "$HKSHIM:$PATH")"
check "hook: the Bash matcher really invokes jq and greps ITS output, not raw stdin" \
  '[ -f "$HKSENT" ] && [ -f "$HKFLAG" ] && [ "$HK_E3B" = "0" ]'

# TodoWrite gates in jq, not on raw-JSON grep, so pretty-printed stdin still parses.
HK_E4="$(hk_run "$HK_TODO" '{"tool_name":"TodoWrite","tool_input":{"todos":[{"content":"a","status": "completed"},{"content":"b","status": "completed"}]}}')"
check "hook: TodoWrite fires when every todo is completed (whitespace-tolerant)" \
  '[ -f "$HKFLAG" ] && grep -q TodoWrite_all_done "$HKFLAG" && [ "$HK_E4" = "0" ]'

HK_E5="$(hk_run "$HK_TODO" '{"tool_name":"TodoWrite","tool_input":{"todos":[{"content":"a","status":"completed"},{"content":"b","status":"in_progress"}]}}')"
check "hook: TodoWrite stays silent while a todo is still open (exit 0)" \
  '[ ! -f "$HKFLAG" ] && [ "$HK_E5" = "0" ]'

# jq's `all` returns true over an EMPTY array, so `length > 0 and` is the only thing
# standing between us and firing on every list-clearing write — which is exactly what
# happens at the end of a plan. `and` short-circuits, so the guard works; without
# these two assertions, deleting it leaves the suite fully green.
HK_E6="$(hk_run "$HK_TODO" '{"tool_name":"TodoWrite","tool_input":{"todos":[]}}')"
check "hook: TodoWrite does NOT fire on an empty todo list (the vacuous-truth guard)" \
  '[ ! -f "$HKFLAG" ] && [ "$HK_E6" = "0" ]'

HK_E7="$(hk_run "$HK_TODO" '{"tool_name":"TodoWrite","tool_input":{}}')"
check "hook: TodoWrite does NOT fire when the todos key is absent entirely" \
  '[ ! -f "$HKFLAG" ] && [ "$HK_E7" = "0" ]'

# The matcher greps the whole command string, so before anchoring, a commit message or
# heredoc merely MENTIONING the phrase fired a PR_event. Not a regression (the old
# matcher grepped "" and never fired at all) but newly reachable now that the path works
# — and it would let U0's own success signal be satisfied by a non-event.
HK_E8="$(hk_run "$HK_BASH" '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"docs: explain the gh pr merge flow\""}}')"
check "hook: a command that merely MENTIONS 'gh pr merge' does not fire PR_event" \
  '[ ! -f "$HKFLAG" ] && [ "$HK_E8" = "0" ]'

HK_E9="$(hk_run "$HK_BASH" '{"tool_name":"Bash","tool_input":{"command":"git fetch origin && gh pr merge 29 --squash"}}')"
check "hook: PR_event still fires for a real invocation after && (anchor not too tight)" \
  '[ -f "$HKFLAG" ] && grep -q PR_event "$HKFLAG" && [ "$HK_E9" = "0" ]'

# ------------------------------------------- measurement split (U7, plan 001)
# RECALL.log (surfacing telemetry) must stay out of the activation signal, and
# only `applied` may raise activation. telemetry_test.py carries the property
# assertions; here we run it and add the grep-level guard that no code path
# anywhere under the plugin ever feeds RECALL.log into use_counts.
echo "== measurement split =="
TELOUT="$ROOT/telemetry_test.out"
python3 "$REPO/tests/telemetry_test.py" > "$TELOUT" 2>&1; TELRC=$?
check "telemetry_test.py: all assertions pass" '[ "$TELRC" = "0" ]'
check "telemetry_test.py: reports a non-empty tally" 'grep -q "telemetry_test: [1-9][0-9]* passed, 0 failed" "$TELOUT"'
check "activation_test.py still green after the use_counts change" \
  'python3 "$REPO/tests/activation_test.py" >/dev/null 2>&1'
check "no code path feeds RECALL.log into use_counts" \
  '! grep -rn "use_counts" "$REPO" --include=*.py --include=*.sh | grep -v "/tests/" | grep -q "RECALL"'
check "use_counts reads only MEMORY_USE.log" \
  'grep -q "use_counts(os.path.join(memory_dir, \"MEMORY_USE.log\"))" "$SCRIPTS/memory_activation.py"'

# ------------------------------- shared recursive corpus (U10, plan 001/KTD16)
# One `iter_bodies()` walks the store; every reader consumes it. corpus_test.py
# carries the property assertions (slug parsing, exclusions, scoped activation,
# scoped rendering, the 866-shaped timing). Here we run it, build an 866-shaped
# fixture to time the render the way SessionStart would, and add the grep-level
# guard that the two production consumers no longer listdir the store themselves.
echo "== shared recursive corpus =="
CORPOUT="$ROOT/corpus_test.out"
python3 "$REPO/tests/corpus_test.py" > "$CORPOUT" 2>&1; CORPRC=$?
check "corpus_test.py: all assertions pass" '[ "$CORPRC" = "0" ]'
check "corpus_test.py: reports a non-empty tally" \
  'grep -q "corpus_test: [1-9][0-9]* passed, 0 failed" "$CORPOUT"'

# 866-file-shaped fixture with nested scope dirs — the corpus the live store
# actually has, not the flat 64% a listdir would show. Reused by the render-timing
# and enumeration-count assertions below.
CP="$ROOT/corpus866"; mkdir -p "$CP/_scope"
python3 - "$CP" <<'PY'
import os, sys
d = sys.argv[1]
slugs = ["-Users-x-projects-repo%02d" % i for i in range(13)]
for s in slugs:
    os.makedirs(os.path.join(d, "_scope", s), exist_ok=True)
def body(n, i):
    return ("---\nname: %s\nlast_used: 2026-%02d-%02d\n---\ndescription: hook for %s\n\nbody %s\n"
            % (n, 1 + i % 6, 1 + i % 28, n, n))
for i in range(579):
    n = "feedback_flat_%04d" % i
    open(os.path.join(d, n + ".md"), "w").write(body(n, i))
for i in range(287):
    n = "project_scoped_%04d" % i
    open(os.path.join(d, "_scope", slugs[i % len(slugs)], n + ".md"), "w").write(body(n, i))
# Non-bodies that must never be enumerated as memories.
open(os.path.join(d, "MEMORY.md"), "w").write("# Memory Index\n\n")
open(os.path.join(d, "MEMORY_USE.log"), "w").write(
    "".join("2026-06-01 feedback_flat_%04d applied\n" % i for i in range(0, 579, 3)))
open(os.path.join(d, "RECALL.log"), "w").write("2026-06-01 feedback_flat_0000 qmd\n")
open(os.path.join(d, "MEMORY.md.pre-render.bak"), "w").write("# old\n")
open(os.path.join(d, "TRIGGERS.json"), "w").write('{"triggers": []}\n')
PY
check "866-shaped fixture: enumeration finds all 866 bodies (579 flat + 287 scoped)" \
  '[ "$(python3 "$SCRIPTS/scoped-memory/corpus.py" "$CP" 2>/dev/null | wc -l | tr -d " ")" = "866" ]'
check "866-shaped fixture: 287 of them are scoped" \
  '[ "$(python3 "$SCRIPTS/scoped-memory/corpus.py" "$CP" 2>/dev/null | grep -c "^-Users-x-projects-repo")" = "287" ]'

# Render wall time over the full corpus. This runs at SessionStart, so it is a real
# budget, not a micro-benchmark. NOTE: there is no `timeout` binary on this box — a
# check written around one exits 0 having measured nothing — so the elapsed time is
# measured directly with the shell's own SECONDS-free millisecond arithmetic.
CP_T0=$(python3 -c 'import time; print(int(time.time()*1000))')
MEMORY_DIR="$CP" python3 "$SCRIPTS/memory-index-render.py" "$CP/MEMORY.md" > "$ROOT/corpus866.render" 2>&1
CP_RC=$?
CP_T1=$(python3 -c 'import time; print(int(time.time()*1000))')
CP_MS=$((CP_T1 - CP_T0))
echo "  info - 866-body index render: ${CP_MS}ms — $(cat "$ROOT/corpus866.render")"
check "866-shaped store renders successfully" '[ "$CP_RC" = "0" ]'
check "866-shaped render stays within the SessionStart budget (<5000ms)" \
  '[ "$CP_MS" -lt 5000 ]'
check "scoped bodies are eligible for the hot tier" \
  'grep -q "](_scope/" "$CP/MEMORY.md"'
check "scoped entries are titled from the file, not the scope directory" \
  '! grep -qE "^- \[[^]]*Users-x-projects" "$CP/MEMORY.md"'
check "non-bodies never enter the index (logs, .bak, trigger manifest)" \
  '! grep -qE "\]\((MEMORY_USE\.log|RECALL\.log|TRIGGERS\.json|MEMORY\.md(\.pre-render\.bak)?)\)" "$CP/MEMORY.md"'

# The guard KTD16 exists for: a consumer that enumerates the store itself sees a
# different corpus than its siblings. Scoped to the two production consumers this
# unit repoints; the remaining sites (memory-index-lint.sh, migrate-memory-index.py,
# backfill.py) are outside U10's file list and are reported, not silently edited.
# Matches the CALL (trailing paren), not the identifier — both files name
# `os.listdir` in prose explaining why they no longer call it.
check "memory_activation.py does not listdir the store" \
  '! grep -q "os\.listdir(" "$SCRIPTS/memory_activation.py"'
check "memory-index-render.py does not listdir the store" \
  '! grep -q "os\.listdir(" "$SCRIPTS/memory-index-render.py"'
check "both consumers enumerate through corpus.iter_bodies" \
  'grep -q "corpus.iter_bodies" "$SCRIPTS/memory_activation.py" && grep -q "corpus.body_paths" "$SCRIPTS/memory-index-render.py"'

# ---------------------------------------------------------------------- report
echo
echo "harness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
