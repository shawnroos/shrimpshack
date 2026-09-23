#!/usr/bin/env bash
# Prints the space snapshot of docs/snapshot.md for one herdr workspace.
#
#   work-snapshot.sh <workspace-id>
#
# Exit 0 with a document, 2 when the argument is refused, 3 when herdr lists
# no such space and no record exists, anything else with nothing on stdout.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd -P)" || LIB_DIR=""
for f in sanitize.sh secrets.sh record.sh binding.sh scope-record.sh linear.sh herdr-read.sh context.sh; do
    if [ -z "$LIB_DIR" ] || [ ! -r "$LIB_DIR/$f" ]; then
        printf 'cannot find lib/%s beside this script\n' "$f" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$LIB_DIR/$f"
done

# Nobody can answer a keychain unlock prompt from here.
export HERDR_LINEAR_KEYCHAIN_TIMEOUT_SECONDS="${HERDR_LINEAR_KEYCHAIN_TIMEOUT_SECONDS:-5}"

SNAP_TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$SNAP_TMP"' EXIT

json_field() {
    printf '%s' "$1" | HERDR_SNAP_FIELD="$2" python3 -c '
import sys, json, os
try:
    v = json.load(sys.stdin).get(os.environ["HERDR_SNAP_FIELD"])
except Exception:
    v = None
sys.stdout.write("" if v is None else (v if isinstance(v, str) else json.dumps(v)))
' 2>/dev/null
}

snapshot_main() {
    local ws="${1:-}" rec_file record_status=missing record_state=unbound record_json="" project_id=""
    local herdr_status=unavailable spaces="" snap=""
    local linear_status=unknown view_status=none view_id="" view_name="" view_json="" issues_json="" project_json="" states_json=""
    local rec_view vr rc have_cred=0 filter tid

    rec_file="$(herdr_linear::_workspace_record_path "$ws")" || return 2

    if [ -e "$rec_file" ]; then
        if herdr_linear::_mode_ok "$rec_file" && record_json="$(herdr_linear::_py read "$rec_file")"; then
            record_status=ok
            record_state="$(json_field "$record_json" state)"
            project_id="$(json_field "$record_json" issue_identifier)"
        else
            record_status=unreadable
            record_state=""
            record_json=""
        fi
    fi

    if herdr_linear::probe && spaces="$(herdr_linear::live_spaces)" \
        && snap="$(herdr_linear::snapshot)" && [ -n "$snap" ]; then
        herdr_status=ok
    fi

    if [ "$record_status" = missing ] && [ "$herdr_status" = ok ]; then
        printf '%s\n' "$spaces" | awk -F'\t' -v w="$ws" '$1 == w { f = 1 } END { exit !f }' || return 3
    fi

    if [ "$record_status" = ok ] && [ "$record_state" = bound ]; then
        rec_view="$(herdr_linear::workspace_view "$ws" 2>/dev/null)" || rec_view=""
        if [ -n "$rec_view" ]; then
            view_id="$(json_field "$rec_view" id)"
            view_name="$(json_field "$rec_view" name)"
            view_status=unreadable
        fi

        herdr_linear::keychain_skip_if_stalled "$HERDR_LINEAR_KEYCHAIN_SERVICE" "$HERDR_LINEAR_KEYCHAIN_ACCOUNT"
        herdr_linear::credential >/dev/null 2>&1; rc=$?
        case "$rc" in 0|2) have_cred=1 ;; esac

        if [ "$have_cred" -eq 1 ]; then
            linear_status=ok
            if [ -n "$view_id" ]; then
                vr="$(herdr_linear::view_read "$view_id")"; rc=$?
                case "$rc" in
                    0)
                        view_json="$vr"
                        if [ "$(json_field "$vr" archived)" = true ]; then
                            view_status=archived
                        elif ! herdr_linear::filter_names_project "$(json_field "$vr" filter)" "$project_id"; then
                            # Checked on every read, not only when chosen: a
                            # filter edited in Linear to drop the project
                            # would otherwise board another project's issues.
                            view_status=not_in_project
                        else
                            case "$(json_field "$(json_field "$vr" layout)" grouping)" in
                                workflowState|assignee|priority|label|project) view_status=ok ;;
                                *) view_status=unsupported_grouping ;;
                            esac
                        fi
                        ;;
                    "$HERDR_LINEAR_NOT_FOUND") view_status=not_found ;;
                    *) linear_status=unavailable ;;
                esac
            fi
            if [ "$linear_status" = ok ]; then
                if [ "$view_status" = ok ]; then
                    filter="$(json_field "$view_json" filter)"
                    issues_json="$(herdr_linear::view_issues "$filter")" || linear_status=unavailable
                else
                    issues_json="$(herdr_linear::project_issues "$project_id")" || linear_status=unavailable
                fi
            fi
            if [ "$linear_status" = ok ]; then
                project_json="$(herdr_linear::project_read "$project_id")" || linear_status=unavailable
            fi
            if [ "$linear_status" = ok ]; then
                states_json="$(printf '%s' "$project_json" | python3 -c '
import sys, json
teams = ((json.load(sys.stdin).get("teams") or {}).get("nodes")) or []
if not teams:
    sys.exit(0)
states = (teams[0].get("states") or {}).get("nodes")
if not isinstance(states, list):
    sys.exit(1)
print(json.dumps({"key": teams[0].get("key"), "states": states}))
' 2>/dev/null)" || linear_status=unavailable
            fi
            if [ "$linear_status" = ok ] && [ "$(json_field "$issues_json" truncated)" = true ]; then
                linear_status=truncated
            fi
        else
            linear_status=unavailable
        fi
        if [ "$linear_status" = unavailable ]; then
            # A view that was read keeps what the read found; only a status
            # that needs the view's layout, now dropped, becomes unreadable.
            case "$view_status" in ok|unsupported_grouping) view_status=unreadable ;; esac
            view_json=""; issues_json=""; project_json=""; states_json=""
        fi
    fi

    : >"$SNAP_TMP/bindings"
    : >"$SNAP_TMP/cache"
    if [ "$record_status" = ok ] && [ "$record_state" = bound ]; then
        local file ident path tab eff cached
        # A non-whitespace separator: `read` collapses consecutive tabs, so an
        # empty tab field would shift the state into the tab's place.
        while IFS=$'\x1f' read -r file ident path tab eff; do
            [ -n "$file" ] && [ -n "$eff" ] || continue
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$file" "$ident" "$path" "$tab" "$eff" >>"$SNAP_TMP/bindings"
            if [ "$linear_status" = unavailable ] && [ -n "$ident" ]; then
                # One line per entry: the cache writer pretty-prints, and the
                # reader below takes a whole document per line.
                cached="$(herdr_linear::cache_read "$ident" 2>/dev/null \
                    | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)))' 2>/dev/null)" || cached=""
                [ -n "$cached" ] && printf '%s\t%s\n' "$ident" "$cached" >>"$SNAP_TMP/cache"
            fi
        done < <(herdr_linear::bindings_effective)
    fi

    # The listing, the project and the herdr snapshot go to python3 as files:
    # one environment string is capped at 128 KiB on Linux, and a real
    # project's listing has already passed 200 KB.
    printf '%s' "$issues_json" >"$SNAP_TMP/issues"
    printf '%s' "$project_json" >"$SNAP_TMP/project"
    printf '%s' "$snap" >"$SNAP_TMP/snapshot"

    SNAP_WS="$ws" SNAP_RECORD_STATUS="$record_status" SNAP_RECORD_STATE="$record_state" \
    SNAP_PROJECT_ID="$project_id" SNAP_HERDR_STATUS="$herdr_status" SNAP_SPACES="$spaces" \
    SNAP_SNAPSHOT_FILE="$SNAP_TMP/snapshot" SNAP_LINEAR_STATUS="$linear_status" SNAP_VIEW_STATUS="$view_status" \
    SNAP_VIEW_ID="$view_id" SNAP_VIEW_NAME="$view_name" SNAP_VIEW="$view_json" \
    SNAP_ISSUES_FILE="$SNAP_TMP/issues" SNAP_PROJECT_FILE="$SNAP_TMP/project" SNAP_STATES="$states_json" \
    SNAP_BINDINGS="$SNAP_TMP/bindings" SNAP_CACHE="$SNAP_TMP/cache" \
    python3 -c "$HERDR_LINEAR_STRIP_PY"'
import calendar, json, os, sys, time

E = os.environ
def env_json(name):
    raw = E.get(name) or ""
    return json.loads(raw) if raw else None
def file_json(name):
    raw = open(E[name]).read()
    return json.loads(raw) if raw else None

ws = E["SNAP_WS"]
herdr_ok = E["SNAP_HERDR_STATUS"] == "ok"
record_status = E["SNAP_RECORD_STATUS"]
record_state = E["SNAP_RECORD_STATE"] or None
bound = record_status == "ok" and record_state == "bound"
linear_status = E["SNAP_LINEAR_STATUS"]
view_status = E["SNAP_VIEW_STATUS"]
view = env_json("SNAP_VIEW")
listing = file_json("SNAP_ISSUES_FILE") or {}
project = file_json("SNAP_PROJECT_FILE") or {}
team = env_json("SNAP_STATES") or {}
states = team.get("states") or []

label, live = ws, None
if herdr_ok:
    live = False
    # split("\n"), not splitlines(): splitlines also breaks on U+2028, VT, FF
    # and the other line-like codepoints a label may carry, and cuts it short.
    for line in (E.get("SNAP_SPACES") or "").split("\n"):
        parts = line.split("\t", 1)
        if parts[0] == ws:
            live = True
            label = parts[1] if len(parts) > 1 and parts[1] else ws
            break

snap = {}
if herdr_ok:
    try:
        snap = file_json("SNAP_SNAPSHOT_FILE")["result"]["snapshot"]
    except Exception:
        snap = {}
tabs = [t for t in (snap.get("tabs") or []) if isinstance(t, dict)]
panes = [p for p in (snap.get("panes") or []) if isinstance(p, dict)]
tab_label = {t.get("tab_id"): t.get("label") for t in tabs}
def panes_in(tab_id):
    return [p.get("pane_id") for p in panes if p.get("tab_id") == tab_id and p.get("pane_id")]

issues = {}
cache_ages = []
now = calendar.timegm(time.gmtime())
if bound and linear_status in ("ok", "truncated"):
    for n in listing.get("nodes") or []:
        ident = n.get("identifier")
        if not ident:
            continue
        st = n.get("state") or {}
        a = n.get("assignee")
        labels = ((n.get("labels") or {}).get("nodes")) or []
        issues[ident] = {
            "id": n.get("id"), "identifier": ident, "title": n.get("title") or "",
            "url": n.get("url"),
            "state": {"id": st.get("id"), "name": st.get("name"), "type": st.get("type")},
            "assignee": {"id": a.get("id"), "name": a.get("name")} if isinstance(a, dict) else None,
            "priority": n.get("priority"),
            "labels": [l.get("name") for l in labels if isinstance(l, dict)],
            "stale": False, "bindings": [],
            "_raw": n,
        }
elif bound and linear_status == "unavailable":
    for line in open(E["SNAP_CACHE"]):
        line = line.rstrip("\n")
        if "\t" not in line:
            continue
        ident, raw = line.split("\t", 1)
        try:
            c = json.loads(raw)
        except Exception:
            continue
        if ident in issues:
            continue
        issues[ident] = {
            "id": None, "identifier": ident, "title": c.get("title") or "", "url": None,
            "state": {"id": None, "name": c.get("status") or "", "type": None},
            "assignee": None, "priority": None, "labels": [], "stale": True, "bindings": [],
            "_raw": c,
        }
        try:
            fetched = calendar.timegm(time.strptime(c.get("fetchedAt", ""), "%Y-%m-%dT%H:%M:%SZ"))
            cache_ages.append(max(0, now - fetched))
        except Exception:
            pass

groups = []
PRIORITY = {0: "No priority", 1: "Urgent", 2: "High", 3: "Medium", 4: "Low"}
state_name = {s.get("id"): s.get("name") for s in states}
state_type = {s.get("id"): s.get("type") for s in states}
if bound and linear_status in ("ok", "truncated"):
    layout = (view or {}).get("layout") or {}
    usable = view_status == "ok"
    grouping = layout.get("grouping") if usable else "workflowState"
    hidden = set(layout.get("hidden") or []) if usable else set()
    order = list(layout.get("column_order") or []) if usable else []
    keys = {}       # key -> (label, [identifiers])
    appearance = []
    def put(key, label, ident):
        if key not in keys:
            keys[key] = [label, []]
            appearance.append(key)
        keys[key][1].append(ident)
    for ident in issues:
        raw = issues[ident]["_raw"]
        if grouping == "workflowState":
            st = raw.get("state") or {}
            put(st.get("id"), state_name.get(st.get("id")) or st.get("name") or st.get("id"), ident)
        elif grouping == "assignee":
            a = raw.get("assignee")
            if isinstance(a, dict) and a.get("id"):
                put(a["id"], a.get("name") or a["id"], ident)
            else:
                put("unassigned", "Unassigned", ident)
        elif grouping == "priority":
            p = raw.get("priority")
            put(str(p), PRIORITY.get(p, str(p)), ident)
        elif grouping == "label":
            labelled = False
            for l in ((raw.get("labels") or {}).get("nodes")) or []:
                if isinstance(l, dict) and l.get("id"):
                    put(l["id"], l.get("name") or l["id"], ident)
                    labelled = True
            if not labelled:
                put("nolabel", "No label", ident)
        elif grouping == "project":
            p = raw.get("project") or {}
            if p.get("id"):
                put(p["id"], p.get("name") or p["id"], ident)
            else:
                put("noproject", "No project", ident)
    if grouping != "workflowState":
        # columnOrderBoard holds state ids for a view that was ever a state
        # board; under another grouping they would be empty columns.
        order = [k for k in order if k not in state_name]
    if grouping == "workflowState" and not order:
        order = [s.get("id") for s in states
                 if usable or s.get("type") != "canceled"]
    for k in appearance:
        if k not in order:
            order.append(k)
    listed = set()
    for k in order:
        if k in hidden:
            continue
        label_k, idents = keys.get(k, [state_name.get(k) or k, []])
        kind = state_type.get(k) if grouping == "workflowState" else None
        groups.append({"key": k, "label": label_k, "kind": kind, "issues": idents})
        listed.update(idents)
    issues = {i: v for i, v in issues.items() if i in listed}
elif bound and linear_status == "unavailable":
    by_status = {}
    for ident in sorted(issues):
        by_status.setdefault(issues[ident]["state"]["name"], []).append(ident)
    for name in by_status:
        groups.append({"key": name, "label": name, "kind": None, "issues": by_status[name]})

claimed = {}
unlisted_claims = {}
if bound:
    rows = []
    for line in open(E["SNAP_BINDINGS"]):
        parts = line.rstrip("\n").split("\x1f")
        if len(parts) != 5:
            continue
        rows.append(parts)
    for _f, ident, path, tab, eff in sorted(rows, key=lambda r: r[2]):
        if ident in issues:
            entry = {"worktree_path": path, "state": eff, "tab": None, "panes": []}
            if tab:
                entry["tab"] = {"id": tab, "label": tab_label.get(tab) if herdr_ok else None}
                entry["panes"] = panes_in(tab) if herdr_ok else []
                claimed[tab] = True
            issues[ident]["bindings"].append(entry)
        elif tab:
            unlisted_claims.setdefault(tab, eff)

unmapped = []
if bound and herdr_ok:
    for t in tabs:
        tid = t.get("tab_id")
        if t.get("workspace_id") != ws or not tid or tid in claimed:
            continue
        unmapped.append({"tab_id": tid, "label": t.get("label"),
                         "reason": unlisted_claims.get(tid, "no_binding"),
                         "panes": panes_in(tid)})

for v in issues.values():
    v.pop("_raw", None)

proj = {"id": None, "name": None, "team_key": None, "url": None}
if bound:
    proj["id"] = E["SNAP_PROJECT_ID"] or None
    if linear_status in ("ok", "truncated"):
        proj["name"] = project.get("name")
        proj["url"] = project.get("url")
        teams = (project.get("teams") or {}).get("nodes") or []
        first = teams[0] if teams else {}
        key = team.get("key") or first.get("key")
        if not key:
            for n in listing.get("nodes") or []:
                tm = n.get("team") or {}
                if tm.get("key") and (not first.get("id") or tm.get("id") == first.get("id")):
                    key = tm["key"]; break
        if not key:
            for n in listing.get("nodes") or []:
                if (n.get("team") or {}).get("key"):
                    key = n["team"]["key"]; break
        proj["team_key"] = key
    elif linear_status == "unavailable":
        names = {}
        for line in open(E["SNAP_CACHE"]):
            if "\t" not in line:
                continue
            try:
                c = json.loads(line.rstrip("\n").split("\t", 1)[1])
            except Exception:
                continue
            if c.get("project"):
                names[c["project"]] = names.get(c["project"], 0) + 1
        if names:
            proj["name"] = max(names, key=lambda k: (names[k], k))
elif record_status == "ok":
    proj["id"] = E["SNAP_PROJECT_ID"] or None

view_doc = {"status": view_status, "id": E["SNAP_VIEW_ID"] or None,
            "name": E["SNAP_VIEW_NAME"] or None, "layout": None}
if view is not None and view_status in ("ok", "archived", "unsupported_grouping"):
    lay = view.get("layout") or {}
    if view_status == "unsupported_grouping":
        view_doc["layout"] = {"grouping": lay.get("grouping"), "column_order": [], "hidden": []}
    else:
        view_doc["layout"] = {"grouping": lay.get("grouping"),
                              "column_order": list(lay.get("column_order") or []),
                              "hidden": list(lay.get("hidden") or [])}

doc = {
    "schema": 1,
    "workspace": {"id": ws, "label": label, "live": live},
    "mapping": {"status": "ok", "source": "default", "space": "project", "tab": "work", "pane": "session"},
    "record": {"status": record_status, "state": record_state,
               "project_id": (E["SNAP_PROJECT_ID"] or None) if record_status == "ok" else None},
    "project": proj,
    "view": view_doc,
    "linear": {"status": linear_status,
               "cache_age_seconds": max(cache_ages) if cache_ages else None,
               "truncated": linear_status == "truncated"},
    "herdr": {"status": "ok" if herdr_ok else "unavailable",
              "version": (snap.get("version") if herdr_ok else None) or None},
    "groups": groups,
    "issues": issues,
    "unmapped": unmapped,
}
print(json.dumps(deep_clean(doc), sort_keys=True, indent=2))
'
}

out="$(snapshot_main "$@")"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
fi
[ "$rc" -eq 0 ] && rc=1
exit "$rc"
