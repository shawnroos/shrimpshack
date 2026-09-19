#!/usr/bin/env bash
# Prints the views that name one Linear project, as the list envelope:
#   {"status": ok|unavailable|partial|unknown, "message": ..., "rows": [{"id", "name"}]}
#
#   work-views.sh <project-id>
#
# Exit 0 with an envelope, 2 when the argument is refused, anything else with
# nothing on stdout.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd -P)" || LIB_DIR=""
if [ -z "$LIB_DIR" ] || [ ! -r "$LIB_DIR/sanitize.sh" ]; then
    printf 'cannot find lib/sanitize.sh beside this script\n' >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$LIB_DIR/sanitize.sh"
for f in secrets.sh linear.sh bind-args.sh; do
    if [ ! -r "$LIB_DIR/$f" ]; then
        printf 'cannot find lib/%s beside this script\n' "$f" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$LIB_DIR/$f"
done

# Nobody can answer a keychain unlock prompt from here.
export HERDR_LINEAR_KEYCHAIN_TIMEOUT_SECONDS="${HERDR_LINEAR_KEYCHAIN_TIMEOUT_SECONDS:-5}"

VIEWS_TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$VIEWS_TMP"' EXIT

views_main() {
    local project="${1:-}" status message="" rc

    herdr_linear::is_bind_identifier "$project" || return 2

    herdr_linear::keychain_skip_if_stalled "$HERDR_LINEAR_KEYCHAIN_SERVICE" "$HERDR_LINEAR_KEYCHAIN_ACCOUNT"
    : >"$VIEWS_TMP/rows"
    # The query layer reports a missing key and a refused key as the same
    # code, so the missing one is settled here before any request.
    herdr_linear::credential >/dev/null 2>&1; rc=$?
    case "$rc" in
        0|2)
            herdr_linear::project_views "$project" >"$VIEWS_TMP/rows" 2>/dev/null; rc=$?
            case "$rc" in
                "$HERDR_LINEAR_OK") status=ok ;;
                "$HERDR_LINEAR_PARTIAL")
                    status=partial
                    message="listed the first $HERDR_LINEAR_VIEW_PAGE_MAX pages of views only; a view past that can be chosen by its id"
                    ;;
                "$HERDR_LINEAR_AUTH")        status=unavailable; message="Linear refused the credential" ;;
                "$HERDR_LINEAR_UNAVAILABLE") status=unavailable; message="Linear could not be reached" ;;
                "$HERDR_LINEAR_RATELIMITED") status=unavailable; message="Linear is rate limiting requests" ;;
                *)                           status=unknown; message="the views read ended without an answer" ;;
            esac
            ;;
        *) status=unavailable; message="no Linear credential is configured" ;;
    esac
    case "$status" in ok|partial) ;; *) : >"$VIEWS_TMP/rows" ;; esac

    VIEWS_STATUS="$status" VIEWS_MESSAGE="$message" VIEWS_ROWS="$VIEWS_TMP/rows" \
    python3 -c "$HERDR_LINEAR_STRIP_PY"'
import json, os, re, sys

E = os.environ

ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", re.ASCII)

rows = []
# split("\n"), not splitlines(): splitlines also breaks on U+2028 and the other
# line-like codepoints a name may carry.
for line in open(E["VIEWS_ROWS"], encoding="utf-8", errors="replace").read().split("\n"):
    parts = line.split("\t")
    # The library strips tabs from a name, so a second tab came from the id
    # and would shift part of it into the name.
    if len(parts) != 2 or not ID.fullmatch(parts[0]):
        continue
    rows.append({"id": parts[0], "name": clean(parts[1])})

print(json.dumps({"status": E["VIEWS_STATUS"],
                  "message": clean(E["VIEWS_MESSAGE"]) or None,
                  "rows": rows}, sort_keys=True, indent=2))
'
}

out="$(views_main "$@")"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
fi
[ "$rc" -eq 0 ] && rc=1
exit "$rc"
