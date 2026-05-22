#!/usr/bin/env bash
# claude-modes V2 hook shim: SessionStart.
#
# Cost-of-being-installed guarantee: presence gate first, silent when no
# modes directory exists. See plan System-Wide Impact.
#
# Responsibilities (U9):
#   - Presence gate (fast no-op when the plugin is dormant).
#   - Dispatch to the Python reconciliation orchestrator
#     (lib/reconcile-symlinks.py) which:
#       * Holds the user-global symlink flock for the critical section
#       * Reads per-branch / user-global active mode
#       * Computes target user-catalog manifest
#       * Skips on the no-op fast path; rebuilds via lib/symlink-rebuild.sh
#         otherwise; writes a divergence toast marker when a concurrent
#         worktree changed the mode underfoot
#       * Logs the contract anchor + outcome to ~/.claude/modes/.session-start.log
#
# U11 add (R20 path c — editor-written files):
#   - After U9's reconcile (which is `exec`'d, so we must run BEFORE it),
#     scan ~/.claude/commands/ and ~/.claude/agents/ for regular files that
#     appeared / changed since the snapshot at ~/.claude/modes/.last-file-scan.json.
#     For each new file, append a toast line to the per-session
#     ~/.claude/modes/.sessions/<session-id>.untagged-files marker. U10's
#     prose hook consumes + deletes the marker on the next UserPromptSubmit.
#   - First-run is BASELINE only (writes snapshot, emits no toast — user
#     hasn't seen the plugin announce anything yet).
#   - PostToolUse handler is a separate script: scripts/on-post-tool-use.sh.
#
# rel-001 contract: SessionStart hooks must NEVER block session start. We:
#   - exit 0 if the modes dir is absent (presence gate)
#   - exec the Python orchestrator; it wraps main() in try/except and
#     always exits 0 (so we'll always inherit a clean exit)
#   - belt-and-braces: append `|| true` to the exec so even an exec failure
#     can't propagate non-zero up to the harness
#
# Defaulting to /usr/bin/python3 — see lib/mode-yaml.sh header for the
# Apple-vs-Homebrew Python rationale.

set -uo pipefail

[ -d "${HOME}/.claude/modes" ] || exit 0

PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# Capture the SessionStart event JSON from stdin ONCE, up front. Two consumers
# need it: (a) the untagged-files scan below derives the session key from its
# `session_id` field — the SAME field every downstream consumer (inject-prose.sh,
# reconcile-symlinks.py, on-post-tool-use.sh) reads, so the marker we write lands
# under a key they will actually look up (round-7 correctness P1: the old code
# keyed off the CLAUDE_SESSION_ID *env var*, which the harness does not set equal
# to the JSON session_id, so the marker was written under a key no consumer read
# and the new-file toast was silently never delivered); (b) the exec'd
# reconcile-symlinks.py at the bottom, which we feed the captured JSON via a
# here-string so consuming stdin here doesn't starve it. `[ ! -t 0 ]` mirrors
# reconcile's isatty() guard so an interactive invocation doesn't hang on cat.
__cm_stdin_json=""
if [ ! -t 0 ]; then
  __cm_stdin_json=$(cat 2>/dev/null || true)
fi

# CLAUDE_PLUGIN_ROOT is set by the Claude Code harness at hook-invocation
# time. Defensive fallback: derive from this script's location.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# ─── U11: R20 SessionStart-scan ──────────────────────────────────────
# Detect editor-authored new/changed files in ~/.claude/{commands,agents}/
# and stage a per-session "untagged-files" marker for U10's prose hook.
# Wrapped in a brace-group with `|| true` so even a Python crash here
# can't poison the U9 reconcile that follows. Must run BEFORE the exec
# below (exec replaces the shell process).
{
  __cm_modes_dir="${HOME}/.claude/modes"
  __cm_commands_live="${HOME}/.claude/commands"
  __cm_agents_live="${HOME}/.claude/agents"
  __cm_snapshot="${__cm_modes_dir}/.last-file-scan.json"
  __cm_sessions_dir="${__cm_modes_dir}/.sessions"

  # Session-id retrieval. Derive from the stdin event JSON's `session_id` field
  # — the SAME field reconcile-symlinks.py._read_session_id and inject-prose.sh
  # use — so the marker key matches what consumers look up. Fall back to
  # ppid-<PPID> only when no JSON session_id is present.
  #
  # KNOWN no-JSON edge: when stdin carries no session_id (interactive invocation
  # or a harness that omits it), the writer's ppid-${PPID} and reconcile's
  # ppid-{os.getppid()} run in DIFFERENT processes → divergent keys. This case
  # is unavoidable without threading the key through, and it is recoverable noise
  # (a missed toast), not data loss. Parity holds in the normal case (harness
  # supplies session_id), which is what the round-7 finding was about.
  __cm_session_id=$("$PYTHON3" -c '
import json, os, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    sid = json.loads(raw).get("session_id") if raw else None
    if isinstance(sid, str) and sid:
        sys.stdout.write(sid); sys.exit(0)
except Exception:
    pass
sys.stdout.write("ppid-{}".format(os.getppid()))
' "$__cm_stdin_json" 2>/dev/null)
  [ -z "$__cm_session_id" ] && __cm_session_id="ppid-${PPID:-noppid}"

  mkdir -m 0700 -p "$__cm_sessions_dir" 2>/dev/null || true

  # C0: prune stale session markers (>7 days old). All marker classes
  # (.injected, .divergence-toast, .untagged-files) are consumed by
  # inject-prose.sh on the next UserPromptSubmit — but a session that ends
  # without a prompt (killed, machine slept) leaves them behind forever.
  # This is the 7-day pruner inject-prose.sh's header refers to. Best-effort.
  find "$__cm_sessions_dir" -type f -mtime +7 -delete 2>/dev/null || true

  # All scan + diff + snapshot-rewrite in one Python invocation for
  # atomic snapshot updates and consistent sha256 hashing.
  __cm_marker_lines=$("$PYTHON3" - \
    "$__cm_commands_live" "$__cm_agents_live" "$__cm_snapshot" <<'PYEOF' 2>/dev/null
import os, os.path, sys, hashlib, json, tempfile

commands_live = sys.argv[1]
agents_live   = sys.argv[2]
snapshot_path = sys.argv[3]

def sha256_file(p):
    h = hashlib.sha256()
    try:
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
    except (OSError, IOError):
        return None
    return h.hexdigest()

# Enumerate regular files (NOT symlinks, NOT directories) at depth 1.
def enum_regular(d):
    out = []
    if not os.path.isdir(d):
        return out
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for n in names:
        p = os.path.join(d, n)
        # os.path.islink first so a symlink-to-file is excluded by
        # is-not-link before isfile (which follows symlinks).
        if os.path.islink(p):
            continue
        if os.path.isfile(p):
            out.append(p)
    return out

current = []
for d in (commands_live, agents_live):
    for p in enum_regular(d):
        s = sha256_file(p)
        if s is None:
            continue
        current.append({"path": p, "sha256": s})

# Load prior snapshot (first-run distinction is based on file existence).
is_first_run = not os.path.isfile(snapshot_path)
prior = []
if not is_first_run:
    try:
        with open(snapshot_path) as f:
            prior = json.load(f) or []
            if not isinstance(prior, list):
                prior = []
    except Exception:
        prior = []

prior_by_path = {e.get("path"): e.get("sha256")
                 for e in prior if isinstance(e, dict)}

# Detect new-or-changed regular files.
new_entries = []
for cur in current:
    p = cur["path"]
    s = cur["sha256"]
    if p not in prior_by_path or prior_by_path[p] != s:
        new_entries.append(cur)

# Only emit toast lines when NOT first run (first-run = silent baseline).
if not is_first_run:
    home = os.path.expanduser("~")
    for e in new_entries:
        p = e["path"]
        display = "~" + p[len(home):] if p.startswith(home + os.sep) else p
        base = os.path.basename(p)
        sys.stdout.write(
            f"Untagged new file {display} — run /mode:adopt {base} "
            f"to scope to active mode, or leave global.\n"
        )

# Atomic snapshot rewrite (umask 077 + tempfile + os.rename). Mode 0600.
snap_dir = os.path.dirname(snapshot_path) or "."
os.makedirs(snap_dir, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".last-file-scan.", suffix=".json", dir=snap_dir)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(current, f, indent=2)
    os.rename(tmp, snapshot_path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
PYEOF
  ) || true

  if [ -n "$__cm_marker_lines" ]; then
    __cm_marker_file="${__cm_sessions_dir}/${__cm_session_id}.untagged-files"
    # Atomic append: write existing+new to a sibling tempfile, rename
    # into place. 0600 via umask subshell scope.
    (
      umask 077
      __cm_tmp=$(mktemp "${__cm_sessions_dir}/.untagged.XXXXXX") || exit 0
      if [ -f "$__cm_marker_file" ]; then
        cat "$__cm_marker_file" > "$__cm_tmp" 2>/dev/null || true
      fi
      printf '%s\n' "$__cm_marker_lines" >> "$__cm_tmp"
      mv "$__cm_tmp" "$__cm_marker_file" 2>/dev/null || rm -f "$__cm_tmp"
    ) || true
  fi

  unset __cm_modes_dir __cm_commands_live __cm_agents_live __cm_snapshot \
        __cm_sessions_dir __cm_session_id __cm_marker_lines __cm_marker_file \
        2>/dev/null || true
} || true

# Feed reconcile the SAME captured stdin JSON (we consumed real stdin above to
# derive the session key; the here-string replays it so reconcile's own
# _read_session_id sees the identical session_id). Empty → reconcile's existing
# timeout/fallback path.
exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/reconcile-symlinks.py" <<< "$__cm_stdin_json" || true

# If exec returned, defensive exit-0.
exit 0
