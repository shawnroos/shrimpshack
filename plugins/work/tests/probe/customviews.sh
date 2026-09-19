#!/usr/bin/env bash
# customviews.sh — capture the CustomView shapes the view functions in
# lib/linear.sh depend on, from the real api.linear.app.
#
# Run by hand, never by the suite. The read arms are the default and send
# nothing but queries. The create-and-delete arm is the ONE mutation this
# directory carries: it runs only with --mutate AND a terminal on stdin, and
# exits 64 otherwise, so no script, hook or agent can reach it by accident.
#
# THE CREDENTIAL NEVER REACHES argv. It goes to curl through `--config -` on
# stdin, as in linear-shape-probe.sh. Never `ps -f` / `pgrep -f` while this runs.
#
# Usage:  bash customviews.sh [--mutate] [project-id]
# The key comes from the Keychain (work-linear / linear-api-key) or from
# ~/.secrets (LINEAR_API_KEY=), and is never printed. Raw output carries real
# ids and names: redact before committing anything it prints.

set -u

MUTATE=0
PROJECT_ID=""
for a in "$@"; do
    case "$a" in
        --mutate) MUTATE=1 ;;
        *) PROJECT_ID="$a" ;;
    esac
done

SECRETS="${LINEAR_SHAPE_PROBE_SECRETS:-$HOME/.secrets}"
KEY="$(security find-generic-password -s work-linear -a linear-api-key -w 2>/dev/null || true)"
if [ -z "$KEY" ] && [ -r "$SECRETS" ]; then
    KEY="$(grep '^LINEAR_API_KEY=' "$SECRETS" | head -1 | cut -d= -f2- | tr -d "\"'")"
fi
if [ -z "$KEY" ]; then
    printf 'no credential in the Keychain or %s\n' "$SECRETS" >&2
    exit 1
fi

cfg() {
    printf 'header = "Authorization: %s"\nheader = "Content-Type: application/json"\nurl = "https://api.linear.app/graphql"\n' "$KEY"
}

q() {   # q <graphql-json-body>
    cfg | curl -s --config - -X POST --data "$1"
}

jbody() {   # jbody <query> [variables-json]
    python3 -c 'import sys,json;print(json.dumps({"query":sys.argv[1],"variables":json.loads(sys.argv[2] if len(sys.argv)>2 else "{}")}))' "$@"
}

show() { python3 -m json.tool 2>/dev/null || cat; }

TYPE_Q='query($n:String!){__type(name:$n){name kind fields{name type{kind name ofType{kind name ofType{kind name}}}} inputFields{name type{kind name ofType{kind name ofType{kind name}}}}}}'

for t in CustomView ViewPreferencesValues ViewPreferences ViewPreferencesPayload \
         CustomViewCreateInput ViewPreferencesCreateInput ViewPreferencesValuesInput \
         CustomViewPayload; do
    printf '=== TYPE %s ===\n' "$t"
    q "$(jbody "$TYPE_Q" "{\"n\":\"$t\"}")" | show
    printf '\n'
done

for e in ViewPreferencesType ViewType; do
    printf '=== ENUM %s ===\n' "$e"
    q "$(jbody 'query($n:String!){__type(name:$n){name enumValues{name}}}' "{\"n\":\"$e\"}")" | show
    printf '\n'
done

printf '=== MUTATION ARGS customViewCreate / viewPreferencesCreate / customViewDelete ===\n'
q "$(jbody 'query{__type(name:"Mutation"){fields{name args{name type{kind name ofType{kind name}}}}}}')" \
    | python3 -c '
import sys, json
fs = json.load(sys.stdin)["data"]["__type"]["fields"]
for f in fs:
    if f["name"] in ("customViewCreate", "viewPreferencesCreate", "customViewDelete", "viewPreferencesUpdate", "customViewUpdate"):
        print(json.dumps(f))
'
printf '\n'

printf '=== customViews(first:50) — Issue views only, with their preferences ===\n'
VIEWS="$(q "$(jbody 'query{customViews(first:50){nodes{id name modelName archivedAt filterData viewPreferencesValues{layout issueGrouping columnOrderBoard hiddenColumns}} pageInfo{hasNextPage endCursor}}}')")"
printf '%s' "$VIEWS" | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]["customViews"]
for v in d["nodes"]:
    if v["modelName"] != "Issue":
        continue
    print(json.dumps({k: v[k] for k in ("id", "name", "archivedAt", "filterData", "viewPreferencesValues")}))
print(json.dumps(d["pageInfo"]))
'
printf '\n'

FIRST_ID="$(printf '%s' "$VIEWS" | python3 -c '
import sys, json
n = [v for v in json.load(sys.stdin)["data"]["customViews"]["nodes"] if v["modelName"] == "Issue"]
print(n[0]["id"] if n else "")')"
FIRST_FILTER="$(printf '%s' "$VIEWS" | python3 -c '
import sys, json
n = [v for v in json.load(sys.stdin)["data"]["customViews"]["nodes"] if v["modelName"] == "Issue"]
print(json.dumps(n[0]["filterData"]) if n else "{}")')"

if [ -n "$FIRST_ID" ]; then
    printf '=== customView(id) with viewPreferencesValues ===\n'
    q "$(jbody 'query($id:String!){customView(id:$id){id name modelName archivedAt filterData viewPreferencesValues{layout issueGrouping columnOrderBoard hiddenColumns}}}' "{\"id\":\"$FIRST_ID\"}")" | show
    printf '\n'

    printf '=== issues(first:3, filter: <that view'"'"'s filterData, unchanged>) ===\n'
    q "$(jbody 'query($f:IssueFilter){issues(first:3,filter:$f){nodes{identifier state{name type}} pageInfo{hasNextPage endCursor}}}' "{\"f\":$FIRST_FILTER}")" | show
    printf '\n'
fi

printf '=== customView(id) on an unknown id ===\n'
q "$(jbody 'query($id:String!){customView(id:$id){id name}}' '{"id":"00000000-0000-4000-8000-000000000000"}')" | show
printf '\n'

if [ "$MUTATE" -ne 1 ]; then
    printf 'Read arms done. Nothing above was written to Linear.\n'
    exit 0
fi
if [ ! -t 0 ]; then
    printf 'the create arm needs a terminal on stdin; refusing\n' >&2
    exit 64
fi
if [ -z "$PROJECT_ID" ]; then
    printf 'the create arm needs a project id argument\n' >&2
    exit 64
fi

printf '=== customViewCreate (throwaway, deleted below) ===\n'
CREATED="$(q "$(jbody 'mutation($i:CustomViewCreateInput!){customViewCreate(input:$i){success customView{id name modelName filterData}}}' \
    "{\"i\":{\"name\":\"probe-throwaway\",\"shared\":false,\"filterData\":{\"project\":{\"id\":{\"in\":[\"$PROJECT_ID\"]}}}}}")")"
printf '%s' "$CREATED" | show
VIEW_ID="$(printf '%s' "$CREATED" | python3 -c 'import sys,json;print((json.load(sys.stdin).get("data") or {}).get("customViewCreate",{}).get("customView",{}).get("id",""))' 2>/dev/null)"
if [ -n "$VIEW_ID" ]; then
    printf '\n=== viewPreferencesCreate ===\n'
    q "$(jbody 'mutation($i:ViewPreferencesCreateInput!){viewPreferencesCreate(input:$i){success viewPreferences{id type preferences{layout issueGrouping}}}}' \
        "{\"i\":{\"type\":\"user\",\"viewType\":\"customView\",\"customViewId\":\"$VIEW_ID\",\"preferences\":{\"layout\":\"board\",\"issueGrouping\":\"workflowState\"}}}")" | show
    printf '\n=== customView(id) after prefs ===\n'
    q "$(jbody 'query($id:String!){customView(id:$id){id name filterData viewPreferencesValues{layout issueGrouping columnOrderBoard hiddenColumns}}}' "{\"id\":\"$VIEW_ID\"}")" | show
    printf '\n=== customViewDelete ===\n'
    q "$(jbody 'mutation($id:String!){customViewDelete(id:$id){success}}' "{\"id\":\"$VIEW_ID\"}")" | show
fi
printf '\nThe throwaway view was created and deleted. Nothing else was written.\n'
