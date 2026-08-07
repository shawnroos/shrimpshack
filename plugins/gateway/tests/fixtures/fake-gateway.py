#!/usr/bin/env python3
"""fake-gateway.py — stand-in for the local Superagent Gateway in gateway plugin tests.

The real gateway and OpenRouter are out of the test path by decision (plan,
Verification Contract), so every automated test points the plugin's base URL at
this server instead.

WHY THIS FIXTURE REQUIRES AUTH
------------------------------
The real gateway guards /anthropic/* behind check_auth and answers an
unauthenticated probe with 401. KTD3 makes liveness a token-bearing
GET /anthropic/v1/models probe precisely because of that, and KTD2 gives the
rejected-token case its own exit code (7) so `ensure` never mistakes an
auth failure for "down" and races a start against a running gateway.

A fixture that accepted bare probes would let all of that regress green: the
plugin could stop sending the token entirely and every test would still pass.
So the auth check runs BEFORE scenario dispatch — a server scripted to return
502, 429 or a slow body still answers an unauthenticated request with 401.

USAGE
-----
    python3 fake-gateway.py --token TOK --aliases a,b [--scenario NAME] ...

It binds 127.0.0.1 on an ephemeral port and prints exactly one line,
`PORT=<n>`, flushed, before serving — so a test can capture the port without
guessing one and without racing a fixed-port collision. Stdlib only.

ROUTES
    GET  /health                  open (no auth), always 200 while serving
    GET  /anthropic/v1/models     auth; the configured alias list
    POST /anthropic/v1/messages   auth; behaviour per --scenario

SCENARIOS
    down             bind, print the port, close it, exit 0 — the port is
                     guaranteed to refuse connections (a "gateway is down"
                     endpoint that cannot be accidentally answered by some
                     other process that grabbed a hardcoded port)
    healthy          200 with a canned assistant message (default)
    upstream-5xx     502 api_error
    throttle-429     429 rate_limit_error with Retry-After
    context-length   400 invalid_request_error, "prompt is too long"
    slow             sleeps --delay seconds, then answers like healthy

"unknown alias" is not a scenario: it falls out of --aliases. A model absent
from that list gets 404 not_found_error, exactly as an unconfigured alias does
on the real gateway. "wrong token" is likewise client-driven — the server
always rejects anything that is not --token.
"""

import argparse
import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CFG = {}


def _err(kind, message):
    return {"type": "error", "error": {"type": kind, "message": message}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Keep the fixture's own chatter off stderr; a noisy fixture buries the
    # assertion output that a failing test is trying to show.
    def log_message(self, fmt, *args):  # noqa: A003
        if CFG.get("verbose"):
            sys.stderr.write("fake-gateway: " + (fmt % args) + "\n")

    def _send(self, code, payload, extra_headers=None):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        """Mirror the gateway's check_auth. Returns True, or answers 401."""
        presented = self.headers.get("x-api-key") or ""
        if not presented:
            auth = self.headers.get("authorization") or ""
            if auth.lower().startswith("bearer "):
                presented = auth[7:]
        if presented == CFG["token"]:
            return True
        self._send(401, _err("authentication_error", "invalid x-api-key"))
        return False

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self._send(200, {"status": "ok"})
            return
        if path == "/anthropic/v1/models":
            if not self._authed():
                return
            self._send(
                200,
                {
                    "data": [
                        {"type": "model", "id": a, "display_name": a}
                        for a in CFG["aliases"]
                    ],
                    "has_more": False,
                },
            )
            return
        self._send(404, _err("not_found_error", "no route " + path))

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path != "/anthropic/v1/messages":
            self._send(404, _err("not_found_error", "no route " + path))
            return
        if not self._authed():
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            req = json.loads(raw.decode("utf-8")) if raw else {}
        except (ValueError, UnicodeDecodeError):
            self._send(400, _err("invalid_request_error", "body is not JSON"))
            return

        model = req.get("model") or ""
        if model not in CFG["aliases"]:
            self._send(404, _err("not_found_error", "model not found: " + str(model)))
            return

        # Record the request so a test can assert on what the plugin actually
        # sent (headers included) rather than only on what came back.
        if CFG.get("request_log"):
            with open(CFG["request_log"], "a", encoding="utf-8") as fh:
                fh.write(
                    json.dumps(
                        {
                            "path": path,
                            "headers": {k.lower(): v for k, v in self.headers.items()},
                            "body": req,
                        }
                    )
                    + "\n"
                )

        scenario = CFG["scenario"]
        if scenario == "upstream-5xx":
            self._send(502, _err("api_error", "upstream provider error"))
            return
        if scenario == "throttle-429":
            self._send(
                429,
                _err("rate_limit_error", "rate limited by upstream provider"),
                {"Retry-After": "13"},
            )
            return
        if scenario == "context-length":
            self._send(
                400,
                _err(
                    "invalid_request_error",
                    "prompt is too long: 260000 tokens > 200000 maximum "
                    "(context_length_exceeded)",
                ),
            )
            return
        if scenario == "slow":
            time.sleep(CFG["delay"])

        self._send(200, self._message(model))

    def _message(self, model):
        # A 200 whose content carries NO text block. Found by driving the real
        # gateway: a reasoning model can spend its entire output budget inside
        # `thinking` and return nothing else. The lens extracts `.type == "text"`
        # blocks, so this used to surface as ok:true / bytes:0 / exit 0 — a green
        # empty answer the caller had already paid for.
        #   thinking-only  stop_reason max_tokens (the measured shape)
        #   empty-text     stop_reason end_turn   (no text, not truncation)
        if CFG["scenario"] in ("thinking-only", "empty-text"):
            return {
                "id": "msg_fake_0001",
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [{"type": "thinking", "thinking": "...reasoning..."}],
                "stop_reason": ("max_tokens" if CFG["scenario"] == "thinking-only"
                                else "end_turn"),
                "stop_sequence": None,
                "usage": {"input_tokens": 11, "output_tokens": 40},
            }
        text = CFG["response_text"]
        if CFG["response_bytes"] > 0:
            # Deterministic filler for the KTD8 spill test: a body big enough
            # to cross the plugin's spill threshold, without a giant fixture.
            text = ("x" * 63 + "\n") * (CFG["response_bytes"] // 64 + 1)
        return {
            "id": "msg_fake_0001",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [{"type": "text", "text": text}],
            "stop_reason": "end_turn",
            "stop_sequence": None,
            "usage": {"input_tokens": 11, "output_tokens": 7},
        }


def main():
    ap = argparse.ArgumentParser(description="Fake Superagent Gateway for tests.")
    ap.add_argument("--token", default="fixture-token", help="the x-api-key it accepts")
    ap.add_argument("--aliases", default="fixture-alias", help="comma-separated served aliases")
    ap.add_argument(
        "--scenario",
        default="healthy",
        choices=["down", "healthy", "upstream-5xx", "throttle-429", "context-length", "slow",
            "thinking-only", "empty-text"],
    )
    ap.add_argument("--delay", type=float, default=5.0, help="seconds the slow scenario sleeps")
    ap.add_argument("--response-text", default="fixture response text")
    ap.add_argument("--response-bytes", type=int, default=0, help="pad the reply to ~N bytes")
    ap.add_argument("--port-file", default="", help="also write the port here")
    ap.add_argument("--request-log", default="", help="append each messages request as JSONL")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    CFG.update(
        {
            "token": args.token,
            "aliases": [a for a in args.aliases.split(",") if a],
            "scenario": args.scenario,
            "delay": args.delay,
            "response_text": args.response_text,
            "response_bytes": args.response_bytes,
            "request_log": args.request_log,
            "verbose": args.verbose,
        }
    )

    if args.scenario == "down":
        # Claim an ephemeral port only long enough to learn its number, then
        # release it. The caller gets a real port that nothing is listening on.
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        _announce(port, args.port_file)
        return

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    _announce(port, args.port_file)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        while thread.is_alive():
            thread.join(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.shutdown()


def _announce(port, port_file):
    # flush matters: a test capturing this line through a pipe blocks forever
    # on a buffered stdout that never drains until the process exits.
    if port_file:
        with open(port_file, "w", encoding="utf-8") as fh:
            fh.write(str(port) + "\n")
    print("PORT=%d" % port, flush=True)


if __name__ == "__main__":
    main()
