#!/usr/bin/env bash
# Prints one Linear issue in full, as the issue envelope:
#   {"schema": 1, "status": ok|partial|unavailable|unknown, "message": ...,
#    "issue": {...}, "truncated": [...]}
#
#   work-issue.sh <issue-id>
#
# The board's issue page reads this when it opens. It is a single Linear call:
# every paged connection is asked for once and what does not fit is named in
# `truncated` rather than drained, so an issue with a thousand comments costs
# the same as one with none.
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

ISSUE_TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$ISSUE_TMP"' EXIT

issue_main() {
    local id="${1:-}" status message="" rc

    herdr_linear::is_bind_identifier "$id" || return 2

    herdr_linear::keychain_skip_if_stalled "$HERDR_LINEAR_KEYCHAIN_SERVICE" "$HERDR_LINEAR_KEYCHAIN_ACCOUNT"
    : >"$ISSUE_TMP/body"
    # The query layer reports a missing key and a refused key as the same
    # code, so the missing one is settled here before any request.
    herdr_linear::credential >/dev/null 2>&1; rc=$?
    case "$rc" in
        0|2)
            herdr_linear::fetch_issue_detail "$id" >"$ISSUE_TMP/body" 2>/dev/null; rc=$?
            case "$rc" in
                "$HERDR_LINEAR_OK")          status=ok ;;
                "$HERDR_LINEAR_NOT_FOUND")   status=unavailable; message="Linear has no issue $id" ;;
                "$HERDR_LINEAR_AUTH")        status=unavailable; message="Linear refused the credential" ;;
                "$HERDR_LINEAR_UNAVAILABLE") status=unavailable; message="Linear could not be reached" ;;
                "$HERDR_LINEAR_RATELIMITED") status=unavailable; message="Linear is rate limiting requests" ;;
                *)                           status=unknown; message="the issue read ended without an answer" ;;
            esac
            ;;
        *) status=unavailable; message="no Linear credential is configured" ;;
    esac
    case "$status" in ok) ;; *) : >"$ISSUE_TMP/body" ;; esac

    ISSUE_STATUS="$status" ISSUE_MESSAGE="$message" ISSUE_BODY="$ISSUE_TMP/body" \
    ISSUE_PAGE_SIZE="$HERDR_LINEAR_DETAIL_PAGE_SIZE" \
    python3 -c "$HERDR_LINEAR_STRIP_PY"'
import json, os

E = os.environ
status = E["ISSUE_STATUS"]
message = E["ISSUE_MESSAGE"]
cap = int(E["ISSUE_PAGE_SIZE"])
issue = None
truncated = []

def nodes(v):
    return (v or {}).get("nodes") or []

def more(v):
    return bool(((v or {}).get("pageInfo") or {}).get("hasNextPage"))

def linked(row, key):
    """A sub-issue, parent or relation row: identifier, title and status, so the
    board can open its page from this row alone."""
    r = (row or {}).get(key) or {}
    if not r.get("id"):
        return None
    return {"id": r.get("id"),
            "identifier": r.get("identifier"),
            "title": r.get("title"),
            "state": r.get("state") or None}

raw = ""
try:
    raw = open(E["ISSUE_BODY"], encoding="utf-8", errors="replace").read()
except OSError:
    raw = ""

if status == "ok":
    try:
        src = (json.loads(raw).get("data") or {}).get("issue")
    except Exception:
        src = None
    if not src:
        status = "unavailable"
        message = "Linear answered with no issue"
    else:
        # Relations name the other issue from two sides: `relations` is what
        # this issue points at, `inverseRelations` what points at it. Linear
        # draws both on the page, so both are carried, each keeping the type
        # that describes the direction it was read from.
        relations = []
        for row in nodes(src.get("relations")):
            other = linked(row, "relatedIssue")
            if other:
                relations.append({"type": row.get("type"), "direction": "outward", "issue": other})
        for row in nodes(src.get("inverseRelations")):
            other = linked(row, "issue")
            if other:
                relations.append({"type": row.get("type"), "direction": "inward", "issue": other})

        comments = []
        for row in nodes(src.get("comments")):
            comments.append({"id": row.get("id"),
                             "body": row.get("body"),
                             "created_at": row.get("createdAt"),
                             "author": (row.get("user") or {}).get("name"),
                             "parent_id": (row.get("parent") or {}).get("id")})

        history = []
        for row in nodes(src.get("history")):
            entry = {"id": row.get("id"),
                     "created_at": row.get("createdAt"),
                     "actor": (row.get("actor") or {}).get("name"),
                     "from_state": (row.get("fromState") or {}).get("name"),
                     "to_state": (row.get("toState") or {}).get("name"),
                     "from_assignee": (row.get("fromAssignee") or {}).get("name"),
                     "to_assignee": (row.get("toAssignee") or {}).get("name"),
                     "from_priority": row.get("fromPriority"),
                     "to_priority": row.get("toPriority"),
                     "added_labels": [l.get("name") for l in (row.get("addedLabels") or [])],
                     "removed_labels": [l.get("name") for l in (row.get("removedLabels") or [])]}
            # A history row that changed nothing this reads is not an event the
            # page can phrase, and Linear returns those for edits to fields the
            # board does not show.
            if any(entry[k] is not None for k in
                   ("from_state", "to_state", "from_assignee", "to_assignee",
                    "from_priority", "to_priority")) or entry["added_labels"] or entry["removed_labels"]:
                history.append(entry)

        children = [c for c in (linked({"c": n}, "c") for n in nodes(src.get("children"))) if c]

        issue = {
            "id": src.get("id"),
            "identifier": src.get("identifier"),
            "title": src.get("title"),
            "url": src.get("url"),
            "description": src.get("description"),
            "updated_at": src.get("updatedAt"),
            "due_date": src.get("dueDate"),
            "estimate": src.get("estimate"),
            "priority": src.get("priority"),
            "state": src.get("state") or None,
            "assignee": src.get("assignee") or None,
            "labels": [n.get("name") for n in nodes(src.get("labels"))],
            "project": src.get("project") or None,
            "milestone": src.get("projectMilestone") or None,
            "cycle": src.get("cycle") or None,
            "parent": linked(src, "parent"),
            "children": children,
            "relations": relations,
            "comments": comments,
            "history": history,
        }

        for key, name in (("children", "children"), ("comments", "comments"),
                          ("history", "history"), ("relations", "relations"),
                          ("inverseRelations", "relations")):
            if more(src.get(key)) and name not in truncated:
                truncated.append(name)
        if truncated:
            status = "partial"
            message = "read the first %d of %s; the rest is in Linear" % (
                cap, " and ".join(truncated))

doc = {"schema": 1,
       "status": status,
       "message": clean(message) or None,
       "issue": deep_clean(issue) if issue else None,
       "truncated": truncated}
print(json.dumps(doc, sort_keys=True, indent=2))
'
}

out="$(issue_main "$@")"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
fi
[ "$rc" -eq 0 ] && rc=1
exit "$rc"
