#!/usr/bin/env bash
#
# probe_boundary_check.sh — KTD9, enforced rather than stated.
#
# A probe is stored agent-authored shell run with the operator's privileges. It
# runs only inside the attended `/reflect:reflect-retro` session. Without this
# check a later change wires probes into a hook, no test fails, and stored shell
# silently becomes unattended execution.
#
# DEFAULT-DENY, not an evasion list. An earlier version grepped two unattended
# paths for the entry point, which failed twice over: it never looked in
# `.claude/hooks/hooks.json`, where hooks are actually DECLARED and where the
# existing entries already run inline shell; and a quoted or variable-built
# invocation walked past its pattern. Enumerating permitted forms is
# default-allow, and default-allow always leaks. So this asks the opposite
# question: WHICH files reference the probe runner at all? Anything outside the
# allowlist fails, however it is written.
#
# Usage: probe_boundary_check.sh [plugin-root]   (exit 0 clean, 1 breached/broken)

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOKS_JSON="$ROOT/.claude/hooks/hooks.json"
RUNNER="$ROOT/scripts/reflect-run.sh"

# Asserted, never assumed: grep exits 2 on a missing target, and a bare
# `! grep ...` turns that into a pass forever the moment a path moves.
for target in "$ROOT/hooks" "$RUNNER" "$HOOKS_JSON" "$ROOT/scripts/retro.py"; do
  if [ ! -e "$target" ]; then
    echo "probe_boundary_check: search target missing: $target" >&2
    exit 1
  fi
done

fail=0

# 1. Which files name the probe runner, or the writer that grants a probe its
#    approval, at all? Everything outside the allowlist is a breach. The
#    allowlist is the definition site, its tests, this check, and the attended
#    command — the one place KTD9 permits. Approval is included because a probe
#    approved from an unattended path is executed shell nobody agreed to.
ALLOWED='^(scripts/retro\.py|tests/retro_test\.py|tests/probe_boundary_check\.sh|commands/reflect-retro\.md|docs/)'
# -I skips binaries: a compiled .pyc carries the symbol and is not a call site.
offenders="$(cd "$ROOT" && grep -rEl -I --exclude-dir=__pycache__ --exclude-dir=.git \
  'run_probes?\b|record_probe_approval\b' . 2>/dev/null | sed 's|^\./||' | grep -Ev "$ALLOWED" || true)"
if [ -n "$offenders" ]; then
  echo "probe_boundary_check: probe runner referenced outside the attended path (KTD9):" >&2
  echo "$offenders" >&2
  fail=1
fi

# 2. No hook may reach retro.py by ANY subcommand. The capture hook is pure
#    shell and calls nothing in scripts/, so this is a flat ban rather than a
#    per-subcommand one — a flat ban cannot be walked past by renaming a
#    subcommand.
hook_hits="$(grep -rEn 'retro\.py' "$ROOT/hooks" "$HOOKS_JSON" 2>/dev/null || true)"
if [ -n "$hook_hits" ]; then
  echo "probe_boundary_check: a hook reaches retro.py; hooks must never call it (KTD9):" >&2
  echo "$hook_hits" >&2
  fail=1
fi

# 3. The runner may call retro.py (it reads the backlog counts) but must never
#    reach the probe subcommand.
runner_hits="$(grep -En 'retro\.py[^|]*\bprobe\b|run_probes?\b' "$RUNNER" 2>/dev/null || true)"
if [ -n "$runner_hits" ]; then
  echo "probe_boundary_check: reflect-run.sh reaches the probe runner (KTD9):" >&2
  echo "$runner_hits" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "probe_boundary_check: clean — no hook and no automatic pass reaches the probe runner"
exit 0
