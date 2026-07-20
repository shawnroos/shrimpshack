#!/usr/bin/env python3
"""status — report where a codebase's tokens and its Paper file disagree (read-only).

`status` is the "sync project" overview: it computes the drift between the source
CSS and the connected Paper file in BOTH directions and writes NOTHING. It's the
thing you run to decide which way to normalize:

  - onlyInCode    tokens the code defines that the Paper file lacks
  - onlyInDesign  tokens the Paper file has that the code lacks (owned by the prefix)
  - differ        tokens both carry with different values (a genuine conflict)

To make the design match the code, run normalize-to-code. To make the code match
the design, run normalize-to-design. `status` never picks for you.

The drift is exactly the sync reconcile diff, re-framed bidirectionally; the pure
`drift()` is unit-testable with injected token sets.

CLI:
  status.py --repo R
  status.py drift --source-file S --conventions J --live-file L [--prefix P]
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import classify_tokens  # noqa: E402
import parse_tokens  # noqa: E402
import sync_tokens  # noqa: E402
from paper_client import PaperClient, read_config  # noqa: E402

EXIT_OK = 0
EXIT_REFUSED = 2
EXIT_ERROR = 4

_HINT = (
    "normalize-to-code makes the design match your code; "
    "normalize-to-design makes your code match the design."
)


def _log(msg: str) -> None:
    print(f"[status] {msg}", file=sys.stderr)


def drift(desired, live, owned_prefix=None, *, unreadable):
    """Re-frame the reconcile diff as bidirectional drift (pure, read-only).

    Returns {inSync, onlyInCode, onlyInDesign, differ} — name lists, sorted."""
    d = sync_tokens.diff_tokens(
        desired, live, owned_prefix=owned_prefix, unreadable=unreadable
    )
    only_in_code = sorted(t["name"] for t in d["creates"])
    only_in_design = sorted(t["name"] for t in d["deletes"])
    # value change (update) or type change (recreate) — both are "same name, differs"
    differ = sorted(t["name"] for t in (d["updates"] + d["recreates"]))
    return {
        "inSync": sync_tokens.is_empty_diff(d),
        "onlyInCode": only_in_code,
        "onlyInDesign": only_in_design,
        "differ": differ,
    }


def desired_from_text(source_text, conventions, prefix=None, dark_texts=None):
    records = parse_tokens.parse_tokens(source_text, conventions, prefix, dark_texts)
    classified = classify_tokens.classify_tokens(records)
    desired, declined = sync_tokens.build_desired(classified)
    return desired, declined


def run(repo=".", url=None, client=None):
    """Read config + source + live Paper tokens, report the drift. Returns
    (report, exit_code). Writes nothing."""
    file_id, cfg, err = read_config(repo)
    if err is not None:
        report = {"ok": False, "refused": True}
        report.update(err)
        return report, EXIT_REFUSED

    conventions = cfg.get("themeConventions") or []
    prefix = (cfg.get("source") or {}).get("prefix")
    try:
        source_text = parse_tokens.load_source(cfg)
        # A `file` convention's dark theme is a separate file; parse cannot reach
        # outside the text it is handed. Same read-failure class as load_source,
        # so it shares the refusal path.
        dark_texts = parse_tokens.resolve_dark_texts(cfg)
        missing = parse_tokens.missing_imports()
        if missing and not (cfg.get("source") or {}).get("allowMissingImports"):
            listed = ", ".join(f"{spec!r}" for spec, _ in missing[:5])
            return (
                {"ok": False, "error": "unresolved_imports",
                 "note": (f"{len(missing)} import(s) could not be resolved: {listed}. "
                          "Their tokens are invisible to this parse, so any drift "
                          "reported here would be wrong.")},
                EXIT_ERROR,
            )
    except RuntimeError as exc:
        return {"ok": False, "error": "source_read_failed", "note": str(exc)}, EXIT_ERROR

    desired, declined = desired_from_text(source_text, conventions, prefix, dark_texts)

    client = client or PaperClient(url=url or cfg.get("paperDaemonUrl"))
    env = client.get_tokens(file_id)
    if not env.get("ok"):
        return {"ok": False, "error": "get_tokens failed", "envelope": env}, EXIT_ERROR
    # Use the module's own tolerant extractor (handles {tokens:[]} and a bare
    # array) rather than a dict-only access on the daemon-controlled payload.
    live = _tokens_from(env.get("result")) or []

    # Same text-derived protection as sync — status must agree with what sync
    # would actually do, or it reports drift that no normalize can ever clear.
    declared = parse_tokens.declared_names(source_text, prefix)
    for dark_text in (dark_texts or {}).values():
        declared |= parse_tokens.declared_names(dark_text, prefix)
    desired_names = {x["name"] for x in desired}
    # Two sources, because neither alone is complete:
    #   - declared in the source text but absent from `desired` (and its twin):
    #     covers parse-level loss, where no record exists to inspect;
    #   - everything explicitly declined: covers the degrade, where the BASE
    #     succeeded and only the twin was dropped, so the base is in `desired`
    #     and the text sweep sees nothing wrong.
    unreadable = {n for n in declared if n not in desired_names}
    unreadable |= {n + "-dark" for n in unreadable}
    unreadable |= {x["name"] for x in declined}

    d = drift(desired, live, owned_prefix=prefix, unreadable=unreadable)
    report = {
        "ok": True,
        "fileId": file_id,
        **d,
        "declined": declined,
        "hint": _HINT,
    }
    return report, EXIT_OK


def _load_json_file(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _tokens_from(obj):
    if isinstance(obj, list):
        return obj
    if isinstance(obj, dict):
        return obj.get("tokens", obj.get("result", {}).get("tokens", []))
    return []


def main(argv=None):
    parser = argparse.ArgumentParser(prog="status.py", description=__doc__)
    sub = parser.add_subparsers(dest="cmd")

    p_run = sub.add_parser("run", help="Live: read config + Paper, report drift (default).")
    p_run.add_argument("--repo", default=".")
    p_run.add_argument("--url", default=None)

    p_d = sub.add_parser("drift", help="Pure drift from injected source + live token files.")
    p_d.add_argument("--source-file", required=True)
    p_d.add_argument("--conventions", required=True, help="themeConventions JSON array")
    p_d.add_argument("--live-file", required=True, help="Paper token set JSON (array or envelope)")
    p_d.add_argument("--prefix", default=None)

    args = parser.parse_args(argv)
    cmd = args.cmd or "run"

    if cmd == "run":
        report, code = run(repo=getattr(args, "repo", "."), url=getattr(args, "url", None))
        print(json.dumps(report, indent=2))
        if report.get("refused"):
            _log(report.get("note") or report.get("error", "refused"))
        return code

    if cmd == "drift":
        with open(args.source_file, encoding="utf-8") as fh:
            source_text = fh.read()
        conventions = json.loads(args.conventions)
        needs_repo = parse_tokens.file_convention_needs_repo(conventions)
        if needs_repo:
            _log(needs_repo)
            return EXIT_REFUSED
        desired, _declined = desired_from_text(source_text, conventions, args.prefix)
        live = _tokens_from(_load_json_file(args.live_file))
        declared = parse_tokens.declared_names(source_text, args.prefix)
        desired_names = {x["name"] for x in desired}
        unreadable = {n for n in declared if n not in desired_names}
        unreadable |= {n + "-dark" for n in unreadable}
        unreadable |= {x["name"] for x in _declined}   # match run()'s derivation
        print(json.dumps(
            drift(desired, live, owned_prefix=args.prefix, unreadable=unreadable), indent=2
        ))
        return EXIT_OK

    parser.print_usage(sys.stderr)
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main())
