#!/usr/bin/env bash
# SessionEnd: let Linear catch up with the repository.
#
# WHY SessionEnd AND NOT Stop (KTD14)
# `Stop` can block a session from ending. R19 says nothing this plugin installs
# may do that, and a tracker write is the last thing that should be able to hold
# a terminal open. `SessionEnd` cannot block, and this hook additionally exits 0
# on every path so that even a crash inside it is invisible to the session.
#
# THIS HOOK NEVER PROMPTS (KTD13)
# It runs while a session is ending; there is nobody to answer. Anything needing
# judgment is recorded against the binding and surfaced by the grounding hook at
# the start of the next session in that worktree.
#
# SHADOW MODE IS ON UNLESS A WORKTREE IS EXPLICITLY LISTED. See lib/reconcile.sh.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)" || exit 0
LIB="$PLUGIN_DIR/lib"
for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh; do
    # shellcheck source=/dev/null
    [ -r "$LIB/$f" ] && . "$LIB/$f" 2>/dev/null
done

payload="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$payload" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("cwd", "") or "")
except Exception:
    print("")
' 2>/dev/null)"
[ -n "$cwd" ] || exit 0

command -v herdr_linear::reconcile >/dev/null 2>&1 || exit 0

# Nothing is printed. A SessionEnd hook has no channel to the model, and stray
# output on a closing session is noise in someone's terminal.
herdr_linear::reconcile "$cwd" >/dev/null 2>&1

exit 0
