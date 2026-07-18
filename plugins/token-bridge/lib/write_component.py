#!/usr/bin/env python3
"""write_component.py — harvest components, map their values to design-token refs,
and write them into the configured Paper file, REPLACING any prior copy.

The end-to-end "refresh components" command of token-bridge's code -> Paper path.

WHAT IT DOES (real / smoke path)
--------------------------------
1. Read the target `fileId` from the target codebase's token-bridge.config.json
   (found via --repo). If it is empty/absent the script REFUSES: it writes
   NOTHING, constructs no Paper client, and exits non-zero with an actionable
   message. A destructive reconcile must never fall back to whatever Paper file
   happens to be open (same guard as token-sync).
2. For each component in the harvest batch:
     a. harvest it via harvest.py (drives a logged-in agent-browser session),
     b. map its computed-style literals to var(--…) token refs via map_to_tokens.py
        against the parsed token set (parsed from the config source, not a
        hardcoded path).
3. Write the mapped component into Paper as nodes, REPLACING not duplicating:
     find_nodes  -> locate the existing wrapper by its stable layer name,
     delete_nodes -> remove it (and its subtree) if present,
     write_html  -> write the fresh copy.
   So re-running does NOT grow the node count.
4. Print a JSON report: components written / replaced + any near-misses (values
   that could only be mapped in the other theme) and unmapped literals.

DESIGN FOR TESTABILITY
----------------------
The harvest and the actual Paper writes need live services, but the ORCHESTRATION
LOGIC — the refuse-without-fileId guard and the find -> delete -> write replace
sequence — is unit-testable with NO live daemon or dev server:

  * The Paper client is dependency-injected through a factory (`make_client`).
    Setting $TB_FAKE_CLIENT to a JSON spec file swaps in a FakePaperClient
    that replays scripted find_nodes responses and RECORDS every call (method +
    args) to $TB_CALL_LOG, so a test can assert the exact call sequence.
  * `--mapped-file <path>` feeds a pre-mapped component envelope (or a list of
    them) straight into the write path, bypassing the live harvest+map entirely.
  * The refuse guard runs BEFORE any client is constructed, so a refusal provably
    issues ZERO Paper calls (the call log is never even written).

See tests/unit/write_component.bats. Scenarios that need a live, logged-in dev
server + Paper daemon (the actual components-land-on-canvas check) are
SMOKE-ONLY and are not covered by the unit suite.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# Import the shared Paper client + the token parser (READ-ONLY dependencies —
# never modified here).
LIB_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB_DIR))
from paper_client import read_config, PaperClient  # noqa: E402
import parse_tokens  # noqa: E402

DEFAULT_BATCH_PATH = LIB_DIR / "harvest_batch.json"

HARVEST_PY = LIB_DIR / "harvest.py"
MAP_PY = LIB_DIR / "map_to_tokens.py"

# Component wrappers are found on re-run by listing the target node's children
# and matching the wrapper's layer name (get_children) — a sentinel style was
# tried first but is not queryable against the live daemon.
WRAPPER_CSS = "display: flex; flex-direction: column;"

# Exit codes — kept distinct so callers/tests can tell failure kinds apart.
EXIT_OK = 0
EXIT_BAD_ARGS = 2
EXIT_REFUSED = 3  # no fileId in config -> refuse, wrote nothing
EXIT_ERROR = 4  # a write/daemon error occurred mid-run


# --------------------------------------------------------------------------- #
# Layer naming + HTML rendering (pure, unit-testable)                          #
# --------------------------------------------------------------------------- #

def layer_name_for(component_name: str) -> str:
    """The stable Paper layer name for a component. Deriving it from the component
    `name` gives a deterministic handle to find + replace on re-run (R13)."""
    return str(component_name)


_ESCAPE = (("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ('"', "&quot;"))


def _escape_text(value) -> str:
    s = "" if value is None else str(value)
    for a, b in _ESCAPE:
        s = s.replace(a, b)
    return s


def _style_attr(styles: dict) -> str:
    """Serialize a {prop: value} dict to a CSS inline-style string. var(--…)
    token refs are emitted verbatim so token bindings survive into the written HTML.

    Values are HTML-attribute-escaped: getComputedStyle font-family values carry
    double quotes (`"Helvetica Neue", sans-serif`) and typography is the first
    harvest batch, so an unescaped value would break out of the style attribute
    on the very first real run."""
    if not styles:
        return ""
    return " ".join(
        f"{_escape_text(prop)}: {_escape_text(value)};" for prop, value in styles.items()
    )


def render_node_html(node: dict) -> str:
    """Render one harvested/mapped node (and its subtree) to an HTML string.

    Style values are passed through untouched, so a mapped `var(--accent)`
    lands as-is in the Paper write payload.
    """
    tag = (node.get("tag") or "div").strip() or "div"
    # An <svg> node carries its raw markup (geometry attributes aren't computed
    # styles). Emit it verbatim so icons render instead of coming through blank.
    if node.get("svgHtml"):
        return node["svgHtml"]
    # An <img> node carries its src (an attribute, not a style); emit a real img.
    if node.get("imgSrc"):
        style = _style_attr(node.get("styles") or {})
        style_attr = f' style="{style}"' if style else ""
        return f'<img src="{_escape_text(node["imgSrc"])}"{style_attr} />'
    # Custom element tags (app-*) aren't valid Paper HTML containers; render them
    # as a div but keep the original tag name as the layer name for traceability.
    render_tag = tag if tag.isalnum() else "div"
    style = _style_attr(node.get("styles") or {})
    layer = tag
    inner = _escape_text(node.get("text"))
    for child in node.get("children") or []:
        inner += render_node_html(child)
    style_attr = f' style="{style}"' if style else ""
    return f'<{render_tag} layer-name="{_escape_text(layer)}"{style_attr}>{inner}</{render_tag}>'


def render_component_html(mapped: dict) -> str:
    """Wrap a mapped component in a layer-named wrapper div.

    The wrapper is the node find_nodes locates and delete_nodes removes, so the
    whole component subtree is replaced atomically on re-run.
    """
    name = mapped.get("name") or "component"
    layer = layer_name_for(name)
    root = mapped.get("root") or {"tag": "div", "text": "", "styles": {}, "children": []}
    body = render_node_html(root)
    return (
        f'<div layer-name="{_escape_text(layer)}" '
        f'data-tb-component="{_escape_text(name)}" '
        f'style="{WRAPPER_CSS}">{body}</div>'
    )


# --------------------------------------------------------------------------- #
# find_nodes result parsing (pure, unit-testable)                             #
# --------------------------------------------------------------------------- #

def node_ids_for_layer(find_envelope: dict, layer_name: str) -> list:
    """Extract the ids of nodes whose layer name matches `layer_name` from a
    find_nodes result envelope.

    PaperClient wraps the daemon payload as {"ok": True, "result": <payload>}.
    The payload is the tool's own shape; we look for a list of node records under
    the common keys and match each record's name field. The find query matches
    ALL component wrappers file-wide by their shared sentinel style, so ONLY an
    exact layer-name match is kept — a nameless record is never provably ours,
    and keeping it would let a single-component refresh delete every sibling
    wrapper's node.
    """
    if not isinstance(find_envelope, dict) or not find_envelope.get("ok"):
        return []
    payload = find_envelope.get("result")
    nodes = _extract_node_list(payload)
    ids = []
    for rec in nodes:
        if not isinstance(rec, dict):
            continue
        rec_name = rec.get("name")
        rec_id = rec.get("id") or rec.get("nodeId")
        if rec_id is None:
            continue
        if rec_name == layer_name:
            ids.append(rec_id)
    return ids


def _extract_node_list(payload) -> list:
    """Best-effort locate the list of node records in a find_nodes / get_children
    payload (get_children returns them under `children`)."""
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("children", "nodes", "results", "matches", "items"):
            val = payload.get(key)
            if isinstance(val, list):
                return val
    return []


# --------------------------------------------------------------------------- #
# The replace sequence (unit-testable with a fake client)                     #
# --------------------------------------------------------------------------- #

def write_mapped_component(client, file_id: str, mapped: dict, target_node_id: str) -> dict:
    """Write one mapped component into Paper, replacing any prior copy (R13).

    Sequence: find_nodes (by stable layer name) -> delete_nodes (if present) ->
    write_html. When find_nodes returns nothing, delete is SKIPPED and only the
    fresh write happens. Returns a per-component report record.
    """
    name = mapped.get("name") or "component"
    layer = layer_name_for(name)
    html = render_component_html(mapped)

    # 1. Locate any existing copy of this component: the wrapper is a direct
    #    child of the target node, so list the target's children and match by
    #    layer name. (A sentinel-style find_nodes does not work against the live
    #    daemon — outline-color is not queryable — so this scoped get_children
    #    lookup is what makes replace-not-duplicate real.)
    found = client.get_children(target_node_id, file_id)
    existing_ids = node_ids_for_layer(found, layer)

    # 2. Delete the prior copy ONLY when present — a not-yet-present component
    #    skips delete entirely. If the delete FAILS, do NOT write: writing anyway
    #    would duplicate the component while reporting it replaced (breaks R13).
    replaced = False
    if existing_ids:
        del_args = {"nodeIds": existing_ids}
        if file_id:
            del_args["fileId"] = file_id
        del_env = client.delete_nodes(del_args)
        if not (isinstance(del_env, dict) and del_env.get("ok")):
            return {
                "name": name,
                "layerName": layer,
                "replaced": False,
                "written": False,
                "nearMisses": mapped.get("near_misses") or [],
                "writeError": {"error": "replace_failed", "note": "could not delete "
                               "the prior copy; skipped the write to avoid a "
                               "duplicate", "deleteEnvelope": del_env},
            }
        replaced = True

    # 3. Write the fresh copy under the target node.
    write_args = {"html": html, "targetNodeId": target_node_id, "mode": "insert-children"}
    if file_id:
        write_args["fileId"] = file_id
    write_env = client.write_html(write_args)

    ok = bool(write_env.get("ok")) if isinstance(write_env, dict) else False
    return {
        "name": name,
        "layerName": layer,
        "replaced": replaced,
        "written": ok,
        "nearMisses": mapped.get("near_misses") or [],
        "writeError": None if ok else (write_env if isinstance(write_env, dict) else {"ok": False}),
    }


# --------------------------------------------------------------------------- #
# Config / batch loading + the refuse guard                                    #
# --------------------------------------------------------------------------- #

def load_batch(path: Path) -> list:
    data = json.loads(path.read_text())
    if isinstance(data, dict):
        return data.get("components", [])
    if isinstance(data, list):
        return data
    return []


# --------------------------------------------------------------------------- #
# Client factory (dependency injection seam)                                   #
# --------------------------------------------------------------------------- #

def make_client(url: str | None = None):
    """Return a Paper client. When $TB_FAKE_CLIENT points at a JSON spec,
    return a FakePaperClient instead (for unit tests / dry runs)."""
    spec_path = os.environ.get("TB_FAKE_CLIENT")
    if spec_path:
        return FakePaperClient.from_spec_file(spec_path)
    return PaperClient(url=url)


class FakePaperClient:
    """A record-and-replay stand-in for PaperClient, activated in tests via
    $TB_FAKE_CLIENT. It records every call (method + args) to
    $TB_CALL_LOG and returns scripted envelopes from the spec.

    Spec shape (all optional):
      {
        "find_nodes":  <envelope> | [<envelope>, ...],   # replayed per call
        "delete_nodes": <envelope>,
        "write_html":   <envelope>,
        "get_basic_info": <envelope>
      }
    A single envelope is returned for every call of that method; a list is
    consumed one entry per call (last entry repeats once exhausted).
    """

    def __init__(self, spec: dict):
        self.spec = spec or {}
        self.calls: list = []
        self._cursors: dict = {}
        self.log_path = os.environ.get("TB_CALL_LOG")

    @classmethod
    def from_spec_file(cls, path: str):
        with open(path, "r", encoding="utf-8") as fh:
            spec = json.load(fh)
        return cls(spec)

    def _record(self, method: str, args: dict) -> None:
        self.calls.append({"method": method, "args": args})
        if self.log_path:
            with open(self.log_path, "w", encoding="utf-8") as fh:
                json.dump(self.calls, fh, indent=2)

    def _reply(self, method: str) -> dict:
        scripted = self.spec.get(method)
        if scripted is None:
            return {"ok": True, "result": {}}
        if isinstance(scripted, list):
            idx = self._cursors.get(method, 0)
            if idx >= len(scripted):
                idx = len(scripted) - 1
            self._cursors[method] = self._cursors.get(method, 0) + 1
            return scripted[idx] if scripted else {"ok": True, "result": {}}
        return scripted

    def find_nodes(self, arguments: dict) -> dict:
        self._record("find_nodes", arguments)
        return self._reply("find_nodes")

    def get_children(self, node_id: str, file_id=None) -> dict:
        self._record("get_children", {"nodeId": node_id, "fileId": file_id})
        return self._reply("get_children")

    def delete_nodes(self, arguments: dict) -> dict:
        self._record("delete_nodes", arguments)
        return self._reply("delete_nodes")

    def write_html(self, arguments: dict) -> dict:
        self._record("write_html", arguments)
        return self._reply("write_html")

    def call_tool(self, name: str, arguments: dict) -> dict:
        self._record(name, arguments)
        return self._reply(name)


# --------------------------------------------------------------------------- #
# Target node resolution (smoke path only)                                     #
# --------------------------------------------------------------------------- #

def resolve_target_node_id(client, file_id: str, override: str | None) -> str | None:
    """Resolve the Paper node to insert components under.

    Precedence: explicit override (CLI/env) -> the first artboard reported by
    get_basic_info. Returns None when neither is available (the caller then emits
    a soft, actionable error). SMOKE-ONLY — unit tests inject the target directly.
    """
    if override:
        return override
    info = client.call_tool("get_basic_info", {"fileId": file_id} if file_id else {})
    if isinstance(info, dict) and info.get("ok"):
        payload = info.get("result")
        artboard = _first_artboard_id(payload)
        if artboard:
            return artboard
    return None


def _first_artboard_id(payload) -> str | None:
    if not isinstance(payload, dict):
        return None
    # Prefer a real artboard; else the root node (which write_html accepts).
    # A page id is NOT usable as a write_html target ("Node not found") — do not
    # fall back to `pages`.
    for key in ("artboards", "children", "nodes"):
        val = payload.get(key)
        if isinstance(val, list) and val and isinstance(val[0], dict):
            return val[0].get("id") or val[0].get("nodeId")
    return payload.get("rootNodeId")


# --------------------------------------------------------------------------- #
# Harvest + map (smoke path only — needs a live dev server)                    #
# --------------------------------------------------------------------------- #

def _parse_token_set(config: dict) -> str:
    """Return the parsed token-set JSON (as a string) from the config source.

    Reads the CSS/SCSS the config points at (working-tree path, or a git ref when
    `source.ref` is set) and parses it into the base+dark token records the mapper
    consumes — no hardcoded token path."""
    text = parse_tokens.load_source(config)
    records = parse_tokens.parse_tokens(
        text,
        config.get("themeConventions") or [],
        (config.get("source") or {}).get("prefix"),
    )
    return json.dumps(records)


def harvest_and_map(entry: dict, tokens_json: str, repo: str, primitive_pattern=None) -> dict:
    """Harvest one component (live) and map its literals to token refs.
    SMOKE-ONLY: harvest.py drives a real logged-in agent-browser session.

    `primitive_pattern` (config `primitivePattern`) overrides the mapper's
    default primitive-detection rule used in the value-collision tie-break."""
    name = entry.get("name")
    harvested = subprocess.run(
        ["python3", str(HARVEST_PY), "--name", name, "--repo", repo],
        capture_output=True, text=True,
    )
    if harvested.returncode != 0:
        return {"ok": False, "name": name, "error": "harvest_failed",
                "note": (harvested.stderr or harvested.stdout).strip()[:400]}
    # harvest --name prints a single component envelope.
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tf:
        tf.write(tokens_json)
        tokens_path = tf.name
    try:
        map_cmd = ["python3", str(MAP_PY), "--tokens", tokens_path]
        if primitive_pattern:
            map_cmd += ["--primitive-pattern", primitive_pattern]
        mapped = subprocess.run(
            map_cmd,
            input=harvested.stdout, capture_output=True, text=True,
        )
    finally:
        os.unlink(tokens_path)
    if mapped.returncode != 0:
        return {"ok": False, "name": name, "error": "map_failed",
                "note": (mapped.stderr or "").strip()[:400]}
    return json.loads(mapped.stdout)


# --------------------------------------------------------------------------- #
# Orchestration                                                                #
# --------------------------------------------------------------------------- #

def write_all(client, file_id: str, mapped_components: list, target_node_id: str) -> dict:
    """Write a list of already-mapped components, returning the report."""
    written = []
    all_near_misses = []
    for mapped in mapped_components:
        if not mapped.get("ok"):
            written.append({"name": mapped.get("name"), "written": False,
                            "replaced": False, "error": mapped.get("error", "not_harvested")})
            continue
        rec = write_mapped_component(client, file_id, mapped, target_node_id)
        for nm in rec.get("nearMisses", []):
            all_near_misses.append({"component": rec["name"], **nm})
        written.append(rec)

    return {
        "ok": all(w.get("written") for w in written) if written else True,
        "fileId": file_id,
        "targetNodeId": target_node_id,
        "componentsWritten": sum(1 for w in written if w.get("written")),
        "componentsReplaced": sum(1 for w in written if w.get("replaced")),
        "written": written,
        "nearMisses": all_near_misses,
    }


def run(repo: str, batch_path: Path, mapped_file: str | None,
        target_override: str | None, url_override: str | None,
        names: list | None = None) -> tuple:
    """Full orchestration. Returns (envelope, exit_code)."""
    # --- refuse guard: BEFORE any client is constructed (zero Paper calls) ---
    file_id, config, refuse = read_config(repo)
    if refuse is not None:
        code = EXIT_BAD_ARGS if refuse.get("error") in ("bad_config", "no_config") else EXIT_REFUSED
        return (refuse, code)

    url = url_override or config.get("paperDaemonUrl")
    client = make_client(url=url)

    # --- resolve target node to insert under ---
    target_node_id = resolve_target_node_id(client, file_id, target_override)
    if not target_node_id:
        return ({
            "ok": False,
            "error": "no_target_node",
            "note": (
                "Could not resolve a Paper node to write components under. Open the "
                "target file in Paper and pass --target-node-id <artboardId> (or set "
                "$TB_TARGET_NODE_ID)."
            ),
            "fileId": file_id,
        }, EXIT_ERROR)

    # --- gather mapped components: from a fixture file (test/dry-run) or live ---
    if mapped_file:
        data = json.loads(Path(mapped_file).read_text())
        mapped_components = data if isinstance(data, list) else [data]
    else:
        # SMOKE path — needs a live dev server + Paper daemon.
        entries = load_batch(batch_path)
        if names:
            wanted = set(names)
            entries = [e for e in entries if e.get("name") in wanted]
            missing = wanted - {e.get("name") for e in entries}
            if missing:
                return ({"ok": False, "error": "unknown_component",
                         "note": f"not in {batch_path.name}: {sorted(missing)}"},
                        EXIT_BAD_ARGS)
        tokens_json = _parse_token_set(config)
        primitive_pattern = config.get("primitivePattern")
        mapped_components = [
            harvest_and_map(e, tokens_json, repo, primitive_pattern) for e in entries
        ]

    report = write_all(client, file_id, mapped_components, target_node_id)
    return (report, EXIT_OK if report.get("ok") else EXIT_ERROR)


# --------------------------------------------------------------------------- #
# CLI                                                                          #
# --------------------------------------------------------------------------- #

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="write_component.py",
        description="Harvest components, map their values to design-token refs, and "
                    "write them into the configured Paper file (replacing any prior copy).",
    )
    parser.add_argument("--repo", default=".",
                        help="Target codebase root holding token-bridge.config.json "
                             "(the config carries the target fileId + token source).")
    parser.add_argument("--batch", default=str(DEFAULT_BATCH_PATH),
                        help="Path to the harvest batch JSON (the component batch).")
    parser.add_argument("--mapped-file",
                        help="Skip live harvest+map: read a pre-mapped component envelope "
                             "(or a JSON array of them) from this path and write it. Used by "
                             "the unit tests and for dry runs.")
    parser.add_argument("--target-node-id",
                        default=os.environ.get("TB_TARGET_NODE_ID"),
                        help="Paper node id to insert components under (else resolved live).")
    parser.add_argument("--url", default=None, help="Paper daemon URL override.")
    parser.add_argument("--name", action="append", dest="names", metavar="COMPONENT",
                        help="Refresh only the named component(s) from the batch "
                             "(repeatable). Omit to refresh the whole batch.")
    args = parser.parse_args(argv)

    envelope, code = run(
        repo=args.repo,
        batch_path=Path(args.batch),
        mapped_file=args.mapped_file,
        target_override=args.target_node_id,
        url_override=args.url,
        names=args.names,
    )
    print(json.dumps(envelope, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
