#!/usr/bin/env bash
# Terminal-sink lint guard (mechanical enforcement of the terminal-escape
# class closure — see docs/solutions/terminal-escape-audit.md).
#
# The terminal-escape class recurred across review rounds 2-4: each round's
# narrow grep found one new sink printing an attacker-controlled value raw to
# a human terminal. After the L4 structural audit closed every site, this test
# FAILS CI if a NEW unsanitized attacker-var → terminal sink is introduced —
# converting reactive round-by-round patching into a standing guarantee
# (per feedback_deterministic_over_probabilistic_v1: mechanical enforcement,
# not disposition).
#
# How it works: in the user-facing command output files, find every line that
# (a) writes to a terminal (printf/echo to stdout/stderr/dev/tty, or __cm_title)
# AND (b) interpolates a known ATTACKER-CLASS variable. Each such line MUST
# either wrap the variable in claude_modes::sanitize_for_display, OR the
# variable must be on the VALIDATED allowlist (its value came from a validator).
#
# Adding a new sink requires routing through a defense AND updating the audit
# doc — this test makes "I forgot to sanitize" a red build, not a round-N find.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"
claude_modes_test::setup

# Scope is COMPUTED, not hand-maintained (round-6 lesson: cascade-engine.sh
# wasn't in the old hand-listed LINT_FILES, so its raw error-branch prints
# slipped past the lint for rounds while sibling files were being hardened).
# Default: every bash file under lib/ and scripts/ is in scope. A new .sh file
# is linted automatically — the failure mode moves from "forgot to add" (silent
# gap) to "forgot to exclude" (loud CI red).
#
# .py files are NOT scanned: this lint's sink/protection detection is bash-only
# (it matches `printf`/`echo`/`__cm_title`/`> /dev/tty` and the bash sanitizer
# `claude_modes::sanitize_for_display`). Python sinks (cascade-engine.py,
# drift-diff.py, *-symlinks.py) defend via an inline Cc+Cf strip in the Python
# layer — a different surface, covered by the audit doc, not by this lint.
#
# LINT_EXCLUDE: files that legitimately cannot leak attacker bytes to a
# terminal. Each entry MUST carry a one-line reason — an unannotated exclusion
# is the same silent-gap failure this rewrite closes.
LINT_EXCLUDE=(
  "lib/sanitize.sh"   # IS the sanitizer; its echo of the value is the defense, by design
  "lib/audit.sh"      # appends to the audit LOG file, never prints to a terminal
)

mapfile -t LINT_FILES < <(
  find "${PLUGIN_ROOT}/lib" "${PLUGIN_ROOT}/scripts" -name '*.sh' \
    | sed "s#^${PLUGIN_ROOT}/##" \
    | sort
)
# Drop excluded files.
__filtered=()
for rel in "${LINT_FILES[@]}"; do
  __skip=0
  for ex in "${LINT_EXCLUDE[@]}"; do
    [ "$rel" = "$ex" ] && { __skip=1; break; }
  done
  [ "$__skip" = "0" ] && __filtered+=("$rel")
done
LINT_FILES=("${__filtered[@]}")

# ATTACKER-CLASS variable names: free-form values an attacker (hostile repo,
# crafted clone path, hostile branch/filename) can influence. If one of these
# is interpolated into a terminal-print line, it MUST be sanitized.
# (active_mode / mode_name / branch_slug are VALIDATED by construction and are
# intentionally NOT in this list — see the audit doc.)
#
# The lint matches variable NAMES, not dataflow. So this list MUST include
# every name DERIVED from an attacker source too (round-5 lesson: the lint
# missed tier_4_path/settings_local/sidecar = "${repo_root}/..." because only
# the base name `repo_root` was listed). Mirror docs/solutions/terminal-escape-audit.md:
# when a new attacker-derived variable is introduced, add its name here AND
# document it in the audit doc. The `_d` display-variant names are the
# sanitized outputs (safe by construction) so they're NOT in this list.
# round-7 (L7) additions: `entry` is untrusted manifest content (the R7
# chokepoint's input — symlink-rebuild.sh:102); `staging`/`err` ride alongside
# it. Same name-allowlist failure mode as round-5's tier_4_path gap.
# round-8 (U2) additions: resolve-catalog-candidate.sh introduced raw attacker
# vars `plugin_raw`/`skill_raw` (hostile cached SKILL.md `name:` + plugin dir),
# `key_raw` (user-writable installed_plugins.json key), `fqn_raw` (user-writable
# marketplace.json name → FQN). post-write-reload.sh's `delta_summary` is the
# raw delta string (may embed plugin keys). Batch-4 addition: `parent_raw`
# (resolve-catalog-candidate.sh — the skill's parent-plugin FQN from the
# user-writable installed_plugins.json; reaches printf only via `parent_d`).
# All currently reach printf only via
# their `_d` display variants — listing the RAW names here keeps that an
# enforced invariant, not a convention (a future regression printing the raw
# var ships a red build, not a silent gap). NOTE: `mode_name` is NOT listed —
# post-write-reload.sh interpolates only `mode_name_d` into every printf (raw
# `mode_name` reaches printf nowhere); it stays validated-by-construction.
ATTACKER_VARS='repo_root|raw_branch|\bbranch\b|cwd_basename|tier_4_path|settings_local|sidecar|candidate|__real_cand|repo_yaml|\bentry\b|staging|\berr\b|plugin_raw|skill_raw|parent_raw|key_raw|fqn_raw|delta_summary'

# A line is SAFE if the attacker var is wrapped in the sanitizer, OR it's a
# call to __cm_title (a sanitizing chokepoint — it strips Cc+Cf internally, so
# every value passed to it is sanitized at the function, not the call site).
__line_is_protected() {
  local line="$1"
  printf '%s' "$line" | grep -qE "sanitize_for_display|__cm_title"
}

# A line is a TERMINAL PRINT if it emits to a human sink. Two non-terminal
# shapes are excluded:
#   - `printf ... |`  — printf feeding a PIPE is an internal transformation
#     (e.g. slugify's `printf '%s' "$branch" | tr ...`), not terminal output.
#   - `printf ... > "$file"` / `>> "$file"` — output redirected to a NAMED file
#     (e.g. `>> "$trusted_file"`) is a file write, not a human-visible sink.
#     /dev/tty and /dev/std{out,err} are NOT files — they stay terminal sinks.
__line_is_terminal_print() {
  local line="$1"
  # __cm_title and direct /dev/tty writes are always terminal sinks.
  if printf '%s' "$line" | grep -qE '__cm_title|> */dev/tty'; then
    return 0
  fi
  # Custom print wrappers `_log`/`_err` (used in unmodes.sh, setup.sh,
  # restore-claude-modes.sh) emit to stderr — treat them as terminal sinks.
  # Anchored like the printf/echo case so `my_log`/`__err` don't match.
  if printf '%s' "$line" | grep -qE '^[[:space:]]*(_log|_err)[[:space:]]|[^_a-zA-Z](_log|_err)[[:space:]]'; then
    # Same pipe / file-redirect exclusions as the printf/echo path.
    if printf '%s' "$line" | grep -qE '(_log|_err)[^|]*\|'; then
      return 1
    fi
    if printf '%s' "$line" | grep -qE '>>?[[:space:]]*"?(\$|/|[A-Za-z0-9_.])' \
       && ! printf '%s' "$line" | grep -qE '>>?[[:space:]]*"?/dev/(tty|std)'; then
      return 1
    fi
    return 0
  fi
  # printf/echo as a command word. Two anchored alternatives — a line-leading
  # `echo`/`printf` (after optional indentation) OR one preceded by a
  # non-identifier char — so `__cm_echo`/`my_printf` don't match but a
  # line-leading `echo` does. (The old `[^_]echo ` missed line-leading echo
  # entirely — a pre-existing gap the hand-listed file scope never exposed; ERE
  # `(^|...)` inside one group doesn't reliably apply the `^` branch in grep,
  # so the leading-whitespace case is its own anchored alternative.)
  if printf '%s' "$line" | grep -qE '^[[:space:]]*(printf|echo)[[:space:]]|[^_a-zA-Z](printf|echo)[[:space:]]'; then
    if printf '%s' "$line" | grep -qE 'printf[^|]*\||echo[^|]*\|'; then
      return 1  # piped → internal transform, not a terminal sink
    fi
    # Redirected to a NAMED file → file write, not a human sink. A redirect
    # target that is a var (`>> "$f"`), a quoted path (`> "/tmp/x"`), or a bare
    # path (`>> /tmp/x`) is a file. `>&2`/`>&1` (fd dup) and `> /dev/tty` /
    # `/dev/std*` are NOT files — they remain terminal sinks (handled by the
    # negative lookahead via the `&`/`/dev/` exclusion).
    if printf '%s' "$line" | grep -qE '>>?[[:space:]]*"?(\$|/|[A-Za-z0-9_.])' \
       && ! printf '%s' "$line" | grep -qE '>>?[[:space:]]*"?/dev/(tty|std)'; then
      return 1
    fi
    return 0
  fi
  return 1
}

# Scan ONE file; echo "rel:lineno: content" for each unsanitized sink. Factored
# out so the deliberate-fail self-test below can run the EXACT same detector
# over a planted-violation temp file (L6-a's manual deliberate-fail, now encoded
# permanently per the round-7 testing finding — a single green-path assertion
# passes vacuously if the detector breaks).
__scan_file_for_violations() {
  local f="$1" rel="$2" out="" entry lineno content
  [ -f "$f" ] || return 0
  while IFS= read -r entry; do
    lineno="${entry%%:*}"
    content="${entry#*:}"
    case "$(printf '%s' "$content" | sed 's/^[[:space:]]*//')" in
      \#*) continue ;;
    esac
    __line_is_terminal_print "$content" || continue
    # Trailing [^A-Za-z0-9_] (or end) so e.g. `tier_4_path` matches
    # `$tier_4_path` / `${tier_4_path}` but NOT the sanitized `$tier_4_path_d`
    # display variant (the `_d` suffix is the "already sanitized" signal).
    printf '%s' "$content" | grep -qE "\\\$\{?(${ATTACKER_VARS})([^A-Za-z0-9_]|\}|$)" || continue
    if ! __line_is_protected "$content"; then
      out="${out}${rel}:${lineno}: ${content}"$'\n'
    fi
  done < <(grep -nE "\\\$\{?(${ATTACKER_VARS})([^A-Za-z0-9_]|\}|$)" "$f" 2>/dev/null)
  printf '%s' "$out"
}

violations=""
for rel in "${LINT_FILES[@]}"; do
  violations="${violations}$(__scan_file_for_violations "${PLUGIN_ROOT}/${rel}" "$rel")"
done

claude_modes_test::it "no user-facing command prints an attacker-class var to a terminal without sanitize_for_display"
if [ -z "$violations" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "unsanitized attacker-var terminal sink(s) found — wrap in claude_modes::sanitize_for_display and update docs/solutions/terminal-escape-audit.md:"$'\n'"${violations}"
fi

# ─── Deliberate-fail self-test (NON-NEGOTIABLE) ───────────────────────────
# L6-a did this by hand (unwrap a real sink, confirm red, re-wrap). Encode it so
# a broken __line_is_terminal_print / ATTACKER_VARS can't produce vacuous green.
__df_dir="$(mktemp -d "${TMPDIR:-/tmp}/cm-shlint.XXXXXX")"
__df_bad="${__df_dir}/bad_sink.sh"
printf 'echo "leaking $repo_root to terminal" >&2\n' > "$__df_bad"
__df_bad_hits="$(__scan_file_for_violations "$__df_bad" "bad_sink.sh")"
claude_modes_test::it "deliberate-fail: lint FLAGS a planted unsanitized bash sink"
if [ -n "$__df_bad_hits" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "lint did NOT flag a planted raw \$repo_root sink — detector broken (vacuous green risk)"
fi
__df_ok="${__df_dir}/ok_sink.sh"
printf 'echo "safe $(claude_modes::sanitize_for_display "$repo_root")" >&2\n' > "$__df_ok"
__df_ok_hits="$(__scan_file_for_violations "$__df_ok" "ok_sink.sh")"
claude_modes_test::it "deliberate-fail control: lint does NOT flag a sanitized bash sink"
if [ -z "$__df_ok_hits" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "lint false-positived on a sanitized sink: ${__df_ok_hits}"
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
