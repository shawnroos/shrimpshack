#!/usr/bin/env bash
# Python-side terminal-sink lint guard — the language-boundary twin of
# tests/integration/terminal-sink-lint.test.sh (which is bash-only).
#
# Round 7 (L7) closed the structural gap that let the terminal-escape class
# recur a 7th time: the bash lint structurally cannot see Python sinks, and the
# audit doc FALSELY claimed the Python layer defended via an inline Cc+Cf strip
# (it did not — no unicodedata anywhere in lib/*.py). cascade-engine.py wrote
# attacker-controlled _repo.yaml keys / clone-paths / YAML-error snippets RAW to
# stderr. L7-a added lib/sanitize.py + sanitize_for_display at every site; this
# lint is the mechanical enforcement that a NEW Python sink must use it too.
#
# How it works: scan every *.py under lib/ (computed via find, minus an
# annotated exclusion list) for a Python terminal sink — sys.stderr.write(...)
# or print(..., file=sys.stderr) — that interpolates a known attacker-class
# variable into an f-string without routing it through sanitize_for_display.
# Because Python f-strings span the call, we scan the WHOLE call expression
# (the sink keyword through its closing paren region), not a single line.
#
# Per feedback_deterministic_over_probabilistic_v1 + the L6-a lesson: this guard
# ships WITH a deliberate-fail assertion (a planted unsanitized sink the lint
# MUST flag), so a broken detector can't report vacuous green.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"
claude_modes_test::setup

# Scope COMPUTED, not hand-maintained (same discipline as the bash lint): every
# *.py under lib/ is in scope by default. LINT_EXCLUDE entries each carry a
# one-line reason — an unannotated exclusion is the silent-gap failure mode.
LINT_EXCLUDE=(
  "lib/sanitize.py"            # IS the sanitizer; nothing to interpolate
  "lib/reconcile-symlinks.py"  # logs only to .session-start.log/.audit.log files, never to a terminal
  "lib/drift-diff.py"          # NOT WIRED IN for V2.0 (no callers); revisit at V2.1 wiring
)

# ATTACKER-CLASS names: externally-controlled values (hostile _repo.yaml content,
# clone-dir-derived paths, untrusted manifest entries, their realpaths). If one
# is interpolated into a Python terminal sink it MUST be wrapped in
# sanitize_for_display. (claude_modes_id / tier_label are ours — not listed.)
ATTACKER_VARS='path|tier_4_path|real_leaf|real_repo|target_settings_local_path|sidecar_path|entry|resolved|cascade_keys'

# A Python terminal sink call. We grep for the sink keyword and capture the
# call's text up to a blank line or the next def/sink (f-strings are multi-line).
__py_lint_scan_file() {
  local f="$1"
  "$CLAUDE_MODES_PYTHON3" - "$f" "$ATTACKER_VARS" <<'PYEOF'
import re, sys
path, attacker_alt = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8", errors="replace").read()
lines = src.splitlines()

# Start of a terminal-sink call.
sink_re = re.compile(r'sys\.stderr\.write\s*\(|print\s*\([^)]*file\s*=\s*sys\.stderr')
attacker_re = re.compile(r'(?<![A-Za-z0-9_])(' + attacker_alt + r')(?![A-Za-z0-9_])')

def call_text(start_idx):
    """Return ONLY the text of THIS sink call (balanced parens from the first
    '(' of the sink keyword). Bounds to the call so a later unrelated statement
    can't bleed in as a false positive."""
    depth = 0
    started = False
    buf = []
    for i in range(start_idx, min(start_idx + 15, len(lines))):
        ln = lines[i]
        seg = []
        for ch in ln:
            if not started and ch == '(':
                started = True
                depth = 1
                seg.append(ch)
                continue
            if started:
                seg.append(ch)
                if ch == '(':
                    depth += 1
                elif ch == ')':
                    depth -= 1
                    if depth == 0:
                        break
        buf.append("".join(seg))
        if started and depth == 0:
            break
    return "\n".join(buf)

# Extract ONLY the f-string interpolation fields {...} from the call text. A
# bare-string literal that merely MENTIONS an argv name (e.g. the usage line
# "expected ... tier_4_path ...") is not an interpolation and must not flag.
# An attacker var is a violation only when it appears inside a {...} field that
# is NOT wrapped in sanitize_for_display(...).
field_re = re.compile(r'\{([^{}]*)\}')

def is_fstring_call(text):
    # Heuristic: the call contains an f-prefixed string literal.
    return re.search(r'\bf["\']', text) is not None

violations = []
for idx, ln in enumerate(lines):
    if not sink_re.search(ln):
        continue
    text = call_text(idx)
    if not is_fstring_call(text):
        continue  # plain string literal — no interpolation, can't leak a var
    for fm in field_re.finditer(text):
        field = fm.group(1)
        if 'sanitize_for_display(' in field:
            continue  # this interpolation is defended
        am = attacker_re.search(field)
        if am:
            violations.append(
                f"{path}:{idx + 1}: attacker var '{am.group(1)}' in terminal "
                f"sink f-string field {{{field.strip()}}} without sanitize_for_display"
            )
            break  # one report per sink is enough

for v in violations:
    print(v)
PYEOF
}

# Build computed file list minus exclusions.
mapfile -t PY_FILES < <(
  find "${PLUGIN_ROOT}/lib" -name '*.py' | sed "s#^${PLUGIN_ROOT}/##" | sort
)
__filtered=()
for rel in "${PY_FILES[@]}"; do
  __skip=0
  for ex in "${LINT_EXCLUDE[@]}"; do
    [ "$rel" = "$ex" ] && { __skip=1; break; }
  done
  [ "$__skip" = "0" ] && __filtered+=("$rel")
done
PY_FILES=("${__filtered[@]}")

violations=""
for rel in "${PY_FILES[@]}"; do
  f="${PLUGIN_ROOT}/${rel}"
  [ -f "$f" ] || continue
  hits="$(__py_lint_scan_file "$f")"
  [ -n "$hits" ] && violations="${violations}${hits}"$'\n'
done

claude_modes_test::it "no lib/*.py terminal sink interpolates an attacker-class var without sanitize_for_display"
if [ -z "$violations" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "unsanitized Python attacker-var terminal sink(s) — wrap in sanitize_for_display (lib/sanitize.py) and update docs/solutions/terminal-escape-audit.md:"$'\n'"${violations}"
fi

# ─── Deliberate-fail self-test (NON-NEGOTIABLE) ───────────────────────────
# Plant a known-bad sink in a temp .py and assert the scanner flags it. Without
# this, a broken sink_re/attacker_re would let the green-path assertion above
# pass vacuously — the exact 0-assertion antipattern the bash lint was dinged
# for (testing P2, round 7). Also assert the SANITIZED form does NOT flag.
__df_dir="$(mktemp -d "${TMPDIR:-/tmp}/cm-pylint.XXXXXX")"
__df_bad="${__df_dir}/bad_sink.py"
cat > "$__df_bad" <<'BADPY'
import sys
def f(path):
    sys.stderr.write(f"error reading {path}\n")
BADPY
__df_bad_hits="$(__py_lint_scan_file "$__df_bad")"

claude_modes_test::it "deliberate-fail: lint FLAGS a planted unsanitized Python sink"
if [ -n "$__df_bad_hits" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "lint did NOT flag a planted raw 'path' sink — detector is broken (vacuous green risk)"
fi

__df_ok="${__df_dir}/ok_sink.py"
cat > "$__df_ok" <<'OKPY'
import sys
from sanitize import sanitize_for_display
def f(path):
    sys.stderr.write(f"error reading {sanitize_for_display(path)}\n")
OKPY
__df_ok_hits="$(__py_lint_scan_file "$__df_ok")"

claude_modes_test::it "deliberate-fail control: lint does NOT flag a sanitized Python sink"
if [ -z "$__df_ok_hits" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "lint false-positived on a sanitize_for_display-wrapped sink: ${__df_ok_hits}"
fi

rm -rf "$__df_dir"

claude_modes_test::teardown

echo ""
printf '%s: %d passed, %d failed\n' \
  "$(basename "${BASH_SOURCE[0]}")" \
  "${CLAUDE_MODES_TEST_PASS_COUNT}" \
  "${CLAUDE_MODES_TEST_FAIL_COUNT}"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
