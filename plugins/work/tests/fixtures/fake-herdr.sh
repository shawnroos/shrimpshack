#!/usr/bin/env bash
# fake-herdr.sh — stand-in for the herdr binary in the work plugin's tests.
#
# lib/herdr-read.sh is the plugin's only reader of herdr. Pointing it here
# through HERDR_BIN keeps the whole accessor path off the user's LIVE server:
# this is their real terminal, and a suite that talked to it would either
# disturb running work or answer differently on every machine.
#
# WHY IT RECORDS ARGV
# U11's hard boundary is that the accessor never invokes a mutating verb. A
# claim like that is worth exactly what asserts it, so every invocation is
# appended to $FAKE_HERDR_RECORD_DIR/argv and the suite asserts no mutating
# verb ever appears. Mutating verbs additionally exit 99 without acting, so a
# regression fails loudly rather than passing over a recorded-but-ignored call.
#
# FIDELITY THAT MATTERS (verified against herdr 0.8.2 this session):
#   * `status server` prints FIVE lines, `status: running` first, then version,
#     protocol, compatible, socket. A reader that assumed one line would pass
#     here and fail live.
#   * a stopped server prints `status: not running` — the exact substring trap
#     `grep -qi running` falls into.
#   * `api snapshot` answers one JSON object shaped
#     .result.snapshot.{panes,tabs,workspaces,agents,focused_*}; pane objects
#     carry pane_id/tab_id/workspace_id.
#
# Environment:
#   FAKE_HERDR_RECORD_DIR  where the argv record lands
#                          (default: $TMPDIR/fake-herdr-record)
#   FAKE_HERDR_MODE        running | not_running | running_then_flood | dead
#   FAKE_HERDR_ALLOW_MUTATION  1 to permit creation verbs (U10 only)
#   FAKE_HERDR_SLOW_PANE   probes a new pane stays unregistered for
#   FAKE_HERDR_WORKSPACES  the spaces `workspace list` reports, as
#                          `id=label,id=label` (default: wA=Plugins). Created
#                          tabs and panes are remembered in the record dir, so
#                          `tab get`, `pane get` and the snapshot answer for
#                          them the way the live server does
#     running            the five faithful lines
#     not_running        `status: not running`, exit 0 (herdr does not fail)
#     running_then_flood `status: running` mid-output, then far more than one
#                        pipe buffer of trailing text. The volume is the point:
#                        under 64KB a reader that closes the pipe early can
#                        drain everything before the writer notices, so the
#                        SIGPIPE defect passes by luck. Over it, the writer
#                        blocks and takes EPIPE deterministically.
#     dead               nothing on stdout, a diagnostic on stderr, exit 1

set -uo pipefail

MODE="${FAKE_HERDR_MODE:-running}"
REC_DIR="${FAKE_HERDR_RECORD_DIR:-${TMPDIR:-/tmp}/fake-herdr-record}"

mkdir -p "$REC_DIR" 2>/dev/null || true
printf '%s\n' "$*" >>"$REC_DIR/argv" 2>/dev/null || true

# The one list. herdr-read.bats reads it back from here rather than carrying a
# second copy: two hand-maintained lists guarding one boundary drift apart, and
# the drift silently empties the assertion that the accessor never mutates.
FAKE_HERDR_MUTATING_VERBS="create split move swap close rename focus run send-keys resize zoom report-metadata report-agent"

if [ "${1:-}" = "--list-mutating-verbs" ]; then
    printf '%s\n' "$FAKE_HERDR_MUTATING_VERBS"
    exit 0
fi

# The value after a flag, or nothing.
_flag() {
    local want="$1"; shift
    while [ "$#" -gt 0 ]; do
        [ "$1" = "$want" ] && { printf '%s' "${2:-}"; return 0; }
        shift
    done
}

# `pane split [PANE_ID]` or `--pane <id>`. Flags that take a value are skipped
# with their value, so a --cwd path is never read as the target.
_split_target() {
    shift 2
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pane) printf '%s' "${2:-}"; return 0 ;;
            --direction|--ratio|--cwd|--env|--right-click) shift ;;
            --*) ;;
            *) printf '%s' "$1"; return 0 ;;
        esac
        shift
    done
}

# `<tab> <workspace>` for a pane this fixture made or the canned snapshot holds.
_pane_where() {
    case "$1" in
        wA:p1|wA:p2) printf 'wA:t1 wA'; return 0 ;;
        wA:p9) printf 'wA:t2 wA'; return 0 ;;
    esac
    [ -f "$REC_DIR/panes" ] || return 1
    awk -v p="$1" '$1 == p { print $2 " " $3; found=1; exit } END { exit !found }' "$REC_DIR/panes"
}

# U11's accessor must never reach a mutating verb, and the refusal is how that
# is asserted. U10 builds layout and legitimately needs them, so it opts in --
# the refusal stays the default so a read path cannot quietly acquire a write.
for _verb in $FAKE_HERDR_MUTATING_VERBS; do
    if [ "${1:-}" = "$_verb" ] || [ "${2:-}" = "$_verb" ]; then
        if [ "${FAKE_HERDR_ALLOW_MUTATION:-0}" != 1 ]; then
            echo "fake-herdr: MUTATING VERB '$_verb' — the read-only accessor must never call this" >&2
            exit 99
        fi
        _mutating="$_verb"
    fi
done

# Creation responses, shaped as herdr 0.8.2 actually answers: `tab create`
# returns .result.tab and .result.root_pane; `pane split` returns .result.pane.
# A caller that assumed a bare id, or that the pane exists the moment create
# returns, would pass against a looser fixture and fail live.
if [ "${FAKE_HERDR_ALLOW_MUTATION:-0}" = 1 ]; then
    _n=0
    _seq="$REC_DIR/seq"
    mkdir -p "$REC_DIR" 2>/dev/null
    [ -f "$_seq" ] && _n="$(cat "$_seq" 2>/dev/null || echo 0)"
    case "${1:-}:${2:-}" in
        workspace:create)
            _n=$(( _n + 1 )); printf '%s' "$_n" > "$_seq"
            printf '{"result":{"workspace":{"workspace_id":"w%s","label":"ws%s"},"tab":{"tab_id":"w%s:t1"},"root_pane":{"pane_id":"w%s:p1","tab_id":"w%s:t1","workspace_id":"w%s"}}}\n' \
                "$_n" "$_n" "$_n" "$_n" "$_n" "$_n"
            exit 0
            ;;
        tab:create)
            _n=$(( _n + 1 )); printf '%s' "$_n" > "$_seq"
            # The tab is made in the space it was asked for. Answering w1
            # whatever was asked let a caller that never passed --workspace
            # pass here and land in the focused space live.
            _ws="$(_flag --workspace "$@")"; _ws="${_ws:-w1}"
            _tab="$_ws:t$_n"; _root="$_ws:p0$_n"
            printf '%s %s\n' "$_tab" "$_ws" >> "$REC_DIR/tabs"
            printf '%s %s %s\n' "$_root" "$_tab" "$_ws" >> "$REC_DIR/panes"
            printf '%s' "${FAKE_HERDR_SLOW_PANE:-0}" > "$REC_DIR/countdown.$_root"
            printf '{"result":{"tab":{"tab_id":"%s","label":"tab%s","workspace_id":"%s"},"root_pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"}}}\n' \
                "$_tab" "$_n" "$_ws" "$_root" "$_tab" "$_ws"
            exit 0
            ;;
        pane:split)
            _n=$(( _n + 1 )); printf '%s' "$_n" > "$_seq"
            # The new pane lands in the TARGET's tab, as herdr does. With no
            # target herdr splits the focused pane, modelled as w1:t1.
            _target="$(_split_target "$@")"
            _tab="w1:t1"; _ws="w1"
            if [ -n "$_target" ]; then
                _where="$(_pane_where "$_target")" || {
                    echo "fake-herdr: no such pane '$_target'" >&2; exit 1; }
                _tab="${_where% *}"; _ws="${_where#* }"
            fi
            # A created pane becomes known to `pane get` only after
            # FAKE_HERDR_SLOW_PANE further probes. Answering immediately would
            # let a caller that assumes registration-on-return pass here and
            # race against the real server, which is the defect this models.
            printf '%s %s %s\n' "$_ws:p$_n" "$_tab" "$_ws" >> "$REC_DIR/panes"
            printf '%s' "${FAKE_HERDR_SLOW_PANE:-0}" > "$REC_DIR/countdown.$_ws:p$_n"
            printf '{"result":{"pane":{"pane_id":"%s:p%s","tab_id":"%s","workspace_id":"%s"}}}\n' "$_ws" "$_n" "$_tab" "$_ws"
            exit 0
            ;;
    esac
fi

# Created panes, checked before the canned pane set. The countdown is decremented
# on each probe; the pane is reported as existing only once it reaches zero.
if [ "${1:-}" = "pane" ] && [ "${2:-}" = "get" ] && [ -n "${3:-}" ]; then
    _cd_file="$REC_DIR/countdown.${3}"
    if [ -f "$_cd_file" ]; then
        _cd="$(cat "$_cd_file" 2>/dev/null || echo 0)"
        if [ "${_cd:-0}" -le 0 ] 2>/dev/null; then
            _where="$(_pane_where "$3")" || _where="w1:t1 w1"
            printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"}}}\n' \
                "$3" "${_where% *}" "${_where#* }"
            exit 0
        fi
        printf '%s' "$(( _cd - 1 ))" > "$_cd_file"
        echo "fake-herdr: pane '$3' not registered yet" >&2
        exit 1
    fi
fi

emit_status() {
    case "$MODE" in
        not_running)
            printf 'status: not running\n'
            ;;
        dead)
            echo "fake-herdr: could not connect to the herdr server" >&2
            return 1
            ;;
        running_then_flood)
            printf 'client: connected\n'
            printf 'status: running\n'
            printf 'version: 0.8.2\n'
            # ~200KB of trailing output; see the MODE notes above.
            local i
            for i in $(seq 1 2000); do
                # `|| exit 101` is fidelity, not defence: a shell that IGNORES
                # SIGPIPE leaves bash's printf merely failing, so the flood
                # would finish at exit 0 and the SIGPIPE defect would pass by
                # luck. Real herdr dies either way — 141 under the default
                # disposition, 101 (Rust "failed printing to stdout") when the
                # signal is ignored. Reproduce the second explicitly.
                printf 'trailing line %04d %s\n' "$i" \
                    'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' \
                    2>/dev/null || exit 101
            done
            printf 'trailing: end\n'
            ;;
        *)
            printf 'status: running\n'
            printf 'version: 0.8.2\n'
            printf 'protocol: 20\n'
            printf 'compatible: yes\n'
            printf 'socket: /tmp/fake-herdr.sock\n'
            ;;
    esac
}

emit_snapshot() {
    [ "$MODE" = dead ] && { echo "fake-herdr: no server" >&2; return 1; }
    canned_snapshot | REC_DIR="$REC_DIR" python3 -c '
import sys, json, os
d = json.load(sys.stdin)
snap = d["result"]["snapshot"]
rec = os.environ["REC_DIR"]
def rows(name):
    try:
        return [l.split() for l in open(os.path.join(rec, name)) if l.strip()]
    except OSError:
        return []
for tab, ws in rows("tabs"):
    snap["tabs"].append({"tab_id": tab, "workspace_id": ws, "label": tab, "pane_count": 1})
for pane, tab, ws in rows("panes"):
    snap["panes"].append({"pane_id": pane, "tab_id": tab, "workspace_id": ws, "agent": None, "cwd": "/"})
print(json.dumps(d))
'
}

canned_snapshot() {
    cat <<'JSON'
{"id":"cli:api:snapshot","result":{"snapshot":{
"focused_pane_id":"wA:p1","focused_tab_id":"wA:t1","focused_workspace_id":"wA",
"protocol":20,"version":"0.8.2",
"workspaces":[{"workspace_id":"wA","label":"Plugins","active_tab_id":"wA:t1","tab_count":2}],
"tabs":[
 {"tab_id":"wA:t1","workspace_id":"wA","label":"Plugin PM","pane_count":2},
 {"tab_id":"wA:t2","workspace_id":"wA","label":"Elsewhere","pane_count":1}],
"panes":[
 {"pane_id":"wA:p1","tab_id":"wA:t1","workspace_id":"wA","agent":"claude","cwd":"/tmp/one"},
 {"pane_id":"wA:p2","tab_id":"wA:t1","workspace_id":"wA","agent":"claude","cwd":"/tmp/two"},
 {"pane_id":"wA:p9","tab_id":"wA:t2","workspace_id":"wA","agent":null,"cwd":"/tmp/nine"}],
"agents":[{"pane_id":"wA:p1","tab_id":"wA:t1","workspace_id":"wA","agent":"claude","agent_status":"idle"}]
}}}
JSON
}

case "${1:-}" in
    status)
        case "${2:-}" in
            server) emit_status ;;
            *) echo "fake-herdr: unsupported status subcommand '${2:-}'" >&2; exit 2 ;;
        esac
        ;;
    pane)
        case "${2:-}" in
            # Read-only. Models herdr's real behaviour after a pane move: the
            # OLD id still resolves for the moved process, and the response
            # carries the pane's CURRENT id, which is what api snapshot reports.
            get)
                [ "$MODE" = dead ] && { echo "fake-herdr: no server" >&2; exit 1; }
                _req="${3:-}"
                if [ -n "${FAKE_HERDR_ALIAS_OF:-}" ] && [ "$_req" = "$FAKE_HERDR_ALIAS_OF" ]; then
                    _req="${FAKE_HERDR_ALIAS_TO:-$_req}"
                fi
                case "$_req" in
                    wA:p1) printf '{"result":{"pane":{"pane_id":"wA:p1","tab_id":"wA:t1","workspace_id":"wA"}}}\n' ;;
                    wA:p2) printf '{"result":{"pane":{"pane_id":"wA:p2","tab_id":"wA:t1","workspace_id":"wA"}}}\n' ;;
                    wA:p9) printf '{"result":{"pane":{"pane_id":"wA:p9","tab_id":"wA:t2","workspace_id":"wA"}}}\n' ;;
                    *) echo "fake-herdr: no such pane '$_req'" >&2; exit 1 ;;
                esac
                ;;
            *) echo "fake-herdr: unsupported pane subcommand '${2:-}'" >&2; exit 2 ;;
        esac
        ;;
    tab)
        case "${2:-}" in
            # herdr answers a missing tab with an error object AND exit 1.
            get)
                [ "$MODE" = dead ] && { echo "fake-herdr: no server" >&2; exit 1; }
                _ws=""
                case "${3:-}" in
                    wA:t1|wA:t2) _ws="wA" ;;
                    *) [ -f "$REC_DIR/tabs" ] && _ws="$(awk -v t="${3:-}" '$1 == t { print $2; exit }' "$REC_DIR/tabs")" ;;
                esac
                if [ -z "$_ws" ]; then
                    printf '{"error":{"code":"tab_not_found","message":"tab %s not found"},"id":"cli:tab:get"}\n' "${3:-}"
                    exit 1
                fi
                printf '{"id":"cli:tab:get","result":{"tab":{"tab_id":"%s","workspace_id":"%s"},"type":"tab_info"}}\n' "${3:-}" "$_ws"
                ;;
            *) echo "fake-herdr: unsupported tab subcommand '${2:-}'" >&2; exit 2 ;;
        esac
        ;;
    workspace)
        case "${2:-}" in
            list)
                [ "$MODE" = dead ] && { echo "fake-herdr: no server" >&2; exit 1; }
                FAKE_HERDR_WORKSPACES="${FAKE_HERDR_WORKSPACES-wA=Plugins}" python3 -c '
import json, os
out = []
for item in os.environ["FAKE_HERDR_WORKSPACES"].split(","):
    if "=" in item:
        wid, label = item.split("=", 1)
        out.append({"workspace_id": wid, "label": label})
print(json.dumps({"id": "cli:workspace:list", "result": {"type": "workspace_list", "workspaces": out}}))
'
                ;;
            *) echo "fake-herdr: unsupported workspace subcommand '${2:-}'" >&2; exit 2 ;;
        esac
        ;;
    api)
        case "${2:-}" in
            snapshot) emit_snapshot ;;
            *) echo "fake-herdr: unsupported api subcommand '${2:-}'" >&2; exit 2 ;;
        esac
        ;;
    *)
        echo "fake-herdr: unsupported command '${1:-}'" >&2
        exit 2
        ;;
esac
