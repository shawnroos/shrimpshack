#!/usr/bin/env bash
# Prints the Linear projects the person is a member of, as the list envelope
# {status, message, rows:[{id, name, team_key}]}.
#
#   work-projects.sh
#
# Exit 0 with an envelope, whatever its status; 2 when an argument is given;
# anything else with nothing on stdout.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd -P)" || LIB_DIR=""
for f in sanitize.sh secrets.sh linear.sh; do
    if [ -z "$LIB_DIR" ] || [ ! -r "$LIB_DIR/$f" ]; then
        printf 'cannot find lib/%s beside this script\n' "$f" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$LIB_DIR/$f"
done

# Nobody can answer a keychain unlock prompt from here.
export HERDR_LINEAR_KEYCHAIN_TIMEOUT_SECONDS="${HERDR_LINEAR_KEYCHAIN_TIMEOUT_SECONDS:-5}"

projects_main() {
    local status=ok message="" rows="[]" out rc

    [ "$#" -eq 0 ] || return 2

    herdr_linear::keychain_skip_if_stalled "$HERDR_LINEAR_KEYCHAIN_SERVICE" "$HERDR_LINEAR_KEYCHAIN_ACCOUNT"

    # The library maps a missing key and a refused key to the same code, so the
    # credential is resolved here first to tell the two apart.
    herdr_linear::credential >/dev/null 2>&1; rc=$?
    case "$rc" in
        0|2)
            out="$(herdr_linear::my_projects)"; rc=$?
            case "$rc" in
                "$HERDR_LINEAR_OK") rows="$out" ;;
                "$HERDR_LINEAR_PARTIAL")
                    rows="$out"; status=partial
                    message="listed the first $HERDR_LINEAR_VIEW_PAGE_MAX pages of projects only"
                    ;;
                "$HERDR_LINEAR_AUTH") status=unavailable; message="Linear refused the credential" ;;
                "$HERDR_LINEAR_RATELIMITED") status=unavailable; message="Linear is rate limiting this credential" ;;
                "$HERDR_LINEAR_UNAVAILABLE") status=unavailable; message="Linear could not be reached" ;;
                *) status=unknown; message="the project read ended unexpectedly" ;;
            esac
            ;;
        *) status=unavailable; message="no Linear credential is configured" ;;
    esac

    printf '%s' "$rows" | LIST_STATUS="$status" LIST_MESSAGE="$message" \
        python3 -c "$HERDR_LINEAR_STRIP_PY"'
import json, os, sys

# The ranges keep tab, newline and carriage return for documents; a picker row
# is one line, so they go too.
STRIP += [(9, 10), (13, 13)]

rows = json.load(sys.stdin)
if not isinstance(rows, list):
    sys.exit(1)
rows = deep_clean(rows)
rows.sort(key=lambda r: (r.get("name") or "").casefold())
status = os.environ["LIST_STATUS"]
print(json.dumps(deep_clean({"status": status, "message": os.environ["LIST_MESSAGE"] or None,
                             "rows": rows if status in ("ok", "partial") else []}),
                 sort_keys=True))
'
}

out="$(projects_main "$@")"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
fi
[ "$rc" -eq 0 ] && rc=1
exit "$rc"
