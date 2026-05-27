#!/usr/bin/env bash
# Mechanical lint: forbid bare `git rev-parse --show-toplevel` on read paths.
#
# Why this lint exists. The cross-project mode-leak (a non-repo subdir of a
# modes-using project inheriting the parent's per-branch pin) recurred FOUR
# times — once in each hand-mirrored copy of the resolver, fixed one at a
# time across rounds of code review. The structural fix landed in
# 2026-05-27: centralize the gate into claude_modes::current_repo_root (the
# walk-up-for-.claude/modes-marker + git-tracked-cwd resolver), have every
# read site source it. The bug class was "fix the cited instance, miss the
# class" — see the resolver-centralization commits (7e52130, 7a22756) and
# the active-mode-resolver-equivalence test.
#
# This lint converts that structural fix into a STANDING GUARANTEE: a future
# refactor that re-introduces a bare `git rev-parse --show-toplevel` on a
# read-path file ships a RED BUILD, not a silent leak. Same shape as the
# terminal-sink-lint (computed scope + documented exclusions; "forgot to
# exclude" is loud, "forgot to add" is impossible).
#
# Scope: read-path files only. The READ side ("which project's mode applies
# to me?") must route through the gate. The WRITE side ("where do I create
# project config?") legitimately uses bare --show-toplevel (via the canonical
# claude_modes::current_git_toplevel) — those files are explicitly excluded.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"
claude_modes_test::setup

# READ-PATH FILES: the files that resolve "which mode is active right now"
# and MUST route through claude_modes::current_repo_root (Bash) or
# _gated_repo_root (Python). A bare `git rev-parse --show-toplevel` on any
# of these reopens the cross-project leak.
#
# Adding a new read-path file (e.g., a new hook that reads a .mode pointer)
# requires adding it here AND having it call the gated resolver. The list is
# explicit-not-computed because "read path" is a semantic property the lint
# can't detect from filename alone — but the list is small and the
# add-without-routing failure mode is exactly what this lint catches.
READ_PATH_FILES=(
  "lib/active-mode.sh"            # canonical read-side resolver chain
  "lib/inject-prose.sh"           # UserPromptSubmit prose hook
  "lib/status.sh"                 # /mode:status
  "lib/apply-mode.sh"             # /mode:apply (re-applies the active mode)
  "scripts/statusline.sh"         # statusline display
  "lib/reconcile-symlinks.py"     # SessionStart reconciler (Python mirror)
)

# Files explicitly EXCLUDED from this lint because they are WRITE-side or
# operate at a different layer. Each entry documents WHY — an unannotated
# exclusion is the same silent-gap failure this lint closes.
LINT_EXCLUDE=(
  "lib/repo-root.sh"              # IS the canonical resolver lib; current_git_toplevel uses bare --show-toplevel BY DESIGN (write side)
  "lib/apply-delta.sh"            # WRITE side — resolves repo root to write .claude/modes/<branch>.mode
  "lib/write-mode-yaml.sh"        # WRITE side — resolves repo root to write a mode YAML
  "lib/cascade-engine.sh"         # cascade_compile WRITES settings.local.json to cwd's repo
  "scripts/unmodes.sh"            # uninstall (write/delete)
)

# Sanity: every READ_PATH_FILES entry must EXIST. A typo would silently
# bypass the lint for a file that no longer matches.
for rel in "${READ_PATH_FILES[@]}"; do
  if [ ! -f "${PLUGIN_ROOT}/${rel}" ]; then
    claude_modes_test::it "read-path file '${rel}' exists (lint scope is valid)"
    claude_modes_test::fail "READ_PATH_FILES references a missing file"
  fi
done

# The forbidden pattern. Different shapes per language:
#   Bash: `git rev-parse --show-toplevel` (with optional `-C <dir>`) as a real
#         command — not as text inside a `#` comment.
#   Python: the literal-list form `"rev-parse", "--show-toplevel"` (the only
#           way subprocess.run shells out to git here). Mentions of the
#           command string in docstrings or comments are documentation, not
#           a security concern — the sharper Python detector matches the
#           argv list shape, not the prose mention.
#
# Inline escape: a line carrying `# lint: read-path-toplevel-ok` is excused
# (matches the existing `# noqa: E402` / `# shellcheck disable=SC1091`
# convention). Use ONLY when the gate is applied at a different layer (e.g.
# reconcile-symlinks.py's _resolve_branch: gate moved to the per-branch-pin
# decision in main(), so _resolve_branch legitimately uses bare toplevel for
# the 3-way no-repo/no-mode/reconcile classification — documented escape).
__scan_for_bare_toplevel() {
  local file_rel="$1"
  local file_abs="${PLUGIN_ROOT}/${file_rel}"
  case "$file_rel" in
    *.py)
      # Match the subprocess argv-list form. Two shapes to catch:
      #   1. Single-line: "rev-parse"<sep>"--show-toplevel" (sep = whitespace/comma)
      #   2. Wrapped-argv: "rev-parse" on one line, "--show-toplevel" within the
      #      next ±2 lines (the argv list is wrapped across lines for readability).
      # A future PR doing:
      #     subprocess.run([
      #         "git",
      #         "rev-parse",
      #         "--show-toplevel",
      #     ], ...)
      # would otherwise bypass a single-line-only detector silently.
      #
      # Python subprocess.run calls also wrap the marker across lines, so the
      # escape marker check uses the same ±3-line window.
      awk '
        {
          lines[NR] = $0
        }
        END {
          for (i = 1; i <= NR; i++) {
            # Shape 1: single-line "rev-parse"<sep>"--show-toplevel"
            single = (lines[i] ~ /"rev-parse"[[:space:]]*,[[:space:]]*"--show-toplevel"/)
            # Shape 2: "rev-parse" on this line, "--show-toplevel" within ±2 lines.
            split_form = 0
            if (!single && lines[i] ~ /"rev-parse"/) {
              for (k = i - 2; k <= i + 2; k++) {
                if (k < 1 || k > NR || k == i) continue
                if (lines[k] ~ /"--show-toplevel"/) { split_form = 1; break }
              }
            }
            if (!single && !split_form) continue
            # Escape-marker window check (±3 lines).
            ok = 0
            for (j = i - 3; j <= i + 3; j++) {
              if (j < 1 || j > NR) continue
              if (lines[j] ~ /# lint: read-path-toplevel-ok/) { ok = 1; break }
            }
            if (ok) continue
            print i ": " lines[i]
          }
        }
      ' "$file_abs"
      ;;
    *)
      # Bash form. Ignore lines that begin with `#` (full-line comment),
      # lines where the match is positionally AFTER a `#` on the same line,
      # and lines carrying the inline escape marker.
      awk '
        /git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?rev-parse[[:space:]]+--show-toplevel/ {
          if ($0 ~ /^[[:space:]]*#/) next
          if ($0 ~ /# lint: read-path-toplevel-ok/) next
          match_pos = index($0, "rev-parse")
          comment_pos = index($0, "#")
          if (comment_pos > 0 && comment_pos < match_pos) next
          print NR ": " $0
        }
      ' "$file_abs"
      ;;
  esac
}

# Build the effective scan list (READ_PATH_FILES minus any that landed on
# the exclude list by mistake — defense-in-depth, should never trigger).
__effective_scan=()
for rel in "${READ_PATH_FILES[@]}"; do
  __skip=0
  for ex in "${LINT_EXCLUDE[@]}"; do
    [ "$rel" = "$ex" ] && { __skip=1; break; }
  done
  [ "$__skip" = "0" ] && __effective_scan+=("$rel")
done

for rel in "${__effective_scan[@]}"; do
  claude_modes_test::it "read-path file '${rel}' has no bare \`git rev-parse --show-toplevel\` (must route through current_repo_root)"
  hits=$(__scan_for_bare_toplevel "$rel")
  if [ -z "$hits" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "$(printf 'forbidden bare --show-toplevel in %s:\n%s\nRoute through claude_modes::current_repo_root (lib/repo-root.sh).' "$rel" "$hits")"
  fi
done

# Coverage sanity: confirm the canonical write-side resolver IS in the
# exclude list — if someone removed it, the lint would flag the lib itself
# and we'd "fix" the canonical resolver into something that no longer works.
claude_modes_test::it "lib/repo-root.sh (canonical write-side resolver) is on the exclude list"
__excluded=0
for ex in "${LINT_EXCLUDE[@]}"; do
  [ "$ex" = "lib/repo-root.sh" ] && __excluded=1
done
if [ "$__excluded" = "1" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "lib/repo-root.sh must be on the exclude list — it IS the canonical write-side bare --show-toplevel"
fi

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
