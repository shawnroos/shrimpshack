#!/usr/bin/env bash
# Behavior-equivalence test for the four mode-name/body validators:
#   1. claude_modes::validate_name        (lib/validate-mode-name.sh — canonical)
#   2. __inject_prose::validate_mode_body (lib/inject-prose.sh inline)
#   3. __claude_modes::status_validate_mode_body (lib/status.sh inline)
#   4. _validate_mode_body                (lib/reconcile-symlinks.py inline)
#
# Why three inline copies (per project_slate_crop_overlay_perf_pattern memory):
#   inject-prose.sh runs on every UserPromptSubmit; sourcing the shared lib
#   adds subprocess + parse cost on the hot path. status.sh and
#   reconcile-symlinks.py have the same concern. We accept duplication and
#   guard against drift with this test.
#
# Fixture categories:
#   - Accept: valid mode names that all 4 implementations must accept
#   - Reject: invalid mode names that all 4 implementations must reject
#
# Why these fixtures:
#   - The accept set includes names that exercise allowed characters and
#     boundary lengths.
#   - The reject set covers the sec-001 P0 attack surface (path traversal),
#     length-cap bypass attempts, reserved tokens, and leading/trailing
#     punctuation. If any implementation diverges on any of these, the
#     P0 patch's defense-in-depth promise is broken.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"
claude_modes_test::setup

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/validate-mode-name.sh"
. "${PLUGIN_ROOT}/lib/inject-prose.sh"
. "${PLUGIN_ROOT}/lib/status.sh"

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# Python-side validator. Two entry points, mirroring production:
#   _is_valid_mode_marker — the READ-SITE gate (_read_per_branch_mode /
#     _read_last_active_mode call this). Accepts the "claude" sentinel.
#   _validate_mode_body   — the STRICT inner validator (also used at the
#     YAML-resolve site). Rejects "claude" and all reserved tokens.
# The test must call whichever layer matches what production calls at the
# read site being modeled, so it takes the function name as an argument.
__test_validate_python() {
  local input="$1"
  local fn="${2:-_is_valid_mode_marker}"
  "$CLAUDE_MODES_PYTHON3" - "$input" "$fn" "${PLUGIN_ROOT}/lib/reconcile-symlinks.py" <<'PYEOF'
import sys, importlib.util, importlib.machinery
input_val = sys.argv[1]
fn_name = sys.argv[2]
src = sys.argv[3]
# Load the module without executing its top-level main() — the functions we
# need are defined at module scope without side effects.
spec = importlib.util.spec_from_file_location("reconcile_symlinks", src)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except SystemExit:
    pass
ok = getattr(mod, fn_name)(input_val)
sys.exit(0 if ok else 1)
PYEOF
}

# Run all four implementations on `input`; assert all four return the same
# rc (accept = 0, reject = 1).
__test_compare_all_four() {
  local label="$1"
  local input="$2"
  local expected="$3"  # "accept" or "reject"

  local rc1 rc2 rc3 rc4
  claude_modes::validate_name "$input" >/dev/null 2>&1; rc1=$?
  __inject_prose::validate_mode_body "$input" >/dev/null 2>&1; rc2=$?
  __claude_modes::status_validate_mode_body "$input" >/dev/null 2>&1; rc3=$?
  __test_validate_python "$input" >/dev/null 2>&1; rc4=$?

  # Normalize to accept/reject ("0" = accept, anything else = reject).
  local act1="reject" act2="reject" act3="reject" act4="reject"
  [ "$rc1" -eq 0 ] && act1="accept"
  [ "$rc2" -eq 0 ] && act2="accept"
  [ "$rc3" -eq 0 ] && act3="accept"
  [ "$rc4" -eq 0 ] && act4="accept"

  if [ "$act1" = "$expected" ] \
     && [ "$act2" = "$expected" ] \
     && [ "$act3" = "$expected" ] \
     && [ "$act4" = "$expected" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "[${label}] input='${input}' expected=${expected} got: canonical=${act1} inject=${act2} status=${act3} reconcile=${act4}"
  fi
}

# ─── Accept fixtures ──────────────────────────────────────────────────
claude_modes_test::it "all four validators accept 'discovery'"
__test_compare_all_four "happy-1" "discovery" "accept"

claude_modes_test::it "all four validators accept 'delivery'"
__test_compare_all_four "happy-2" "delivery" "accept"

claude_modes_test::it "all four validators accept 'review-pass'"
__test_compare_all_four "hyphen" "review-pass" "accept"

claude_modes_test::it "all four validators accept 'underscore_name'"
__test_compare_all_four "underscore-mid" "underscore_name" "accept"

claude_modes_test::it "all four validators accept 64-char boundary"
__test_compare_all_four "len-64" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "accept"

# ─── Reject fixtures: path-traversal (sec-001 P0 surface) ────────────
claude_modes_test::it "all four validators reject '..'"
__test_compare_all_four "traversal-dotdot" ".." "reject"

claude_modes_test::it "all four validators reject '.'"
__test_compare_all_four "traversal-dot" "." "reject"

claude_modes_test::it "all four validators reject '../../tmp/evil'"
__test_compare_all_four "traversal-rel" "../../tmp/evil" "reject"

claude_modes_test::it "all four validators reject 'name..with..dotdot'"
__test_compare_all_four "embedded-dotdot" "name..with..dotdot" "reject"

claude_modes_test::it "all four validators reject empty string"
__test_compare_all_four "empty" "" "reject"

# ─── Reject fixtures: length cap ──────────────────────────────────────
claude_modes_test::it "all four validators reject 65-char (cap bypass)"
__test_compare_all_four "len-65" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "reject"

# ─── Reject fixtures: leading/trailing punctuation ────────────────────
claude_modes_test::it "all four validators reject leading dash '-foo'"
__test_compare_all_four "lead-dash" "-foo" "reject"

claude_modes_test::it "all four validators reject trailing dash 'foo-'"
__test_compare_all_four "trail-dash" "foo-" "reject"

claude_modes_test::it "all four validators reject leading underscore '_foo'"
__test_compare_all_four "lead-underscore" "_foo" "reject"

# ─── Reject fixtures: forbidden chars ─────────────────────────────────
claude_modes_test::it "all four validators reject path separator 'a/b'"
__test_compare_all_four "slash" "a/b" "reject"

claude_modes_test::it "all four validators reject shell metachar 'a;ls'"
__test_compare_all_four "semicolon" "a;ls" "reject"

# sec-005: internal whitespace must be rejected by ALL validators. The bug
# was that the shell READ path used `tr -d '[:space:]'` (deletes internal
# whitespace → "delivery x" became "deliveryx", accepted) while Python's
# read used .strip() (kept "delivery x", rejected). The validators
# themselves always rejected internal whitespace via the charset regex;
# this fixture guards that contract so a future read-path change can't
# silently reintroduce the divergence.
claude_modes_test::it "all four validators reject internal space 'delivery x'"
__test_compare_all_four "internal-space" "delivery x" "reject"

claude_modes_test::it "all four validators reject internal tab 'a\\tb'"
__test_compare_all_four "internal-tab" "$(printf 'a\tb')" "reject"

claude_modes_test::it "all four validators reject UTF-8 lookalike (Cyrillic 'а')"
# U+0430 looks like Latin 'a' but encodes as bytes D0 B0 — must reject.
__test_compare_all_four "utf8" "$(printf '\xd0\xb0')" "reject"

# ─── Special-case: 'claude' Claude-Mode sentinel ───────────────────────
# "claude" has a SPLIT contract by design:
#   - canonical (validate_name): REJECT — cannot NAME a mode "claude"
#   - read-site validators: ACCEPT — sentinel for "no mode active"
# So the equivalence test must check the three read-site validators
# agree (accept) and the canonical disagrees (reject).
claude_modes_test::it "3 read-site validators accept 'claude' sentinel; canonical rejects (intentional split)"
# Read-site validators model what production calls at the .mode read site:
# the shell inline validators (which accept "claude") and the Python
# _is_valid_mode_marker wrapper (which also accepts "claude"). The canonical
# write-validator rejects it (you cannot NAME a mode "claude").
__rc_canonical=$(claude_modes::validate_name "claude" >/dev/null 2>&1; echo $?)
__rc_inj=$(__inject_prose::validate_mode_body "claude" >/dev/null 2>&1; echo $?)
__rc_stat=$(__claude_modes::status_validate_mode_body "claude" >/dev/null 2>&1; echo $?)
__rc_py=$(__test_validate_python "claude" "_is_valid_mode_marker" >/dev/null 2>&1; echo $?)
if [ "$__rc_canonical" -ne 0 ] \
   && [ "$__rc_inj" -eq 0 ] \
   && [ "$__rc_stat" -eq 0 ] \
   && [ "$__rc_py" -eq 0 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected canonical=reject + read-sites=accept; got canonical=${__rc_canonical} inj=${__rc_inj} stat=${__rc_stat} py=${__rc_py}"
fi

# ─── Reserved tokens: security-critical subset (all four reject) ──────
# _global and _repo map to REAL tier files (tier-2 _global.yaml, tier-4
# _repo.yaml). Accepting them as a .mode body would redirect the cascade to
# a structural config file, so every validator — including the inline
# path-safety subset — must reject them. The leading-underscore rule
# (`[-_]*`) is what catches these in all four implementations.
claude_modes_test::it "all four validators reject reserved token '_global'"
__test_compare_all_four "reserved-global" "_global" "reject"

claude_modes_test::it "all four validators reject reserved token '_repo'"
__test_compare_all_four "reserved-repo" "_repo" "reject"

# ─── Reserved tokens: ALL four validators must reject (parametrized) ──
# Re-review correctness finding: the inline read-site validators previously
# OMITTED the reserved-token check, so a .mode body of "set"/"setup"/etc was
# accepted by inject-prose + status while the canonical validator and the
# Python reconciler rejected it — a status-vs-reconcile state disagreement
# (the sec-005 divergence class). The inline validators now carry the
# reserved-token list too. This loop guards that all four agree (reject) on
# every UX-reserved token. "claude" is the ONE exception (Claude-Mode
# sentinel) and is tested separately above — it is excluded here.
# Tokens correspond to CLAUDE_MODES_RESERVED_TOKENS minus claude/_global/_repo
# (_global/_repo are covered by the underscore-edge reject fixtures above).
for __rt in default none set status clear apply registry adopt setup list help promote rebuild coverage; do
  claude_modes_test::it "all four validators reject reserved token '${__rt}'"
  __test_compare_all_four "reserved-${__rt}" "$__rt" "reject"
done

claude_modes_test::teardown

# Summary in the format tests/run.sh expects (and fail the suite on red).
echo ""
printf '%s: %d passed, %d failed\n' \
  "$(basename "${BASH_SOURCE[0]}")" \
  "${CLAUDE_MODES_TEST_PASS_COUNT}" \
  "${CLAUDE_MODES_TEST_FAIL_COUNT}"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
