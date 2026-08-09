#!/usr/bin/env bash
# fake-gateway-bin.sh — stand-in for the BUILT gateway binary at exec time (U3).
#
# WHY THIS EXISTS, AND WHY IT IS NOT fake-gateway.py
# -------------------------------------------------
# fake-gateway.py is the SERVER the plugin probes; it picks its own ephemeral
# port, so it cannot be the thing `start` launches. This file is what
# spawnctl.sh resolves as the install's binary and spawns: copied to
# <install>/target/release/gateway, handed --config, and left to serve.
#
# It exists because U3's whole claim is about what the child process can SEE at
# exec:
#   * the OpenRouter key must NOT be in its exec-time environment (R7) — a
#     variable in the environment at exec is readable by any same-user process
#     via `ps -Eww`, which is the exposure the delivery file exists to avoid;
#   * the mode-0600 delivery file MUST be present, in the CWD, at exec — that
#     is the only window in which the real gateway reads it;
#   * the key the gateway ends up holding must be the DELIVERED one, not an
#     inherited export (AE9).
# None of those are observable from outside the child, so the child writes them
# down. The records hold NAMES, MODES and a SHA of the effective key — the
# fixture never has to write a secret value to make the assertion, except for
# the exec-time environment dump, which is the artifact under test (a canary
# appearing there IS the defect).
#
# DOTENV FIDELITY (upstream src/main.rs:26-45, verified against v0.1.1)
# --------------------------------------------------------------------
# The real gateway loads ./.env.local then ./.env relative to its CWD and sets
# only variables that are currently UNSET, via runtime set_var (invisible to
# `ps`). Process environment therefore WINS over the file. This fixture
# reproduces exactly that precedence — smoothing it over would make AE9
# vacuous, because the whole point of clearing the inherited key is that an
# inherited value would otherwise suppress the delivered one.
#
# TOKEN FIDELITY (upstream src/main.rs:54-56)
# -------------------------------------------
# A GATEWAY_TOKEN environment variable is MERGED onto the auth token list
# rather than substituted, so a literal token in gateway.yaml stays valid.
# Both are accepted here, for the same reason.
#
# SHAPE: bash records, then runs the HTTP server as a python CHILD and waits.
# It deliberately does not `exec` python: spawnctl.sh's pid_is_gateway matches
# the recorded binary path as a whole argv element, and an exec would replace
# this script's argv with python's, so `stop` would stop recognizing the
# process it legitimately owns.
#
# Environment:
#   FAKE_GATEWAY_RECORD_DIR   where records land (default $TMPDIR/fake-gw-record)
#   FAKE_GATEWAY_FAIL         non-empty: record, then exit 1 without serving —
#                             the failed-start path, which must still leave no
#                             delivery file behind

set -uo pipefail

REC="${FAKE_GATEWAY_RECORD_DIR:-${TMPDIR:-/tmp}/fake-gw-record}"
mkdir -p "$REC"

# --- 1. the exec-time environment ------------------------------------------
# Written FIRST, before this script assigns anything of its own, so what lands
# here is what the parent handed us at exec — the same thing `ps -Eww` shows.
{
    printf -- '--- exec %s ---\n' "$$"
    env
} >> "$REC/env"

printf 'exec %s %s\n' "$$" "$*" >> "$REC/execs"

# --- 2. the delivery file, as it exists AT EXEC ----------------------------
# CWD-relative, because that is how the gateway finds it and therefore the only
# location that proves the start path put it somewhere useful.
DELIVERY="$PWD/.env.local"
{
    printf -- '--- exec %s ---\n' "$$"
    printf 'cwd=%s\n' "$PWD"
    if [ -f "$DELIVERY" ]; then
        printf 'delivery_present=yes\n'
        # macOS first, GNU second. A missing mode is reported as such rather
        # than as a passing value.
        mode="$(stat -f '%Lp' "$DELIVERY" 2>/dev/null || stat -c '%a' "$DELIVERY" 2>/dev/null)"
        printf 'delivery_mode=%s\n' "${mode:-unknown}"
        # NAMES only. The values are the secrets under test and never enter a
        # record on any path.
        printf 'delivery_vars=%s\n' \
            "$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$DELIVERY" | tr '\n' ',')"
        printf 'delivery_lines=%s\n' "$(wc -l < "$DELIVERY" | tr -d ' ')"
    else
        printf 'delivery_present=no\n'
    fi
} >> "$REC/delivery"

# --- 3. dotenv resolution, with the real precedence ------------------------
dotenv_get() {   # <name> — the file's value, or empty
    [ -f "$DELIVERY" ] || return 0
    sed -n "s/^$1=//p" "$DELIVERY" | head -1
}

OR_SOURCE="unset"
OR_VALUE=""
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    # Process env wins — exactly the upstream behaviour, and exactly why the
    # start path has to clear an inherited export rather than warn about it.
    OR_SOURCE="env"
    OR_VALUE="$OPENROUTER_API_KEY"
else
    OR_VALUE="$(dotenv_get OPENROUTER_API_KEY)"
    [ -n "$OR_VALUE" ] && OR_SOURCE="file"
fi

TOK_SOURCE="unset"
TOK_VALUE=""
if [ -n "${GATEWAY_TOKEN:-}" ]; then
    TOK_SOURCE="env"
    TOK_VALUE="$GATEWAY_TOKEN"
else
    TOK_VALUE="$(dotenv_get GATEWAY_TOKEN)"
    [ -n "$TOK_VALUE" ] && TOK_SOURCE="file"
fi

# A SHA, never the value: it lets a test assert "the delivered value is what
# the gateway read" without a secret landing in a record file.
sha_of() { printf '%s' "$1" | shasum | cut -d' ' -f1; }
{
    printf -- '--- exec %s ---\n' "$$"
    printf 'openrouter_source=%s\n' "$OR_SOURCE"
    printf 'openrouter_sha=%s\n' "$(sha_of "$OR_VALUE")"
    printf 'gateway_token_source=%s\n' "$TOK_SOURCE"
    printf 'gateway_token_sha=%s\n' "$(sha_of "$TOK_VALUE")"
} >> "$REC/effective"

if [ -n "${FAKE_GATEWAY_FAIL:-}" ]; then
    printf 'fake-gateway-bin: FAKE_GATEWAY_FAIL set, refusing to serve\n' >&2
    exit 1
fi

# --- 4. serve, like fake-gateway.py ----------------------------------------
CFG=""
prev=""
for a in "$@"; do
    [ "$prev" = "--config" ] && CFG="$a"
    prev="$a"
done
if [ ! -f "$CFG" ]; then
    printf 'fake-gateway-bin: no readable --config\n' >&2
    exit 1
fi

# The config's own token, merged with the delivered one (upstream merges rather
# than substitutes), so a config that carries no token at all still authenticates
# through GATEWAY_TOKEN alone — the case R9 is about.
# [[:blank:]], never [ \t]: BSD sed reads `\t` inside a bracket expression as
# the literal characters backslash and t, so `[ \t]*` after the colon happily
# ate the FIRST LETTER of the token — a fixture that silently 401s every probe.
# (Observed: `token: tok-ctl-123` extracted as `ok-ctl-123`.)
CFG_TOKEN="$(sed -n 's/^[[:blank:]]*token:[[:blank:]]*//p' "$CFG" | head -1 | sed 's/[[:blank:]]*#.*$//' | tr -d '"'"'")"

printf 'fake gateway binary serving\n'

# Tokens travel to the child in the ENVIRONMENT, not in argv: this fixture
# stands in for a binary whose entire test is about what argv and the process
# table expose, and a fixture that put a token in its own child's argv would be
# a poor example of the thing it is asserting.
# The config path is passed in ARGV as well as the environment, and it is not
# decoration: the suite's teardown reaps leftovers with `pgrep -f "$WORK"`, and
# a child whose argv was bare `python3 -` matched nothing, survived the test,
# and kept bats' fd 3 open — which makes `bats` itself hang after the last test
# reports. fd 3 is closed here for the same reason, belt and braces.
GW_STUB_TOKENS="$CFG_TOKEN
$TOK_VALUE" \
python3 - "$CFG" 3>&- <<'PY' &
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

text = open(sys.argv[1], encoding="utf-8").read()
PORT = int(re.search(r'bind:\s*"?[^"\s:]+:(\d+)', text).group(1))
ALIASES = re.findall(r"^  ([A-Za-z0-9._-]+):\s*$", text, re.M)
TOKENS = [t for t in os.environ.get("GW_STUB_TOKENS", "").split("\n") if t]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self._send(200, {"status": "ok"})
            return
        if path == "/anthropic/v1/models":
            presented = self.headers.get("x-api-key") or ""
            if not presented:
                auth = self.headers.get("authorization") or ""
                if auth.lower().startswith("bearer "):
                    presented = auth[7:]
            # An EMPTY accepted-token list would make every request pass, which
            # is the open proxy R9 forbids — so an empty list rejects instead.
            if not TOKENS or presented not in TOKENS:
                self._send(401, {"type": "error",
                                 "error": {"type": "authentication_error",
                                           "message": "invalid x-api-key"}})
                return
            self._send(200, {"data": [{"type": "model", "id": a, "display_name": a}
                                      for a in ALIASES], "has_more": False})
            return
        self._send(404, {"type": "error",
                         "error": {"type": "not_found_error", "message": "no route"}})


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
child=$!
# The server is a child rather than an exec (see SHAPE above), so this script
# has to pass a stop along to it — otherwise `stop` reports success while the
# port stays held, which is the wrong-success class this plugin refuses.
trap 'kill "$child" 2>/dev/null; exit 143' TERM
trap 'kill "$child" 2>/dev/null; exit 130' INT
wait "$child"
