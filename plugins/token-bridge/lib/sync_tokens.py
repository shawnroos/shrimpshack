#!/usr/bin/env python3
"""Idempotent token-sync — reconcile a codebase's CSS tokens into a Paper file.

This is token-bridge's code -> Paper command. It reads the CSS source declared
by the target codebase's config, parses + classifies it (via the sibling lib
modules), builds the *desired* Paper token set, diffs it against the *live*
Paper file, and applies the minimal reconcile (create / update / delete /
recreate). Re-run against an unchanged source, it writes nothing (R3).

The source, custom-property prefix, and theme conventions all come from the
config found under `--repo <path>` (paper_client.read_config) — nothing about a
particular codebase is hardcoded here.

--------------------------------------------------------------------------------
LIGHT / DARK NAMING SCHEME (KTD2 — frozen)
--------------------------------------------------------------------------------
Paper has no per-file "theme mode" for tokens, so v1's base + one "dark" theme
are written as two *separately named* Paper tokens rather than two modes of one
token:

  * The BASE (light) value keeps the token's own name:   --accent
  * The DARK value gets a "-dark" suffixed twin:          --accent-dark

Only theme-VARYING tokens (parse_tokens gives them a non-null `dark`) get a dark
twin. Mode-invariant tokens (dark == null) are written exactly once, under their
own name, with no twin.

Aliases follow the same scheme *within their theme* (R2 + R3):
  * A LIGHT alias references the plain (light) name:   var(--green-500)
  * A DARK alias references the DARK counterpart —      var(--accent-dark)
    but ONLY when that referent is itself theme-varying (and therefore has a
    "-dark" twin). If the referent is mode-invariant it has no twin, so the dark
    alias references its plain name.

Worked example:
    --nav-active-fg        = var(--accent)        # light twin
    --nav-active-fg-dark   = var(--accent-dark)   # dark twin,
                                                  # NOT var(--accent)

Tier-2 aliases are written as var(--*) references, never resolved to their
literal hex (R2) — parse_tokens' light_alias/dark_alias metadata drives this.

--------------------------------------------------------------------------------
Architecture
--------------------------------------------------------------------------------
The DIFF ENGINE is a pure function (desired, live) -> {creates, updates, deletes,
recreates} with no config and no daemon, so it is unit-testable against fixtures.
Only apply_diff() touches the live daemon. build_desired() is likewise pure over
classified records. Reading the source (parse_tokens.load_source) is the only
file/git-touching step, and it is driven entirely by the config.

CLI:
  python3 sync_tokens.py run --repo PATH        # full pipeline (config + daemon)
  python3 sync_tokens.py build-desired --source-file F --conventions JSON [--prefix P]
  python3 sync_tokens.py diff --desired D --live L
  python3 sync_tokens.py simulate-apply --live L --diff D
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

# Sibling lib modules — READ/import only (never modified by this unit).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import classify_tokens  # noqa: E402
import map_to_tokens  # noqa: E402
import parse_tokens  # noqa: E402
from paper_client import PaperClient, read_config  # noqa: E402

# --- configuration -----------------------------------------------------------

DARK_SUFFIX = "-dark"

# Exit codes — distinct so callers/tests can tell failure kinds apart.
EXIT_OK = 0
EXIT_REFUSED = 2  # safety guard: no fileId / no config / bad config
EXIT_ERROR = 4  # source read / daemon / apply failure


def _log(msg: str) -> None:
    print(f"[sync_tokens] {msg}", file=sys.stderr)


# --- value normalization (shared by build + diff, for idempotency) -----------


def _norm_value(v):
    """Normalize a token value for comparison: strip, then uppercase every hex
    run via parse_tokens' own normalizer — one definition of "same value" feeds
    the diff whose emptiness is the R3 idempotency contract. Non-hex values
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
    --accent = var(--green-500)), and any alias chaining through it. Topological
    sort on the in-batch var() dependency; tokens with no in-batch referent keep
    their relative order and come first. Cycles are broken by emitting in
    encounter order."""
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
         e.g. --accent aliases a primitive in light but is a literal in dark).
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
        # light twin rather than send value:None to create_tokens.
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
    `0px` — so a raw string compare churns those tokens on every sync (R3). A
    var() alias has no color/length to canonicalize; it compares as a normalized
    string. map_to_tokens.normalize_value owns the canonical color/length form
    (shared with the harvest path)."""
    a = map_to_tokens.normalize_value(_norm_value(live_val))
    b = map_to_tokens.normalize_value(_norm_value(desired_val))
    return a == b


# --- the diff engine (PURE — no config, no daemon) ---------------------------


def _owns(name, owned_prefix):
    """Whether the plugin OWNS this live token name, and may therefore delete it
    when it's absent from the desired set.

    With a configured `owned_prefix`, ownership is scoped to that namespace: the
    source only defines prefixed tokens (and their `-dark` twins, which also
    start with the prefix), so a token outside it — a Paper-native `--color-*`,
    another team's prefix, a hand-authored token — is NOT ours to delete. With no
    prefix (source is "all custom properties"), the plugin owns the whole file
    and full reconcile applies."""
    if not owned_prefix:
        return True
    return _norm_name(name).startswith(_norm_name(owned_prefix))


def diff_tokens(desired, live, owned_prefix=None):
    """Diff the desired Paper token set against the live one (pure function).

    Compares with NORMALIZED name (lowercase) and value (uppercased hex) so an
    unchanged source yields an EMPTY diff (R3).

    `owned_prefix` scopes deletions: a live token absent from the desired set is
    deleted only when the plugin OWNS it (see `_owns`). This stops a prefixed
    sync from wiping Paper-native or other-namespace tokens that share the target
    file. Creates/updates/recreates are always driven by the desired set, so they
    are unaffected.

    Returns {creates, updates, deletes, recreates}:
      creates    tokens present in desired, absent from live         -> create
      updates    same name+type, value changed                       -> set value
      deletes    OWNED, present in live, absent from desired          -> delete
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
        if _norm_name(t["name"]) not in desired_names and _owns(t["name"], owned_prefix)
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


# --- desired-set construction from source text (pure) ------------------------


def desired_from_source(text, conventions, prefix=None):
    """Full pure source pipeline: parse -> classify -> build_desired.

    `conventions` is the config `themeConventions` list; `prefix` restricts
    output to custom properties with that prefix (None/"" takes all)."""
    records = parse_tokens.parse_tokens(text, conventions, prefix)
    classified = classify_tokens.classify_tokens(records)
    return build_desired(classified)


# --- top-level orchestration -------------------------------------------------


def run(repo=".", url=None, apply=True):
    """The end-to-end reconcile. Returns (report_dict, exit_code).

    Reads everything it needs (fileId, source, prefix, theme conventions, daemon
    URL) from the config found under `--repo`. Refuses (writes NOTHING) when the
    config is missing/invalid or carries no fileId — the destructive-reconcile
    safety guard. This runs BEFORE any source read or daemon call."""
    file_id, cfg, err = read_config(repo)
    if err is not None:
        # no_config / bad_config / no_target_file — all refuse before any write.
        return (
            {
                "ok": False,
                "refused": True,
                "error": err.get("error"),
                "note": err.get("note"),
            },
            EXIT_REFUSED,
        )

    # Source (config working-tree path by default; the git-ref mode when
    # source.ref is set — both handled inside parse_tokens.load_source).
    try:
        text = parse_tokens.load_source(cfg)
    except RuntimeError as exc:
        return ({"ok": False, "error": str(exc)}, EXIT_ERROR)

    conventions = cfg.get("themeConventions") or []
    prefix = (cfg.get("source") or {}).get("prefix")
    desired, declined = desired_from_source(text, conventions, prefix)

    # Live Paper tokens.
    client = PaperClient(url=url or cfg.get("paperDaemonUrl"))
    live_env = client.get_tokens(file_id)
    if not live_env.get("ok"):
        return (
            {"ok": False, "error": "get_tokens failed", "envelope": live_env},
            EXIT_ERROR,
        )
    live = live_env.get("result", {}).get("tokens", []) or []

    # Scope deletes to the owned prefix so a prefixed sync never wipes
    # Paper-native or other-namespace tokens sharing the target file.
    diff = diff_tokens(desired, live, owned_prefix=prefix)

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

    p_run = sub.add_parser("run", help="Full reconcile (config source + live daemon).")
    p_run.add_argument("--repo", default=".", help="Target codebase root holding token-bridge.config.json")
    p_run.add_argument("--url", default=None, help="Paper daemon URL override")
    p_run.add_argument("--no-apply", action="store_true", help="Diff + report only")

    p_bd = sub.add_parser("build-desired", help="Build the desired set from one CSS source + conventions.")
    p_bd.add_argument("--source-file", required=True, help="CSS/SCSS source file to parse")
    p_bd.add_argument("--conventions", required=True, help="JSON array of themeConventions")
    p_bd.add_argument("--prefix", default=None, help="Only include custom properties with this prefix")

    p_diff = sub.add_parser("diff", help="Pure diff of desired vs live JSON files.")
    p_diff.add_argument("--desired", required=True)
    p_diff.add_argument("--live", required=True)
    p_diff.add_argument("--owned-prefix", default=None,
                        help="Only delete live tokens with this prefix (plugin ownership scope)")

    p_sim = sub.add_parser("simulate-apply", help="Pure in-memory apply of a diff to a live state.")
    p_sim.add_argument("--live", required=True)
    p_sim.add_argument("--diff", required=True)

    args = parser.parse_args(argv)
    cmd = args.cmd or "run"

    if cmd == "run":
        # `run` is also the bare-invocation default.
        report, code = run(
            repo=getattr(args, "repo", "."),
            url=getattr(args, "url", None),
            apply=not getattr(args, "no_apply", False),
        )
        print(json.dumps(report, indent=2))
        if report.get("refused"):
            _log(report.get("note") or report.get("error", "refused"))
        return code

    if cmd == "build-desired":
        try:
            conventions = json.loads(args.conventions)
        except json.JSONDecodeError as exc:
            _log(f"--conventions is not valid JSON: {exc}")
            return EXIT_REFUSED
        if not isinstance(conventions, list):
            _log("--conventions must be a JSON array of convention objects")
            return EXIT_REFUSED
        with open(args.source_file, encoding="utf-8") as fh:
            text = fh.read()
        desired, declined = desired_from_source(text, conventions, args.prefix)
        print(json.dumps({"desired": desired, "declined": declined}, indent=2))
        return EXIT_OK

    if cmd == "diff":
        desired = _load_json_file(args.desired)
        if isinstance(desired, dict):  # accept a build-desired envelope too
            desired = desired["desired"]
        live = _load_json_file(args.live)
        if isinstance(live, dict):  # accept a get_tokens result envelope too
            live = live.get("tokens", live.get("result", {}).get("tokens", []))
        print(json.dumps(diff_tokens(desired, live, owned_prefix=args.owned_prefix), indent=2))
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
