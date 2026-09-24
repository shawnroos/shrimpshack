#!/usr/bin/env bash
# Prints every herdr space with its binding state, as the list envelope:
#   {"status": ok|unavailable|unknown, "message": ...,
#    "rows": [{"id", "label", "live", "state", "project_id", "project_name"}]}
#
#   work-spaces.sh
#
# Exit 0 with an envelope, whatever its status; 2 when an argument is given;
# anything else with nothing on stdout. docs/spaces.md has the contract.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd -P)" || LIB_DIR=""
if [ -z "$LIB_DIR" ] || [ ! -r "$LIB_DIR/sanitize.sh" ]; then
    printf 'cannot find lib/sanitize.sh beside this script\n' >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$LIB_DIR/sanitize.sh"
for f in record.sh binding.sh scope-record.sh herdr-read.sh; do
    if [ ! -r "$LIB_DIR/$f" ]; then
        printf 'cannot find lib/%s beside this script\n' "$f" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$LIB_DIR/$f"
done

SPACES_TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$SPACES_TMP"' EXIT

spaces_main() {
    local status=ok message="" bin

    [ "$#" -eq 0 ] || return 2

    : >"$SPACES_TMP/live"
    : >"$SPACES_TMP/records"
    # live_spaces prints `id TAB label` lines, and a label carrying a newline
    # would forge a space; the raw answer goes to python3 instead.
    bin="$(herdr_linear::bin)"
    if [ -z "$bin" ] || ! herdr_linear::probe; then
        status=unavailable; message="herdr is not running"
    elif ! herdr_linear::_bounded "$bin" workspace list >"$SPACES_TMP/live" 2>/dev/null; then
        status=unavailable; message="herdr did not list its spaces"
    elif ! herdr_linear::workspaces_effective >"$SPACES_TMP/records" 2>/dev/null; then
        status=unknown; message="the space records could not be read"
    fi

    SPACES_STATUS="$status" SPACES_MESSAGE="$message" \
    SPACES_LIVE="$SPACES_TMP/live" SPACES_RECORDS="$SPACES_TMP/records" \
    python3 -c "$HERDR_LINEAR_STRIP_PY"'
import json, os, re, sys

E = os.environ

# The ranges keep tab, newline and carriage return for documents; a picker row
# is one line, so they go too.
STRIP += [(9, 10), (13, 13)]

# Narrower than _workspace_record_path, which admits a leading dash: a row id
# is passed on to a bind, where `-rf` would read as an option.
WS_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", re.ASCII)

status, message = E["SPACES_STATUS"], E["SPACES_MESSAGE"]
live = []
if status == "ok":
    try:
        spaces = json.load(open(E["SPACES_LIVE"]))["result"]["workspaces"]
        if not isinstance(spaces, list):
            raise ValueError
    except Exception:
        status, message = "unavailable", "herdr did not list its spaces"
        spaces = []
    for w in spaces:
        wid = w.get("workspace_id") if isinstance(w, dict) else None
        if not isinstance(wid, str) or not WS_ID.fullmatch(wid) or wid in (x[0] for x in live):
            continue
        label = w.get("label")
        live.append((wid, clean(label) if isinstance(label, str) else ""))

records = {}
if status == "ok":
    try:
        for line in open(E["SPACES_RECORDS"], encoding="utf-8").read().split("\n"):
            if not line:
                continue
            r = json.loads(line)
            if WS_ID.fullmatch(r.get("id") or ""):
                records.setdefault(r["id"], r)
    except Exception:
        status, message = "unknown", "the space records could not be read"
        records = {}

def row(wid, label, is_live):
    r = records.get(wid) or {}
    pid, name = r.get("project_id"), r.get("project_name")
    return {"id": wid, "label": label or wid, "live": is_live,
            "state": r.get("state") or "unbound",
            "project_id": clean(pid) if isinstance(pid, str) and pid else None,
            "project_name": clean(name) if isinstance(name, str) else None}

rows = []
if status == "ok":
    seen = set()
    for wid, label in live:
        rows.append(row(wid, label, True))
        seen.add(wid)
    for wid in sorted(records):
        if wid not in seen:
            rows.append(row(wid, "", False))

print(json.dumps({"status": status, "message": clean(message) or None, "rows": rows},
                 sort_keys=True, indent=2))
'
}

out="$(spaces_main "$@")"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
fi
[ "$rc" -eq 0 ] && rc=1
exit "$rc"
