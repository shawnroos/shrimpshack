#!/usr/bin/env python3
"""Idempotent WCS token-sync — reconcile the merged develop SCSS into a Paper file.

This is U5's end-to-end command. It reads the two source SCSS files from the
merged `develop` ref, parses + classifies them (via the sibling lib modules),
builds the *desired* Paper token set, diffs it against the *live* Paper file,
and applies the minimal reconcile (create / update / delete / recreate). Re-run
against an unchanged source, it writes nothing (R7).

--------------------------------------------------------------------------------
LIGHT / DARK NAMING SCHEME (the deferred R3 decision, resolved here)
--------------------------------------------------------------------------------
Paper has no per-file "theme mode" for tokens, so the two WCS themes are written
as two *separately named* Paper tokens rather than two modes of one token:

  * The LIGHT value keeps the token's own name:      --wcs-accent
  * The DARK value gets a "-dark" suffixed twin:      --wcs-accent-dark

Only theme-VARYING tokens (parse_tokens gives them a non-null `dark`) get a dark
twin. Mode-invariant tokens (dark == null) are written exactly once, under their
own name, with no twin.

Aliases follow the same scheme *within their theme* (R2 + R3):
  * A LIGHT alias references the plain (light) name:   var(--wcs-green-500)
  * A DARK alias references the DARK counterpart —      var(--wcs-accent-dark)
    but ONLY when that referent is itself theme-varying (and therefore has a
    "-dark" twin). If the referent is mode-invariant it has no twin, so the dark
    alias references its plain name.

Worked example (from the real source):
    --wcs-timeline-playhead        = var(--wcs-accent)        # light twin
    --wcs-timeline-playhead-dark   = var(--wcs-accent-dark)   # dark twin,
                                                              # NOT var(--wcs-accent)

Tier-2 aliases are written as var(--wcs-*) references, never resolved to their
literal hex (R2) — parse_tokens' light_alias/dark_alias metadata drives this.

--------------------------------------------------------------------------------
Architecture
--------------------------------------------------------------------------------
The DIFF ENGINE is a pure function (desired, live) -> {creates, updates, deletes,
recreates} with no git and no daemon, so it is unit-testable against fixtures.
Only apply_diff() touches the live daemon. build_desired() is likewise pure over
classified records. read_source() is the only git-touching step and its ref /
paths are all injectable so tests can feed fixture text instead.

CLI:
  python3 sync_tokens.py                      # full pipeline (git + daemon)
  python3 sync_tokens.py run --config C       # explicit config; refuses if empty
  python3 sync_tokens.py build-desired --token-file F --general-file G
  python3 sync_tokens.py diff --desired D --live L
  python3 sync_tokens.py simulate-apply --live L --diff D
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

# Sibling lib modules — READ/import only (never modified by this unit).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import classify_tokens  # noqa: E402
import map_to_tokens  # noqa: E402
import parse_tokens  # noqa: E402
from paper_client import PaperClient  # noqa: E402

# --- configuration -----------------------------------------------------------

_HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.normpath(os.path.join(_HERE, "..", "wcs-paper.config.json"))
DEFAULT_REPO = os.path.expanduser("~/projects/Slate/web-app")
DEFAULT_REF = "origin/develop"
DEFAULT_TOKEN_PATH = "src/styles/themes/_wcs-design-tokens.scss"
DEFAULT_GENERAL_PATH = "src/styles/_general.scss"

DARK_SUFFIX = "-dark"

# Exit codes — distinct so callers/tests can tell failure kinds apart.
EXIT_OK = 0
EXIT_REFUSED = 2  # safety guard: no fileId configured
EXIT_ERROR = 4  # git / daemon / apply failure

def _log(msg: str) -> None:
    print(f"[sync_tokens] {msg}", file=sys.stderr)


# --- value normalization (shared by build + diff, for idempotency) -----------


def _norm_value(v):
    """Normalize a token value for comparison: strip, then uppercase every hex
    run via parse_tokens' own normalizer — one definition of "same value" feeds
    the diff whose emptiness is the R7 idempotency contract. Non-hex values
    (var(...), rgba(...), 8px) are unaffected beyond a strip."""
    if v is None:
        return None
    return parse_tokens._normalize_hex(v.strip())


def _norm_name(name):
    return name.lower()


_VAR_REF = re.compile(r"var\(\s*(--[A-Za-z0-9-]+)\s*\)")


def order_for_create(tokens):
    """Order create tokens so a var() alias is created AFTER its referent.

    Paper's create_tokens processes the array in order and a var(--x) whose
    referent does not exist YET fails silently — so an alphabetically-sorted
    batch drops every Tier-2 alias whose Tier-1 referent sorts later (e.g.
    --wcs-accent = var(--wcs-green-500)), and any alias chaining through it.
    Topological sort on the in-batch var() dependency; tokens with no in-batch
    referent keep their relative order and come first. Cycles (none exist in the
    WCS source) are broken by emitting in encounter order."""
    by_name = {t["name"]: t for t in tokens}
    ordered = []
    placed = set()
    visiting = set()

    def visit(t):
        name = t["name"]
        if name in placed or name in visiting:
            return
        visiting.add(name)
        m = _VAR_REF.search(t.get("value") or "")
        if m and m.group(1) in by_name:
            visit(by_name[m.group(1)])
        visiting.discard(name)
        placed.add(name)
        ordered.append(t)

    for t in tokens:
        visit(t)
    return ordered


# --- desired-set construction (pure over classified records) -----------------


def _alias_ref(referent, theme, theme_varying):
    """Resolve an alias referent to the name it should carry in `theme`.

    In the dark theme a referent that is itself theme-varying points at its
    "-dark" twin; otherwise (mode-invariant referent, or the light theme) it
    points at the plain name."""
    if theme == "dark" and referent in theme_varying:
        return referent + DARK_SUFFIX
    return referent


def _light_value(rec, theme_varying):
    """The light-theme write value: a var() alias if the light decl is an alias
    (R2), else the resolved light literal."""
    if rec.get("light_alias"):
        return "var(%s)" % _alias_ref(rec["light_alias"], "light", theme_varying)
    return _norm_value(rec.get("light"))


def _dark_value(rec, theme_varying, dark_literals):
    """The dark-theme write value. Alias precedence:
      1. an explicit dark alias (dark_alias) -> its dark-theme referent;
      2. a *flipping* light alias — the token has NO independent dark
         declaration, and it is theme-varying only because its light referent is
         redeclared in dark. Detected by the referent's resolved dark literal
         equalling this token's dark literal. -> the referent's dark twin.
      3. otherwise the resolved dark literal (an independent dark declaration,
         e.g. --wcs-accent aliases a primitive in light but is a literal in dark).
    """
    if rec.get("dark_alias"):
        return "var(%s)" % _alias_ref(rec["dark_alias"], "dark", theme_varying)
    ref = rec.get("light_alias")
    if ref and dark_literals.get(ref) == _norm_value(rec.get("dark")):
        # Pure flip-through: the dark value is the referent's flipped value, not
        # an independent literal. Reference the referent's dark twin.
        return "var(%s)" % _alias_ref(ref, "dark", theme_varying)
    return _norm_value(rec.get("dark"))


def build_desired(classified):
    """Build the desired Paper token list from classified records (pure).

    Returns (desired, declined) where:
      desired  = sorted list of {name, type, value} Paper tokens
      declined = sorted list of {name, reason} for non-writable tokens
    """
    theme_varying = {
        r["name"] for r in classified if r.get("dark") is not None
    }
    # Each token's effective dark literal (dark value, or light when invariant),
    # keyed by name — used to detect pure flip-through aliases in _dark_value.
    dark_literals = {
        r["name"]: _norm_value(
            r["dark"] if r.get("dark") is not None else r.get("light")
        )
        for r in classified
    }

    desired = []
    declined = []
    for rec in classified:
        if not rec.get("writable"):
            declined.append(
                {"name": rec["name"], "reason": rec.get("excluded_reason")}
            )
            continue

        ptype = rec["paper_type"]
        # Light twin (or the sole token for a mode-invariant value). A token
        # declared only in the dark block would resolve light=None; skip the
        # light twin rather than send value:None to create_tokens. (No such
        # token exists in today's source — the dark block is a strict subset.)
        light_val = _light_value(rec, theme_varying)
        if light_val is not None:
            desired.append({"name": rec["name"], "type": ptype, "value": light_val})
        # Dark twin — only for theme-varying tokens.
        if rec.get("dark") is not None:
            desired.append(
                {
                    "name": rec["name"] + DARK_SUFFIX,
                    "type": ptype,
                    "value": _dark_value(rec, theme_varying, dark_literals),
                }
            )

    desired.sort(key=lambda t: t["name"])
    declined.sort(key=lambda t: t["name"])
    return desired, declined


def _same_value(live_val, desired_val):
    """True when the live (Paper-stored) value equals the desired value AFTER
    canonicalizing for Paper's own serialization. Paper rewrites on store —
    `transparent` -> `#00000000`, `rgba(r,g,b,a)` -> `rgb(r g b / a%)`, `0` ->
    `0px` — so a raw string compare churns those tokens on every sync (R7). A
    var() alias has no color/length to canonicalize; it compares as a normalized
    string. map_to_tokens.normalize_value owns the canonical color/length form
    (shared with the harvest path)."""
    a = map_to_tokens.normalize_value(_norm_value(live_val))
    b = map_to_tokens.normalize_value(_norm_value(desired_val))
    return a == b


# --- the diff engine (PURE — no git, no daemon) ------------------------------


def diff_tokens(desired, live):
    """Diff the desired Paper token set against the live one (pure function).

    Compares with NORMALIZED name (lowercase) and value (uppercased hex) so an
    unchanged source yields an EMPTY diff (R7).

    Returns {creates, updates, deletes, recreates}:
      creates    tokens present in desired, absent from live         -> create
      updates    same name+type, value changed                       -> set value
      deletes    present in live, absent from desired                -> delete
      recreates  same name, TYPE changed (Paper cannot retype)       -> delete+create
    """
    live_by_name = {}
    for t in live:
        live_by_name[_norm_name(t["name"])] = t

    creates, updates, recreates = [], [], []
    desired_names = set()

    for d in desired:
        key = _norm_name(d["name"])
        desired_names.add(key)
        cur = live_by_name.get(key)
        if cur is None:
            creates.append(d)
            continue
        if cur.get("type") != d.get("type"):
            # Paper cannot change a token's type in place — delete then recreate.
            recreates.append(d)
            continue
        if not _same_value(cur.get("value"), d.get("value")):
            updates.append(d)

    deletes = [
        {"name": t["name"]}
        for t in live
        if _norm_name(t["name"]) not in desired_names
    ]

    return {
        "creates": creates,
        "updates": updates,
        "deletes": deletes,
        "recreates": recreates,
    }


def is_empty_diff(diff):
    return not (
        diff["creates"] or diff["updates"] or diff["deletes"] or diff["recreates"]
    )


# --- pure apply simulation (for idempotency round-trip tests, no daemon) ------


def simulate_apply(live, diff):
    """Apply a diff to a live-state list in memory and return the new state.

    Mirrors apply_diff()'s semantics without a daemon, so a round-trip
    (diff -> simulate-apply -> re-diff) can be asserted empty in a unit test."""
    state = {_norm_name(t["name"]): dict(t) for t in live}

    for t in diff["deletes"]:
        state.pop(_norm_name(t["name"]), None)
    for t in diff["recreates"]:
        state[_norm_name(t["name"])] = {
            "name": t["name"],
            "type": t["type"],
            "value": t["value"],
        }
    for t in diff["creates"]:
        state[_norm_name(t["name"])] = {
            "name": t["name"],
            "type": t["type"],
            "value": t["value"],
        }
    for t in diff["updates"]:
        cur = state[_norm_name(t["name"])]
        cur["value"] = t["value"]

    return sorted(state.values(), key=lambda t: _norm_name(t["name"]))


# --- apply against the live daemon -------------------------------------------


def apply_diff(client, file_id, diff):
    """Apply a diff via the PaperClient. Returns a per-step result summary.

    Order: deletes (deletes + recreate-old) first, then creates (creates +
    recreate-new), then value updates. Each step's envelope is captured; the
    first non-ok envelope short-circuits with ok:false."""
    steps = []

    # 1. Deletions: stale deletes + the delete half of every recreate.
    delete_names = [t["name"] for t in diff["deletes"]] + [
        t["name"] for t in diff["recreates"]
    ]
    if delete_names:
        env = client.set_tokens(
            [{"name": n, "delete": True} for n in delete_names], file_id
        )
        steps.append({"step": "delete", "names": delete_names, "envelope": env})
        if not env.get("ok"):
            return {"ok": False, "steps": steps}

    # 2. Creations: fresh creates + the create half of every recreate, ordered
    #    so a var() alias is created after its referent (Paper creates in array
    #    order and a dangling var() alias fails silently).
    create_tokens = order_for_create([
        {"type": t["type"], "name": t["name"], "value": t["value"]}
        for t in diff["creates"] + diff["recreates"]
    ])
    if create_tokens:
        env = client.create_tokens(create_tokens, file_id)
        steps.append(
            {
                "step": "create",
                "names": [t["name"] for t in create_tokens],
                "envelope": env,
            }
        )
        if not env.get("ok"):
            return {"ok": False, "steps": steps}

    # 3. Value updates (same type, changed value).
    if diff["updates"]:
        env = client.set_tokens(
            [{"name": t["name"], "value": t["value"]} for t in diff["updates"]],
            file_id,
        )
        steps.append(
            {
                "step": "update",
                "names": [t["name"] for t in diff["updates"]],
                "envelope": env,
            }
        )
        if not env.get("ok"):
            return {"ok": False, "steps": steps}

    return {"ok": True, "steps": steps}


# --- source reading (the only git-touching step) -----------------------------


def _git_show(repo, ref, path):
    """Return the text of `path` at `ref` from `repo` via `git show`."""
    proc = subprocess.run(
        ["git", "-C", repo, "show", f"{ref}:{path}"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"git show {ref}:{path} failed: {proc.stderr.strip()}"
        )
    return proc.stdout


def read_source(
    repo=DEFAULT_REPO,
    ref=DEFAULT_REF,
    token_path=DEFAULT_TOKEN_PATH,
    general_path=DEFAULT_GENERAL_PATH,
    token_text=None,
    general_text=None,
):
    """Read the two source SCSS texts. If token_text/general_text are provided
    they are used verbatim (test injection); otherwise both are read from git."""
    if token_text is None:
        token_text = _git_show(repo, ref, token_path)
    if general_text is None:
        general_text = _git_show(repo, ref, general_path)
    return token_text, general_text


def desired_from_source(token_text, general_text):
    """Full pure source pipeline: parse -> classify -> build_desired."""
    token_records = parse_tokens.parse_tokens(token_text)
    general_record = parse_tokens.parse_general(general_text)
    classified = classify_tokens.classify_tokens(token_records + [general_record])
    return build_desired(classified)


# --- config ------------------------------------------------------------------


def read_file_id(config_path):
    """Return the (stripped) configured fileId and daemon URL, or raise on
    unreadable. A non-string or whitespace-only fileId resolves to "" so the
    refuse guard fires — the stripped value is what actually reaches get_tokens,
    so a trailing newline in the config can't silently target a nonexistent
    file (matching write_component's guard)."""
    with open(config_path, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)
    raw = cfg.get("fileId", "")
    file_id = raw.strip() if isinstance(raw, str) else ""
    return file_id, cfg.get("paperDaemonUrl")


# --- top-level orchestration -------------------------------------------------


def run(
    config_path=DEFAULT_CONFIG,
    repo=DEFAULT_REPO,
    ref=DEFAULT_REF,
    token_path=DEFAULT_TOKEN_PATH,
    general_path=DEFAULT_GENERAL_PATH,
    token_text=None,
    general_text=None,
    url=None,
    apply=True,
):
    """The end-to-end reconcile. Returns (report_dict, exit_code).

    Refuses (writes NOTHING) when no fileId is configured — the destructive-
    reconcile safety guard. This runs BEFORE any git read or daemon call."""
    try:
        file_id, cfg_url = read_file_id(config_path)
    except (OSError, json.JSONDecodeError) as exc:
        return (
            {
                "ok": False,
                "refused": True,
                "error": f"cannot read config {config_path}: {exc}",
            },
            EXIT_REFUSED,
        )

    if not file_id.strip():
        return (
            {
                "ok": False,
                "refused": True,
                "error": (
                    "no fileId configured — set fileId in wcs-paper.config.json "
                    "(from the Paper file URL: app.paper.design/file/<fileId>). "
                    "Refusing: a destructive reconcile must never target the "
                    "wrong file."
                ),
            },
            EXIT_REFUSED,
        )

    # Source (git or injected fixture text).
    try:
        token_text, general_text = read_source(
            repo, ref, token_path, general_path, token_text, general_text
        )
    except RuntimeError as exc:
        return ({"ok": False, "error": str(exc)}, EXIT_ERROR)

    desired, declined = desired_from_source(token_text, general_text)

    # Live Paper tokens.
    client = PaperClient(url=url or cfg_url)
    live_env = client.get_tokens(file_id)
    if not live_env.get("ok"):
        return (
            {"ok": False, "error": "get_tokens failed", "envelope": live_env},
            EXIT_ERROR,
        )
    live = live_env.get("result", {}).get("tokens", []) or []

    diff = diff_tokens(desired, live)

    report = {
        "ok": True,
        "fileId": file_id,
        "created": [t["name"] for t in diff["creates"]],
        "updated": [t["name"] for t in diff["updates"]],
        "deleted": [t["name"] for t in diff["deletes"]],
        "recreated": [t["name"] for t in diff["recreates"]],
        "declined": declined,
        "empty": is_empty_diff(diff),
    }

    if apply and not is_empty_diff(diff):
        apply_result = apply_diff(client, file_id, diff)
        report["applied"] = apply_result["ok"]
        report["apply_steps"] = apply_result["steps"]
        if not apply_result["ok"]:
            report["ok"] = False
            return (report, EXIT_ERROR)
    else:
        report["applied"] = False

    return (report, EXIT_OK)


# --- CLI ---------------------------------------------------------------------


def _load_json_file(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="sync_tokens.py", description=__doc__)
    sub = parser.add_subparsers(dest="cmd")

    p_run = sub.add_parser("run", help="Full reconcile (git source + live daemon).")
    p_run.add_argument("--config", default=DEFAULT_CONFIG)
    p_run.add_argument("--repo", default=DEFAULT_REPO)
    p_run.add_argument("--ref", default=DEFAULT_REF)
    p_run.add_argument("--token-path", default=DEFAULT_TOKEN_PATH)
    p_run.add_argument("--general-path", default=DEFAULT_GENERAL_PATH)
    p_run.add_argument("--token-file", default=None, help="Inject token SCSS (skip git)")
    p_run.add_argument("--general-file", default=None, help="Inject general SCSS (skip git)")
    p_run.add_argument("--url", default=None, help="Paper daemon URL override")
    p_run.add_argument("--no-apply", action="store_true", help="Diff + report only")

    p_bd = sub.add_parser("build-desired", help="Build the desired set from source files.")
    p_bd.add_argument("--token-file", required=True)
    p_bd.add_argument("--general-file", required=True)

    p_diff = sub.add_parser("diff", help="Pure diff of desired vs live JSON files.")
    p_diff.add_argument("--desired", required=True)
    p_diff.add_argument("--live", required=True)

    p_sim = sub.add_parser("simulate-apply", help="Pure in-memory apply of a diff to a live state.")
    p_sim.add_argument("--live", required=True)
    p_sim.add_argument("--diff", required=True)

    args = parser.parse_args(argv)
    cmd = args.cmd or "run"

    if cmd == "run":
        # `run` is also the bare-invocation default.
        cfg = getattr(args, "config", DEFAULT_CONFIG)
        token_text = None
        general_text = None
        if getattr(args, "token_file", None):
            with open(args.token_file, encoding="utf-8") as fh:
                token_text = fh.read()
        if getattr(args, "general_file", None):
            with open(args.general_file, encoding="utf-8") as fh:
                general_text = fh.read()
        report, code = run(
            config_path=cfg,
            repo=getattr(args, "repo", DEFAULT_REPO),
            ref=getattr(args, "ref", DEFAULT_REF),
            token_path=getattr(args, "token_path", DEFAULT_TOKEN_PATH),
            general_path=getattr(args, "general_path", DEFAULT_GENERAL_PATH),
            token_text=token_text,
            general_text=general_text,
            url=getattr(args, "url", None),
            apply=not getattr(args, "no_apply", False),
        )
        print(json.dumps(report, indent=2))
        if report.get("refused"):
            _log(report.get("error", "refused"))
        return code

    if cmd == "build-desired":
        with open(args.token_file, encoding="utf-8") as fh:
            token_text = fh.read()
        with open(args.general_file, encoding="utf-8") as fh:
            general_text = fh.read()
        desired, declined = desired_from_source(token_text, general_text)
        print(json.dumps({"desired": desired, "declined": declined}, indent=2))
        return EXIT_OK

    if cmd == "diff":
        desired = _load_json_file(args.desired)
        if isinstance(desired, dict):  # accept a build-desired envelope too
            desired = desired["desired"]
        live = _load_json_file(args.live)
        if isinstance(live, dict):  # accept a get_tokens result envelope too
            live = live.get("tokens", live.get("result", {}).get("tokens", []))
        print(json.dumps(diff_tokens(desired, live), indent=2))
        return EXIT_OK

    if cmd == "simulate-apply":
        live = _load_json_file(args.live)
        if isinstance(live, dict):
            live = live.get("tokens", live.get("result", {}).get("tokens", []))
        diff = _load_json_file(args.diff)
        print(json.dumps(simulate_apply(live, diff), indent=2))
        return EXIT_OK

    parser.print_usage(sys.stderr)
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main())
