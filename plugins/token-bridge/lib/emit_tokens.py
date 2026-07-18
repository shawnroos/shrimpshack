#!/usr/bin/env python3
"""Emit CSS from a Paper file's tokens — the reverse direction of sync_tokens.

Paper stores the base+dark model as base tokens (`--x`) plus `-dark`-suffixed
twins (`--x-dark`), because Paper has no per-token theme mode (see sync_tokens).
This module inverts that scheme back into CSS: a base `:root { … }` block plus a
dark override block written in the config's PRIMARY theme convention.

Inverting the twin scheme has TWO halves (KTD4) — miss either and the round-trip
breaks:
  1. property name:  `--x-dark`            -> `--x`   (inside the dark scope)
  2. alias referent: `var(--y-dark)`       -> `var(--y)`
     A dark twin that aliases another theme-varying token references THAT token's
     dark twin (`var(--y-dark)`). The emitted dark scope redeclares `--y`, so the
     referent must lose its `-dark` too, or the emitted CSS references a
     `--y-dark` property that does not exist in the dark scope and parse resolves
     it to null.

Round-trip stability (R5): emit -> parse (parse_tokens) -> build_desired ->
diff against the Paper set is EMPTY. This is a token-MODEL fixed point, not a
byte compare — Paper re-serializes values on store (`rgba()` -> `rgb( / %)`,
`0` -> `0px`, `transparent` -> `#00000000`), so a string compare would churn.
build_desired + diff_tokens (from sync_tokens) own the canonical comparison, and
they normalize the re-parsed alias-flip form back to the same twin the Paper set
carries — so the fixed point holds even though parse sees an explicit dark alias
where the original source had a flip-through.

CLI:
  python3 emit_tokens.py run --repo R                       # live: get_tokens -> write emitTarget
  python3 emit_tokens.py emit-from-file --tokens F --conventions J [--prefix P]
  python3 emit_tokens.py roundtrip --tokens F --conventions J [--prefix P]
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# Sibling lib modules — READ/import only.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import classify_tokens  # noqa: E402
import parse_tokens  # noqa: E402
import sync_tokens  # noqa: E402
from paper_client import (  # noqa: E402
    PaperClient,
    read_config,
    resolve_repo_path,
)

# The reserved dark-twin suffix — the exact one sync_tokens writes, so emit
# inverts precisely what sync produced.
DARK_SUFFIX = sync_tokens.DARK_SUFFIX

EXIT_OK = 0
EXIT_REFUSED = 2  # no fileId / no config — refuse, write nothing
EXIT_ERROR = 4  # daemon / config / write failure


def _log(msg: str) -> None:
    print(f"[emit_tokens] {msg}", file=sys.stderr)


# --- the pure inverse (tokens -> CSS), unit-testable, no daemon --------------


def _strip_dark_alias(value):
    """In a dark-twin value, de-suffix a `var(--y-dark)` referent to `var(--y)`.

    A dark twin references another theme-varying token's dark twin; the emitted
    dark scope redeclares the plain name, so the referent must lose `-dark` too.
    A non-twin referent (`var(--y)`) or a literal is returned unchanged."""
    if value is None:
        return value
    m = parse_tokens._VAR.match(value.strip())
    if not m:
        return value
    ref = m.group(1)
    if ref.endswith(DARK_SUFFIX):
        return "var(%s)" % ref[: -len(DARK_SUFFIX)]
    return value


def _root_block(pairs):
    body = "\n".join("  %s: %s;" % (name, val) for name, val in pairs)
    return ":root {\n%s\n}" % body


def _dark_block(conv, pairs):
    """Wrap the dark declarations in the primary convention's scope."""
    ctype = conv.get("type")
    if ctype == "data-attribute":
        selector = ':root[%s="%s"]' % (conv.get("attr"), conv.get("value"))
        body = "\n".join("  %s: %s;" % (name, val) for name, val in pairs)
        return "%s {\n%s\n}" % (selector, body)
    if ctype == "media-query":
        body = "\n".join("    %s: %s;" % (name, val) for name, val in pairs)
        return "@media %s {\n  :root {\n%s\n  }\n}" % (conv.get("query"), body)
    raise ValueError("unknown themeConvention type: %r" % ctype)


def emit_css(paper_tokens, conventions, prefix=None):
    """Emit a CSS string from a Paper token set (base + `-dark` twins).

    Partitions base tokens from `-dark` twins by the suffix, emits a `:root`
    base block and a dark override block in the primary convention, inverting
    both the twin name and its alias referents (KTD4). `prefix`, when set,
    restricts output to matching names (the Paper set is already prefix-filtered
    by sync, so this is a belt-and-suspenders match for the round-trip)."""
    primary = parse_tokens._primary_convention(conventions)

    def keep(name):
        return (not prefix) or name.startswith(prefix)

    base_pairs = sorted(
        (t["name"], t.get("value"))
        for t in paper_tokens
        if not t["name"].endswith(DARK_SUFFIX) and keep(t["name"])
    )
    dark_pairs = sorted(
        (t["name"][: -len(DARK_SUFFIX)], _strip_dark_alias(t.get("value")))
        for t in paper_tokens
        if t["name"].endswith(DARK_SUFFIX) and keep(t["name"])
    )

    blocks = [_root_block(base_pairs)]
    if dark_pairs:
        blocks.append(_dark_block(primary, dark_pairs))
    return "\n\n".join(blocks) + "\n"


# --- round-trip proof (R5), no daemon ----------------------------------------


def roundtrip(paper_tokens, conventions, prefix=None):
    """Prove the R5 fixed point: emit -> parse -> build_desired -> diff vs the
    Paper set. Returns {css, diff, empty}. `empty` True == round-trip stable."""
    css = emit_css(paper_tokens, conventions, prefix)
    records = parse_tokens.parse_tokens(css, conventions, prefix)
    classified = classify_tokens.classify_tokens(records)
    desired, _declined = sync_tokens.build_desired(classified)
    diff = sync_tokens.diff_tokens(desired, paper_tokens)
    return {"css": css, "diff": diff, "empty": sync_tokens.is_empty_diff(diff)}


# --- live path (get_tokens -> write emitTarget) ------------------------------


def run(repo=".", url=None):
    """Read the configured Paper file's tokens and write the emitted CSS to the
    config's emitTarget. Returns (report, exit_code).

    Refuses (writes nothing) when the config is missing or has no fileId. Refuses
    in-place emit onto a DUAL-convention source (KTD7) — writing the primary-only
    block back over a two-convention source would silently drop the other block."""
    file_id, cfg, err = read_config(repo)
    if err is not None:
        report = {"ok": False, "refused": True}
        report.update(err)
        return report, EXIT_REFUSED

    conventions = cfg.get("themeConventions") or []
    source = cfg.get("source") or {}
    prefix = source.get("prefix")

    emit_target = resolve_repo_path(cfg, cfg.get("emitTarget"))
    if not emit_target:
        return (
            {"ok": False, "error": "no emitTarget configured in token-bridge.config.json"},
            EXIT_ERROR,
        )

    # KTD7: in-place emit onto a dual-convention source is data loss.
    source_path = resolve_repo_path(cfg, source.get("path"))
    if (
        source_path
        and os.path.abspath(emit_target) == os.path.abspath(source_path)
        and len(conventions) > 1
    ):
        return (
            {
                "ok": False,
                "error": "refused_in_place_dual_convention",
                "note": (
                    "emitTarget equals the source and the source declares more "
                    "than one theme convention — emitting the primary-only block "
                    "in place would drop the other convention's block. Point "
                    "emitTarget at a distinct file."
                ),
            },
            EXIT_ERROR,
        )

    client = PaperClient(url=url or cfg.get("paperDaemonUrl"))
    env = client.get_tokens(file_id)
    if not env.get("ok"):
        return (
            {"ok": False, "error": "get_tokens failed", "envelope": env},
            EXIT_ERROR,
        )
    tokens = env.get("result", {}).get("tokens", []) or []

    css = emit_css(tokens, conventions, prefix)
    try:
        os.makedirs(os.path.dirname(os.path.abspath(emit_target)), exist_ok=True)
        with open(emit_target, "w", encoding="utf-8") as fh:
            fh.write(css)
    except OSError as exc:
        return ({"ok": False, "error": f"could not write {emit_target}: {exc}"}, EXIT_ERROR)

    return (
        {
            "ok": True,
            "emitTarget": emit_target,
            "tokenCount": len(tokens),
            "bytes": len(css),
        },
        EXIT_OK,
    )


# --- CLI ---------------------------------------------------------------------


def _load_json_file(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _tokens_from(obj):
    """Accept a bare token array or a get_tokens result envelope/dict."""
    if isinstance(obj, list):
        return obj
    if isinstance(obj, dict):
        return obj.get("tokens", obj.get("result", {}).get("tokens", []))
    return []


def main(argv=None):
    parser = argparse.ArgumentParser(prog="emit_tokens.py", description=__doc__)
    sub = parser.add_subparsers(dest="cmd")

    p_run = sub.add_parser("run", help="Live: get_tokens -> emit -> write emitTarget.")
    p_run.add_argument("--repo", default=".")
    p_run.add_argument("--url", default=None, help="Paper daemon URL override")

    p_emit = sub.add_parser("emit-from-file", help="Pure emit: tokens JSON -> CSS on stdout.")
    p_emit.add_argument("--tokens", required=True, help="Paper token set JSON (array or envelope)")
    p_emit.add_argument("--conventions", required=True, help="themeConventions JSON array")
    p_emit.add_argument("--prefix", default=None)

    p_rt = sub.add_parser("roundtrip", help="Prove R5: emit -> parse -> build_desired -> diff.")
    p_rt.add_argument("--tokens", required=True)
    p_rt.add_argument("--conventions", required=True)
    p_rt.add_argument("--prefix", default=None)

    args = parser.parse_args(argv)
    cmd = args.cmd or "run"

    if cmd == "run":
        report, code = run(repo=getattr(args, "repo", "."), url=getattr(args, "url", None))
        print(json.dumps(report, indent=2))
        if report.get("refused"):
            _log(report.get("note") or report.get("error", "refused"))
        return code

    if cmd == "emit-from-file":
        tokens = _tokens_from(_load_json_file(args.tokens))
        conventions = json.loads(args.conventions)
        sys.stdout.write(emit_css(tokens, conventions, args.prefix))
        return EXIT_OK

    if cmd == "roundtrip":
        tokens = _tokens_from(_load_json_file(args.tokens))
        conventions = json.loads(args.conventions)
        result = roundtrip(tokens, conventions, args.prefix)
        print(json.dumps(result, indent=2))
        return EXIT_OK if result["empty"] else EXIT_ERROR

    parser.print_usage(sys.stderr)
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main())
