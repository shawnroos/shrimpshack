#!/usr/bin/env bash
# fake-codex.sh — stand-in for the `codex` binary in spawn tests (U6).
#
# WHY A FIXTURE AT ALL. Codex is NOT installed on the machine this path was
# built on, so every Codex assertion in setup-wiring.bats is fixture-proven.
# That is a stated gap (KTD20), not a hidden one: setup's own output carries it,
# and this header is the second place it is written down.
#
# WHAT IT HAS TO BE FAITHFUL ABOUT — the one behaviour the whole KTD20 decision
# rests on:
#
#   `codex doctor --json` has NO config-only mode. Its process exit is
#   CONTAMINATED by checks that have nothing to do with the config — network
#   reachability is the obvious one — so a caller that branches on `$?` reports
#   a perfectly valid config as broken every time the machine is offline or the
#   gateway is down. The status of the `config.load` check inside the JSON is
#   the only thing that answers "is this config loadable?".
#
#   Mode `net_fail` below is that exact shape: config.load PASSES and the
#   process still exits non-zero. It exists so the suite can prove setup reads
#   the check rather than the exit code — an assertion that is worth nothing
#   without a fixture that can produce the two disagreeing signals.
#
# There is no `codex config` subcommand to imitate; that absence is why this
# fixture only implements `doctor`.
#
# The JSON SHAPE here is this plugin's contract with itself: one `checks` array
# of {name, status, detail}. Setup parses exactly this and nothing else — a
# parser accepting two shapes when only one is ever exercised is a second code
# path with no test behind it.
#
# Environment:
#   FAKE_CODEX_MODE     ok | invalid | net_fail | garbage | nocheck | hang
#       ok        config.load passes, process exits 0
#       invalid   config.load FAILS with a distinctive detail string, exit 1
#       net_fail  config.load PASSES, a network check fails, process exits 3
#       garbage   stdout is not JSON at all, process exits 0
#       nocheck   valid JSON, but no config.load check in it, process exits 0
#       hang      sleeps past any sane budget (bound proof)
#   FAKE_CODEX_RECORD   file every invocation's argv is APPENDED to (optional)
#
# NO REAL CREDENTIAL IS USED OR NEEDED here or in the suite that drives it.
set -uo pipefail

MODE="${FAKE_CODEX_MODE:-ok}"

if [ -n "${FAKE_CODEX_RECORD:-}" ]; then
    printf '%s\n' "$*" >> "$FAKE_CODEX_RECORD"
fi

# The detail string the `invalid` mode reports. AE10 requires setup to carry the
# LOADER's own message rather than a paraphrase, so this is deliberately
# distinctive: a suite asserting on it cannot be satisfied by setup's own prose.
INVALID_DETAIL='failed to parse ~/.codex/config.toml: expected a value at line 12 column 9'

case "${1:-}" in
    doctor) ;;
    *)
        printf 'fake-codex: unsupported subcommand %s\n' "${1:-<none>}" >&2
        exit 2
        ;;
esac

case "$MODE" in
    ok)
        printf '%s\n' '{"version":"0.0.0-fake","checks":[{"name":"config.load","status":"ok","detail":"loaded 1 provider, 3 profiles"},{"name":"network.reachable","status":"ok","detail":"reached api endpoint"}]}'
        exit 0
        ;;
    invalid)
        printf '{"version":"0.0.0-fake","checks":[{"name":"config.load","status":"error","detail":"%s"}]}\n' "$INVALID_DETAIL"
        exit 1
        ;;
    net_fail)
        # The whole reason this fixture exists: the config is FINE and the
        # process still exits non-zero.
        printf '%s\n' '{"version":"0.0.0-fake","checks":[{"name":"config.load","status":"ok","detail":"loaded 1 provider, 3 profiles"},{"name":"network.reachable","status":"error","detail":"dns lookup failed for api.openai.com"}]}'
        exit 3
        ;;
    garbage)
        printf '%s\n' 'codex doctor: running checks...'
        exit 0
        ;;
    nocheck)
        printf '%s\n' '{"version":"0.0.0-fake","checks":[{"name":"network.reachable","status":"ok","detail":"reached api endpoint"}]}'
        exit 0
        ;;
    hang)
        sleep 120
        exit 0
        ;;
    *)
        printf 'fake-codex: unknown FAKE_CODEX_MODE %s\n' "$MODE" >&2
        exit 2
        ;;
esac
