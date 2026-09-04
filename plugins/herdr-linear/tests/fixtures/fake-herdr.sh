#!/usr/bin/env bash
# fake-herdr.sh — stand-in for the herdr binary in herdr-linear tests.
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

for _verb in $FAKE_HERDR_MUTATING_VERBS; do
    if [ "${1:-}" = "$_verb" ] || [ "${2:-}" = "$_verb" ]; then
        echo "fake-herdr: MUTATING VERB '$_verb' — the read-only accessor must never call this" >&2
        exit 99
    fi
done

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
