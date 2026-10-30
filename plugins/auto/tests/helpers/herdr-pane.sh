# Sourced by tests that drive programme verbs as herdr sessions (R21: start, become-pm and takeover need a proven pane).
# Needs AUTO_ROOT, PY and WORK, and a fake herdr first on PATH that answers `pane get <pane>`.

pane_for() { # pane_for <session> [workspace]: a stable pane id in the workspace
  printf '%s:p%s' "${2:-w2}" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}

register_session() { # register_session <session> [workspace]: the SessionStart row herdr would have written
  local sid="$1" ws="${2:-w2}" mark
  mark="${WORK}/.registered-${sid}-${ws}"
  [ -e "$mark" ] && return 0
  : > "$mark"
  # A test that registered the session itself keeps its own pane.
  "$PY" - "$AUTO_ROOT" "$sid" <<'PYEOF' && return 0
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.exit(0 if load_lib_module("session_registry").lookup(sys.argv[2], include_headless=True) else 1)
PYEOF
  local pf="${WORK}/.panefake"
  if [ ! -x "${pf}/herdr" ]; then
    mkdir -p "$pf"
    cat > "${pf}/herdr" <<'FAKE'
#!/bin/bash
[ "$1 ${2:-}" = "pane get" ] || exit 0
pane="$3"
printf '{"id":"cli:pane:get","result":{"pane":{"pane_id":"%s","workspace_id":"%s","terminal_id":"term_%s","tab_id":"%s:t1"}},"type":"pane_info"}\n' \
  "$pane" "${pane%%:*}" "${pane##*:}" "${pane%%:*}"
FAKE
    chmod +x "${pf}/herdr"
  fi
  printf '{"session_id":"%s","source":"startup","cwd":"/tmp"}' "$sid" |
    env -u CLAUDE_CODE_ENTRYPOINT PATH="${pf}:${PATH}" HERDR_PANE_ID="$(pane_for "$sid" "$ws")" HERDR_WORKSPACE_ID="$ws" \
      "$PY" "${AUTO_ROOT}/lib/session_registry.py" record
}

as_pane() { # as_pane <session> <workspace> <command...>: run as that session, in its own pane, with its row written
  local sid="$1" ws="$2"
  shift 2
  register_session "$sid" "$ws"
  env CLAUDE_CODE_SESSION_ID="$sid" HERDR_PANE_ID="$(pane_for "$sid" "$ws")" HERDR_WORKSPACE_ID="$ws" "$@"
}
