#!/usr/bin/env python3
"""connect — bind a codebase to a Paper file by scaffolding its token-bridge.config.json.

`connect` is the one-time setup step: it writes `<repo>/token-bridge.config.json`
so the other commands (status, normalize-to-code, normalize-to-design,
refresh-components) can find the source CSS, the theme convention, and the target
Paper file. It EITHER references an existing Paper file (by id or URL) OR creates
a fresh one via the daemon and captures its id.

It refuses to overwrite an existing config unless `--force`, so re-running is safe.

CLI:
  connect.py --repo R --source src/styles/tokens.css --file <id-or-URL>
  connect.py --repo R --source src/styles/tokens.css --create-file --name "My Design"
  connect.py --repo R --source ... --convention media-query --query "(prefers-color-scheme: dark)"
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paper_client import CONFIG_FILENAME, PaperClient  # noqa: E402

EXIT_OK = 0
EXIT_BAD_ARGS = 2
EXIT_EXISTS = 3  # config already present, no --force
EXIT_ERROR = 4  # daemon / write failure

# Paper file URL: app.paper.design/file/<fileId>/<page> — capture the id segment.
_FILE_ID_IN_URL = re.compile(r"/file/([A-Za-z0-9]+)")


def _log(msg: str) -> None:
    print(f"[connect] {msg}", file=sys.stderr)


def extract_file_id(ref: str) -> str:
    """Resolve a Paper file id from a full URL or a bare id (returned as-is)."""
    ref = (ref or "").strip()
    m = _FILE_ID_IN_URL.search(ref)
    return m.group(1) if m else ref


def _convention(kind, attr, value, query):
    """Build the single primary themeConvention from the CLI flags."""
    if kind == "media-query":
        if not query:
            raise ValueError("--convention media-query requires --query")
        return {"type": "media-query", "query": query, "primary": True}
    # default / data-attribute
    return {
        "type": "data-attribute",
        "attr": attr or "data-theme",
        "value": value or "dark",
        "primary": True,
    }


def _default_emit_target(source_path):
    """Derive a sane emitTarget beside the source: `tokens.css` -> `tokens.generated.css`."""
    root, ext = os.path.splitext(source_path)
    return f"{root}.generated{ext or '.css'}"


def _theme_signal(conv):
    """The harvest theme signal mirrors the primary convention (minus `primary`)."""
    if conv["type"] == "media-query":
        return {"type": "media-query", "query": conv["query"]}
    return {"type": "data-attribute", "attr": conv["attr"], "value": conv["value"]}


def build_config(file_id, source_path, prefix, convention, emit_target, daemon_url):
    """Assemble the token-bridge config dict (schema-matching)."""
    return {
        "fileId": file_id,
        "paperDaemonUrl": daemon_url,
        "source": {"path": source_path, "ref": None, "prefix": prefix},
        "emitTarget": emit_target or _default_emit_target(source_path),
        "primitivePattern": None,
        "themeConventions": [convention],
        "harvest": {"themeSignal": _theme_signal(convention), "batch": []},
    }


def _created_file_id(env):
    """Pull the new file's id out of a create_file envelope (string or dict)."""
    payload = env.get("result")
    if isinstance(payload, str):
        return payload.strip()
    if isinstance(payload, dict):
        for key in ("fileId", "id", "fileID"):
            v = payload.get(key)
            if isinstance(v, str) and v.strip():
                return v.strip()
    return ""


def run(
    repo,
    source_path,
    convention,
    prefix=None,
    emit_target=None,
    file_ref=None,
    create_name=None,
    create=False,
    force=False,
    daemon_url="http://127.0.0.1:29979/mcp",
    client=None,
):
    """Scaffold <repo>/token-bridge.config.json. Returns (report, exit_code).

    Exactly one of `file_ref` (reference existing) or `create` (create a new
    Paper file) drives the target file. Refuses to overwrite an existing config
    unless `force`."""
    repo_abs = os.path.abspath(os.path.expanduser(repo))
    config_path = os.path.join(repo_abs, CONFIG_FILENAME)

    if os.path.exists(config_path) and not force:
        return (
            {
                "ok": False,
                "error": "config_exists",
                "note": f"{config_path} already exists — pass --force to overwrite.",
                "configPath": config_path,
            },
            EXIT_EXISTS,
        )

    if create == bool(file_ref):
        return (
            {
                "ok": False,
                "error": "bad_target",
                "note": "provide exactly one of --file <id|URL> or --create-file.",
            },
            EXIT_BAD_ARGS,
        )

    created = False
    if create:
        client = client or PaperClient(url=daemon_url)
        env = client.create_file(create_name)
        if not env.get("ok"):
            return (
                {"ok": False, "error": "create_file_failed", "envelope": env},
                EXIT_ERROR,
            )
        file_id = _created_file_id(env)
        if not file_id:
            return (
                {"ok": False, "error": "create_file_no_id", "envelope": env},
                EXIT_ERROR,
            )
        created = True
    else:
        file_id = extract_file_id(file_ref)
        if not file_id:
            return ({"ok": False, "error": "bad_file_ref", "note": file_ref}, EXIT_BAD_ARGS)

    cfg = build_config(file_id, source_path, prefix, convention, emit_target, daemon_url)

    try:
        with open(config_path, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)
            fh.write("\n")
    except OSError as exc:
        return ({"ok": False, "error": "write_failed", "note": str(exc)}, EXIT_ERROR)

    return (
        {
            "ok": True,
            "configPath": config_path,
            "fileId": file_id,
            "created": created,
            "source": cfg["source"]["path"],
            "emitTarget": cfg["emitTarget"],
            "convention": convention["type"],
        },
        EXIT_OK,
    )


def main(argv=None):
    p = argparse.ArgumentParser(prog="connect.py", description=__doc__)
    p.add_argument("--repo", required=True, help="Target codebase root (config is written here).")
    p.add_argument("--source", required=True, help="CSS/SCSS source path, relative to --repo.")
    p.add_argument("--prefix", default=None, help="Custom-property prefix (omit for all).")
    p.add_argument("--emit-target", default=None, help="Paper->CSS output path (default: <source>.generated.<ext>).")
    p.add_argument("--convention", choices=["data-attribute", "media-query"], default="data-attribute")
    p.add_argument("--attr", default="data-theme", help="data-attribute name (data-attribute convention).")
    p.add_argument("--value", default="dark", help="data-attribute value (data-attribute convention).")
    p.add_argument("--query", default=None, help="media query (media-query convention).")
    p.add_argument("--file", dest="file_ref", default=None, help="Existing Paper file id or URL to bind.")
    p.add_argument("--create-file", dest="create", action="store_true", help="Create a new Paper file to bind.")
    p.add_argument("--name", default=None, help="Display name for --create-file.")
    p.add_argument("--force", action="store_true", help="Overwrite an existing config.")
    p.add_argument("--url", default="http://127.0.0.1:29979/mcp", help="Paper daemon URL.")
    args = p.parse_args(argv)

    try:
        convention = _convention(args.convention, args.attr, args.value, args.query)
    except ValueError as exc:
        print(json.dumps({"ok": False, "error": "bad_convention", "note": str(exc)}))
        return EXIT_BAD_ARGS

    report, code = run(
        repo=args.repo,
        source_path=args.source,
        convention=convention,
        prefix=args.prefix,
        emit_target=args.emit_target,
        file_ref=args.file_ref,
        create_name=args.name,
        create=args.create,
        force=args.force,
        daemon_url=args.url,
    )
    print(json.dumps(report, indent=2))
    if not report.get("ok"):
        _log(report.get("note") or report.get("error", "failed"))
    return code


if __name__ == "__main__":
    sys.exit(main())
