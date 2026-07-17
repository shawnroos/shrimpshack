#!/usr/bin/env python3
"""harvest.py — wrap agent-browser to harvest a WCS component's rendered structure
and computed styles from a running dev server, producing JSON for the U7 mapper.

Unit U6 of the wcs-paper plugin.

WHAT IT DOES
------------
For a component entry (name / selector / route / optional trigger steps) it drives a
logged-in agent-browser session:
  1. open the route (the WCS editor needs auth + a loaded project, so this runs against
     an `agent-browser --profile <name>` session that is already logged in),
  2. run any trigger steps (e.g. open a drawer) to make the component render,
  3. eval harvest_extract.js against the selector, which returns the node tree + the
     active theme with getComputedStyle values already resolved to literals.

FAIL-SOFT ENVELOPES (never a hang or a stack trace to the caller)
  - dev server unreachable  -> {"ok": false, "error": "server_unreachable", ...}
  - selector never renders   -> {"ok": false, "error": "component_not_found", ...}
A selector that never renders is NEVER reported as an empty-but-successful result.

TEST COVERAGE (see tests/unit/harvest.bats)
  UNIT-TESTED (no live server; agent-browser faked via $WCS_PAPER_AGENT_BROWSER):
    - server_unreachable envelope when `open` fails,
    - component_not_found envelope when eval yields a null/empty node,
    - structure pass-through: one record per node + active theme, from a fixture blob,
    - selector injection into the eval script,
    - envelope shape / valid-JSON output.
  SMOKE-ONLY (needs a live, logged-in WCS dev server — cannot be unit-tested here):
    - AE4: a currentColor / color-mix() border coming back as a LITERAL hex/rgb value.
      That resolution happens in the real browser's getComputedStyle; a fixture can
      only assert the pass-through, not that the browser did the resolving.

The agent-browser binary is taken from $WCS_PAPER_AGENT_BROWSER (default: "agent-browser")
so tests can inject a fake command without a PATH shim.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

LIB_DIR = Path(__file__).resolve().parent
EXTRACT_JS_PATH = LIB_DIR / "harvest_extract.js"
DEFAULT_BATCH_PATH = LIB_DIR / "harvest_batch.json"
SELECTOR_TOKEN = '"__WCS_PAPER_SELECTOR__"'

AGENT_BROWSER = os.environ.get("WCS_PAPER_AGENT_BROWSER", "agent-browser")
DEFAULT_BASE_URL = os.environ.get("WCS_PAPER_BASE_URL", "http://localhost:4200")
DEFAULT_PROFILE = os.environ.get("WCS_PAPER_PROFILE", "wcs")
# agent-browser can genuinely hang if the page never settles; bound every call.
STEP_TIMEOUT = int(os.environ.get("WCS_PAPER_STEP_TIMEOUT", "60"))

# Substrings in agent-browser stderr that mean "the dev server isn't reachable".
_UNREACHABLE_MARKERS = (
    "err_connection",
    "econnrefused",
    "err_name_not_resolved",
    "err_address_unreachable",
    "net::err",
    "connection refused",
    "unreachable",
    "timed out",
    "timeout",
)


class HarvestError(Exception):
    """A soft failure that maps to an error envelope (code + human message)."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


# --------------------------------------------------------------------------- #
# Pure, unit-testable logic (no subprocess, no browser)                        #
# --------------------------------------------------------------------------- #

def build_extract_js(template: str, selector: str) -> str:
    """Inject `selector` into the eval template by replacing the quoted token.

    json.dumps gives a correctly-escaped JS string literal, so a selector with
    quotes/backslashes can't break out of the string.
    """
    return template.replace(SELECTOR_TOKEN, json.dumps(selector))


def _unwrap(data):
    """agent-browser --json may wrap the eval result in a container key.

    Our payload always carries `ok`/`root`/`theme`; if the top level lacks those
    but looks like a single-key wrapper (result/value/data/output), unwrap once.
    """
    if isinstance(data, dict) and not ({"ok", "root", "theme"} & data.keys()):
        for key in ("result", "value", "data", "output"):
            if key in data:
                return data[key]
    return data


def interpret_eval_output(raw: str):
    """Parse agent-browser eval stdout into our payload dict.

    Raises HarvestError("component_not_found", ...) when the eval produced no
    component — null, empty, ok:false, or a missing root. Never returns an
    empty-but-successful payload for a selector that didn't render.
    """
    text = (raw or "").strip()
    if text == "":
        raise HarvestError("component_not_found", "eval returned no output")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise HarvestError("component_not_found", f"eval output was not JSON: {exc}")

    payload = _unwrap(data)

    if not payload or not isinstance(payload, dict):
        raise HarvestError("component_not_found", "selector matched no element")
    if payload.get("ok") is False:
        raise HarvestError(
            "component_not_found",
            payload.get("message") or "selector matched no element",
        )
    if not payload.get("root"):
        raise HarvestError("component_not_found", "component root did not render")
    return payload


def flatten_nodes(root: dict, theme, path: str = "0"):
    """Yield one flat record per node in the tree, each stamped with the theme."""
    yield {
        "path": path,
        "tag": root.get("tag"),
        "text": root.get("text", ""),
        "styles": root.get("styles", {}),
        "theme": theme,
    }
    for i, child in enumerate(root.get("children", []) or []):
        yield from flatten_nodes(child, theme, f"{path}.{i}")


def build_success_envelope(entry: dict, payload: dict) -> dict:
    """Assemble the ok envelope U7 consumes: tree + theme + per-node records."""
    theme = payload.get("theme")
    root = payload["root"]
    return {
        "ok": True,
        "name": entry.get("name"),
        "selector": entry.get("selector"),
        "route": entry.get("route"),
        "theme": theme,
        "root": root,
        "nodes": list(flatten_nodes(root, theme)),
    }


def error_envelope(code: str, message: str, entry: dict | None = None) -> dict:
    # `note` is the field every other wcs-paper script uses for the human
    # message (paper_client/sync_tokens/write_component); keep `message` too so
    # anything already reading it still works.
    env = {"ok": False, "error": code, "note": message, "message": message}
    if entry:
        env["name"] = entry.get("name")
        env["selector"] = entry.get("selector")
        env["route"] = entry.get("route")
    return env


def build_url(base_url: str, route: str) -> str:
    if route.startswith("http://") or route.startswith("https://"):
        return route
    return base_url.rstrip("/") + "/" + route.lstrip("/")


def _looks_unreachable(stderr: str) -> bool:
    low = (stderr or "").lower()
    return any(marker in low for marker in _UNREACHABLE_MARKERS)


# --------------------------------------------------------------------------- #
# Side-effecting boundary (the only part that touches the browser)             #
# --------------------------------------------------------------------------- #

def run_agent_browser(args: list[str]) -> subprocess.CompletedProcess:
    """Invoke agent-browser with the given args. Raises HarvestError on missing
    binary or timeout — both surface as soft envelopes upstream."""
    cmd = [AGENT_BROWSER, *args]
    try:
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=STEP_TIMEOUT,
        )
    except FileNotFoundError:
        raise HarvestError(
            "agent_browser_missing",
            f"agent-browser binary not found (looked for '{AGENT_BROWSER}')",
        )
    except subprocess.TimeoutExpired:
        raise HarvestError(
            "server_unreachable",
            f"agent-browser timed out after {STEP_TIMEOUT}s",
        )


def harvest_entry(entry: dict, base_url: str, profile: str) -> dict:
    """Harvest one component. Always returns an envelope (ok or error), never raises."""
    selector = entry.get("selector")
    route = entry.get("route", "")
    triggers = entry.get("trigger") or []
    try:
        if not selector:
            raise HarvestError("component_not_found", "entry has no selector")

        url = build_url(base_url, route)

        # 1. Open the route. A failure here means the dev server isn't reachable.
        #    (An SPA returns 200 for unknown client routes, so a bad route surfaces
        #    later as component_not_found, not here.)
        opened = run_agent_browser(["--profile", profile, "open", url])
        if opened.returncode != 0:
            raise HarvestError(
                "server_unreachable",
                f"could not open {url}: {(opened.stderr or opened.stdout).strip()[:400]}",
            )

        # 2. Trigger steps (best-effort). Each is a list of agent-browser args,
        #    e.g. ["click", "button.wcs-open-typography"]. If a step can't run the
        #    dev server is likely down; anything else is left for the eval to catch.
        for step in triggers:
            if not isinstance(step, list) or not step:
                continue
            res = run_agent_browser(["--profile", profile, *step])
            if res.returncode != 0 and _looks_unreachable(res.stderr):
                raise HarvestError(
                    "server_unreachable",
                    f"trigger step {step} failed: {(res.stderr or '').strip()[:200]}",
                )

        # 3. Eval the extractor against the selector.
        template = EXTRACT_JS_PATH.read_text()
        js = build_extract_js(template, selector)
        evaluated = run_agent_browser(["--profile", profile, "eval", js, "--json"])
        if evaluated.returncode != 0:
            if _looks_unreachable(evaluated.stderr):
                raise HarvestError(
                    "server_unreachable",
                    f"eval failed: {(evaluated.stderr or '').strip()[:200]}",
                )
            raise HarvestError(
                "component_not_found",
                f"eval failed: {(evaluated.stderr or '').strip()[:200]}",
            )

        payload = interpret_eval_output(evaluated.stdout)
        return build_success_envelope(entry, payload)

    except HarvestError as err:
        return error_envelope(err.code, err.message, entry)


# --------------------------------------------------------------------------- #
# CLI                                                                          #
# --------------------------------------------------------------------------- #

def load_batch(path: Path) -> list[dict]:
    """Load harvest_batch.json. Accepts either a bare array or {"components":[...]}."""
    data = json.loads(path.read_text())
    if isinstance(data, dict):
        return data.get("components", [])
    if isinstance(data, list):
        return data
    return []


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Harvest a WCS component's structure + computed styles as JSON."
    )
    parser.add_argument(
        "--batch",
        default=str(DEFAULT_BATCH_PATH),
        help="Path to harvest_batch.json (default: alongside this script).",
    )
    parser.add_argument(
        "--name",
        help="Harvest only the component with this name. Omit to harvest the whole batch.",
    )
    parser.add_argument(
        "--base-url",
        default=DEFAULT_BASE_URL,
        help=f"Dev server base URL (default: {DEFAULT_BASE_URL}).",
    )
    parser.add_argument(
        "--profile",
        default=DEFAULT_PROFILE,
        help=f"agent-browser --profile name for the logged-in session (default: {DEFAULT_PROFILE}).",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List component names in the batch and exit.",
    )
    args = parser.parse_args(argv)

    batch_path = Path(args.batch)
    if not batch_path.exists():
        print(
            json.dumps(error_envelope("batch_not_found", f"no batch file at {batch_path}")),
            file=sys.stdout,
        )
        return 2

    entries = load_batch(batch_path)

    if args.list:
        print(json.dumps([e.get("name") for e in entries]))
        return 0

    if args.name:
        match = next((e for e in entries if e.get("name") == args.name), None)
        if match is None:
            print(
                json.dumps(
                    error_envelope("unknown_component", f"no component named '{args.name}' in batch")
                )
            )
            return 2
        print(json.dumps(harvest_entry(match, args.base_url, args.profile)))
        return 0

    # Whole batch: fail-soft per component, wrapped in a single result object.
    components = [harvest_entry(e, args.base_url, args.profile) for e in entries]
    print(json.dumps({"ok": True, "components": components}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
