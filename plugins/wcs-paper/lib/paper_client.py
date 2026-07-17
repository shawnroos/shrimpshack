#!/usr/bin/env python3
"""Paper desktop daemon client — JSON-RPC 2.0 over HTTP with SSE-framed responses.

Reusable by wcs-paper token-sync (U5) and component-harvest (U8). Wraps the
paper-desktop MCP tool surface:
  - token sync:      get_tokens / set_tokens / create_tokens
  - component harvest: write_html / find_nodes / delete_nodes
  - handshake:       initialize

The paper-desktop daemon (verified live: paper-desktop v0.4.4 at
http://127.0.0.1:29979/mcp, JSON-RPC 2.0, no auth, localhost only) frames its
HTTP responses as Server-Sent Events: the body is lines like

    event: message
    data: {...json...}

so the JSON must be extracted from the `data:` line(s) — you cannot json.loads
the whole body. Tool-call results nest the real payload a second level deep, as
a JSON *string* inside result.content[0].text, so that must be parsed again.

Design goals:
  - Importable module: `from paper_client import PaperClient, parse_sse_body,
    interpret_rpc_response`. Other units call these directly.
  - Runnable script for a manual smoke and for unit tests:
    `python3 paper_client.py <subcommand> ...`.
  - The SSE parse + response interpretation are standalone pure functions, unit
    testable from a fixture with no live daemon.
  - Fail soft: a connection error (daemon down) returns an error envelope
    {"ok": false, "error": "daemon_unreachable", ...} rather than raising.
  - A JSON-RPC error object in a response is surfaced as an error envelope
    (ok:false), never swallowed as success.
  - Diagnostics go to stderr; the structured result is printed as JSON to stdout.

Only urllib is used for HTTP (never curl — curl buffers SSE and can hang).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

# --- configuration -----------------------------------------------------------

DEFAULT_URL = "http://127.0.0.1:29979/mcp"
DEFAULT_TIMEOUT = 10  # seconds

# Exit codes for the CLI — kept distinct so callers/tests can tell failure kinds
# apart without parsing the envelope.
EXIT_OK = 0
EXIT_BAD_ARGS = 2
EXIT_UNREACHABLE = 3
EXIT_ERROR = 4  # JSON-RPC error, HTTP error, or malformed response


def _url() -> str:
    """Resolve the daemon URL: PAPER_MCP_URL env override, else the default."""
    return os.environ.get("PAPER_MCP_URL", DEFAULT_URL)


def _log(msg: str) -> None:
    """Diagnostics go to stderr so stdout stays clean JSON."""
    print(f"[paper_client] {msg}", file=sys.stderr)


# --- envelopes ---------------------------------------------------------------


def ok_envelope(payload) -> dict:
    return {"ok": True, "result": payload}


def error_envelope(error: str, note: str | None = None, **extra) -> dict:
    env = {"ok": False, "error": error}
    if note is not None:
        env["note"] = note
    env.update(extra)
    return env


# --- shared config -----------------------------------------------------------


def read_config(config_path: str) -> tuple:
    """Read wcs-paper.config.json and resolve the target fileId.

    Returns (file_id, config_dict, error_envelope_or_None). Both the sync and
    refresh commands read the target file the same way through this helper, so a
    trailing-newline or non-string fileId behaves identically in both. A
    missing/empty/non-string fileId yields a no_target_file error envelope —
    the destructive-reconcile refuse guard both commands depend on.
    """
    try:
        with open(config_path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        return None, {}, error_envelope(
            "no_target_file", note=f"config not found: {config_path}"
        )
    except (OSError, json.JSONDecodeError) as exc:
        return None, {}, error_envelope(
            "bad_config", note=f"could not read {config_path}: {exc}"
        )
    raw = cfg.get("fileId", "")
    file_id = raw.strip() if isinstance(raw, str) else ""
    if not file_id:
        return None, cfg, error_envelope(
            "no_target_file",
            note=f"set a non-empty string fileId in {config_path} — refusing to "
            "target whatever Paper file is currently open.",
        )
    return file_id, cfg, None


# --- pure parsing (unit-testable, no daemon) ---------------------------------


def parse_sse_body(body: str) -> dict:
    """Extract the JSON object from an SSE-framed response body.

    An SSE body is a sequence of lines. We only care about `data:` lines. Per
    the SSE spec, a single event's data field can be split across consecutive
    `data:` lines which are rejoined with a newline — and a JSON value split at
    whitespace and rejoined with a newline is still valid JSON, so this also
    handles chunked payloads. Non-data lines (event:, id:, retry:, comments,
    blank lines) are ignored.

    Returns the parsed JSON-RPC response object (dict).
    Raises ValueError if there is no data line or the joined data is not JSON.
    """
    data_lines = []
    for raw in body.splitlines():
        # `data:` optionally followed by a single space (SSE strips one space).
        if raw.startswith("data:"):
            chunk = raw[len("data:"):]
            if chunk.startswith(" "):
                chunk = chunk[1:]
            data_lines.append(chunk)
    if not data_lines:
        raise ValueError("no SSE data line found in response body")
    joined = "\n".join(data_lines)
    try:
        return json.loads(joined)
    except json.JSONDecodeError as exc:
        raise ValueError(f"SSE data line is not valid JSON: {exc}") from exc


def interpret_rpc_response(resp: dict) -> dict:
    """Turn a parsed JSON-RPC response into a caller-facing envelope.

    - A JSON-RPC error object -> error envelope (ok:false), surfaced not swallowed.
    - A tools/call result -> the inner payload parsed out of
      result.content[0].text (a JSON string), wrapped in ok_envelope.
    - Any other result (e.g. initialize) -> the raw result, wrapped in ok_envelope.
    """
    if not isinstance(resp, dict):
        return error_envelope(
            "bad_response", note=f"expected a JSON object, got {type(resp).__name__}"
        )

    if "error" in resp:
        rpc_error = resp["error"]
        note = None
        if isinstance(rpc_error, dict):
            note = rpc_error.get("message")
        return error_envelope("jsonrpc_error", note=note, rpc_error=rpc_error)

    result = resp.get("result", {})

    # An MCP tool-execution failure comes back as a *successful* JSON-RPC
    # response whose result carries isError:true (the error text is in content).
    # Treat it as a failure, or a rejected Paper write is reported as applied.
    if isinstance(result, dict) and result.get("isError"):
        note = None
        content = result.get("content")
        if isinstance(content, list) and content and isinstance(content[0], dict):
            note = content[0].get("text")
        return error_envelope("tool_error", note=note, result=result)

    # tools/call shape: {"result": {"content": [{"type": "text", "text": "<json>"}]}}
    if isinstance(result, dict):
        content = result.get("content")
        if isinstance(content, list) and content and isinstance(content[0], dict):
            text = content[0].get("text")
            if isinstance(text, str):
                try:
                    payload = json.loads(text)
                except json.JSONDecodeError:
                    # Not a nested JSON string — hand back the raw text.
                    payload = text
                return ok_envelope(payload)

    return ok_envelope(result)


# --- client ------------------------------------------------------------------


class PaperClient:
    """Thin JSON-RPC client for the Paper desktop daemon.

    All public methods return an envelope dict (never raise on daemon-down or
    JSON-RPC errors), so callers in other units can branch on env["ok"].
    """

    def __init__(self, url: str | None = None, timeout: int = DEFAULT_TIMEOUT):
        self.url = url or _url()
        self.timeout = timeout
        self._req_id = 0

    # -- low level ------------------------------------------------------------

    def _next_id(self) -> int:
        self._req_id += 1
        return self._req_id

    def _post(self, method: str, params: dict | None) -> dict:
        """POST a JSON-RPC request; return a caller-facing envelope.

        Fail soft: connection errors -> daemon_unreachable; HTTP errors and
        malformed bodies -> error envelope. Success -> interpret_rpc_response.
        """
        payload = {"jsonrpc": "2.0", "id": self._next_id(), "method": method}
        if params is not None:
            payload["params"] = params

        req = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode(),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                body = r.read().decode()
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = exc.read().decode()[:500]
            except Exception:  # noqa: BLE001 - best-effort diagnostic only
                pass
            _log(f"HTTP {exc.code} from daemon for {method}: {detail}")
            return error_envelope(
                "http_error",
                note=f"daemon returned HTTP {exc.code}",
                http_status=exc.code,
                detail=detail,
            )
        except urllib.error.URLError as exc:
            # Connection refused / daemon not running / DNS / timeout.
            _log(f"daemon unreachable at {self.url} for {method}: {exc.reason}")
            return error_envelope(
                "daemon_unreachable",
                note=f"could not reach the Paper daemon at {self.url} "
                f"({exc.reason}); is Paper running?",
            )
        except Exception as exc:  # noqa: BLE001 - final fail-soft backstop
            _log(f"unexpected transport error for {method}: {exc!r}")
            return error_envelope("transport_error", note=str(exc))

        try:
            resp = parse_sse_body(body)
        except ValueError as exc:
            _log(f"could not parse SSE body for {method}: {exc}")
            return error_envelope("bad_sse", note=str(exc), body=body[:500])

        return interpret_rpc_response(resp)

    def call_tool(self, name: str, arguments: dict) -> dict:
        """Invoke a Paper tool via tools/call."""
        return self._post("tools/call", {"name": name, "arguments": arguments})

    # -- handshake ------------------------------------------------------------

    def initialize(self) -> dict:
        return self._post(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "wcs-paper-client", "version": "0.1.0"},
            },
        )

    # -- token sync (U5) ------------------------------------------------------

    def get_tokens(self, file_id: str) -> dict:
        return self.call_tool("get_tokens", {"fileId": file_id})

    def set_tokens(self, tokens: list, file_id: str | None = None) -> dict:
        # Shape: {tokens: [{name, newName?, value?, delete?, description?}]}
        if not file_id:
            return error_envelope(
                "no_target_file",
                note="set_tokens is destructive and requires an explicit fileId; "
                "refusing rather than acting on whatever file is open.",
            )
        return self.call_tool("set_tokens", {"tokens": tokens, "fileId": file_id})

    def create_tokens(self, tokens: list, file_id: str | None = None) -> dict:
        # Shape: {tokens: [{type, name, value, description?}]}
        if not file_id:
            return error_envelope(
                "no_target_file",
                note="create_tokens requires an explicit fileId; refusing rather "
                "than acting on whatever file is open.",
            )
        return self.call_tool("create_tokens", {"tokens": tokens, "fileId": file_id})

    # -- component harvest (U8) ----------------------------------------------

    def write_html(self, arguments: dict) -> dict:
        return self.call_tool("write_html", arguments)

    def find_nodes(self, arguments: dict) -> dict:
        return self.call_tool("find_nodes", arguments)

    def get_children(self, node_id: str, file_id: str | None = None) -> dict:
        args = {"nodeId": node_id}
        if file_id:
            args["fileId"] = file_id
        return self.call_tool("get_children", args)

    def delete_nodes(self, arguments: dict) -> dict:
        return self.call_tool("delete_nodes", arguments)


# --- CLI ---------------------------------------------------------------------


def _read_source(path: str | None) -> str:
    """Read an SSE body from a file path, or stdin when path is None or '-'."""
    if path is None or path == "-":
        return sys.stdin.read()
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def _parse_tokens_arg(raw: str | None) -> list:
    if raw is None:
        raise ValueError("--tokens-json is required")
    value = json.loads(raw)
    if not isinstance(value, list):
        raise ValueError("--tokens-json must be a JSON array of token objects")
    return value


def _emit(envelope: dict) -> int:
    """Print the envelope as JSON to stdout; return the matching exit code."""
    print(json.dumps(envelope))
    if envelope.get("ok"):
        return EXIT_OK
    if envelope.get("error") == "daemon_unreachable":
        return EXIT_UNREACHABLE
    return EXIT_ERROR


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="paper_client.py",
        description="Client for the Paper desktop daemon (JSON-RPC over SSE).",
    )
    parser.add_argument(
        "--url",
        default=None,
        help="Daemon URL (default: $PAPER_MCP_URL or %s)" % DEFAULT_URL,
    )
    parser.add_argument(
        "--timeout", type=int, default=DEFAULT_TIMEOUT, help="HTTP timeout seconds"
    )
    sub = parser.add_subparsers(dest="cmd")

    # Offline: parse an SSE body from a file/stdin — no daemon needed.
    p_sse = sub.add_parser(
        "parse-sse",
        help="Parse an SSE-framed body (file or stdin) into a result envelope.",
    )
    p_sse.add_argument("file", nargs="?", default=None, help="SSE body file, or - for stdin")

    p_init = sub.add_parser("initialize", help="Send the JSON-RPC initialize handshake.")

    p_get = sub.add_parser("get-tokens", help="get_tokens for a fileId.")
    p_get.add_argument("file_id")

    p_set = sub.add_parser("set-tokens", help="set_tokens for a fileId.")
    p_set.add_argument("file_id")
    p_set.add_argument("--tokens-json", required=True, help="JSON array of token updates")

    p_create = sub.add_parser("create-tokens", help="create_tokens for a fileId.")
    p_create.add_argument("file_id")
    p_create.add_argument("--tokens-json", required=True, help="JSON array of new tokens")

    for name in ("write-html", "find-nodes", "delete-nodes"):
        pp = sub.add_parser(name, help=f"{name.replace('-', '_')} with raw arguments JSON.")
        pp.add_argument("--args-json", required=True, help="JSON object of tool arguments")

    args = parser.parse_args(argv)

    if args.cmd is None:
        parser.print_usage(sys.stderr)
        _log("no subcommand given")
        return EXIT_BAD_ARGS

    # Offline path first — never touches the network.
    if args.cmd == "parse-sse":
        try:
            body = _read_source(args.file)
        except OSError as exc:
            _log(f"cannot read SSE source: {exc}")
            return EXIT_BAD_ARGS
        try:
            resp = parse_sse_body(body)
        except ValueError as exc:
            return _emit(error_envelope("bad_sse", note=str(exc)))
        return _emit(interpret_rpc_response(resp))

    client = PaperClient(url=args.url, timeout=args.timeout)

    try:
        if args.cmd == "initialize":
            env = client.initialize()
        elif args.cmd == "get-tokens":
            env = client.get_tokens(args.file_id)
        elif args.cmd == "set-tokens":
            env = client.set_tokens(_parse_tokens_arg(args.tokens_json), args.file_id)
        elif args.cmd == "create-tokens":
            env = client.create_tokens(_parse_tokens_arg(args.tokens_json), args.file_id)
        elif args.cmd == "write-html":
            env = client.write_html(json.loads(args.args_json))
        elif args.cmd == "find-nodes":
            env = client.find_nodes(json.loads(args.args_json))
        elif args.cmd == "delete-nodes":
            env = client.delete_nodes(json.loads(args.args_json))
        else:  # pragma: no cover - argparse guards this
            parser.print_usage(sys.stderr)
            return EXIT_BAD_ARGS
    except (ValueError, json.JSONDecodeError) as exc:
        _log(f"bad arguments: {exc}")
        return EXIT_BAD_ARGS

    return _emit(env)


if __name__ == "__main__":
    sys.exit(main())
