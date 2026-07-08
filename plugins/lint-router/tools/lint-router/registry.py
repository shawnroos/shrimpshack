#!/usr/bin/env python3
"""lint-router registry — the single validated reader/writer/matcher for routes.json.

routes.json is an ORDERED list of profiles; the FIRST profile whose `when` holds
wins (order == precedence, KTD-1). A profile bundles linters; each linter self-gates
so "run nothing" (today's skip) emerges naturally when no linter applies (KTD-2).

Predicate grammar (a `when` is one predicate; predicates nest):
  {"default": true}                      -> always matches (the catch-all; put last)
  {"origin": "<glob>"}                   -> fnmatch on `git remote get-url origin`
  {"has_file": {"path": "...", "contains": "..."}}  -> file exists (+ optional grep)
  {"path": "<glob>"}                     -> fnmatch on the repo root path
  {"all": [<pred>, ...]}                 -> every sub-predicate holds (AND)
  {"any": [<pred>, ...]}                 -> some sub-predicate holds (OR)
  bare keys (origin/has_file/path together) -> AND of each

Linter shape: {linter, mode: overlay|standalone, config, files, requires_file?}.
An overlay linter applies only when its `requires_file` (the repo's own base config
it layers on) is present; a standalone linter always applies (runtime file-glob
filtering happens in run.sh, not here).

Commands (all writes validate + are atomic-ish):
  match <repo-root>              -> {"profile","matched_by","linters":[applicable...]}  (exit 3 if none)
  list                          -> the raw profile array
  add-profile <json> [--at N]   -> insert a profile (default: before the trailing default, else end)
  add-linter <profile> <json>   -> append a linter to a profile
  remove <profile>[.<linter>]   -> drop a linter, or a whole profile
Registry path: $LINT_ROUTER_STATE_DIR/routes.json (default ${XDG_STATE_HOME:-~/.claude/state}/lint-router).
"""
from __future__ import annotations
import fnmatch
import json
import os
import subprocess
import sys


def state_dir() -> str:
    d = os.environ.get("LINT_ROUTER_STATE_DIR")
    if d:
        return d
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".claude", "state")
    return os.path.join(base, "lint-router")


def routes_path() -> str:
    return os.path.join(state_dir(), "routes.json")


def _die(msg: str, code: int = 2):
    sys.stderr.write(f"registry: {msg}\n")
    sys.exit(code)


def load_routes() -> list:
    p = routes_path()
    if not os.path.exists(p):
        _die(f"no registry at {p} (run --setup-only to seed it)", 2)
    try:
        with open(p) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        _die(f"malformed routes.json ({e})", 2)
    if not isinstance(data, list):
        _die("routes.json must be a JSON array of profiles", 2)
    for prof in data:
        if not isinstance(prof, dict) or "name" not in prof or "when" not in prof:
            _die("every profile needs a name and a when", 2)
        prof.setdefault("linters", [])
    return data


def save_routes(data: list):
    p = routes_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, p)


def _git_origin(repo: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", repo, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return ""


def _pred_holds(pred: dict, repo: str) -> bool:
    if not isinstance(pred, dict):
        return False
    if pred.get("default") is True:
        return True
    if "any" in pred:
        return any(_pred_holds(p, repo) for p in pred["any"])
    if "all" in pred:
        return all(_pred_holds(p, repo) for p in pred["all"])
    ok = True  # bare keys are ANDed; empty pred never matches
    seen = False
    if "origin" in pred:
        seen = True
        ok = ok and fnmatch.fnmatch(_git_origin(repo), pred["origin"])
    if "path" in pred:
        seen = True
        ok = ok and fnmatch.fnmatch(os.path.abspath(repo), pred["path"])
    if "has_file" in pred:
        seen = True
        hf = pred["has_file"]
        fp = os.path.join(repo, hf["path"]) if isinstance(hf, dict) else os.path.join(repo, hf)
        exists = os.path.isfile(fp)
        if exists and isinstance(hf, dict) and hf.get("contains"):
            try:
                with open(fp) as f:
                    exists = hf["contains"] in f.read()
            except OSError:
                exists = False
        ok = ok and exists
    return ok and seen


def _linter_applies(linter: dict, repo: str) -> bool:
    if linter.get("mode") == "overlay":
        req = linter.get("requires_file")
        if req:
            return os.path.isfile(os.path.join(repo, req))
        return True
    return True  # standalone: always applies (runtime file-glob filters files)


def cmd_match(repo: str):
    routes = load_routes()
    for prof in routes:
        if _pred_holds(prof["when"], repo):
            applicable = [ln for ln in prof.get("linters", []) if _linter_applies(ln, repo)]
            out = {"profile": prof["name"], "matched_by": prof["when"], "linters": applicable}
            json.dump(out, sys.stdout)
            sys.stdout.write("\n")
            sys.exit(0 if applicable else 3)  # exit 3 = matched but nothing to run (skip)
    _die("no profile matched (registry has no default catch-all?)", 4)


def cmd_explain(repo: str):
    """Dry-run: which profile matches, why, and each linter's applicability (+ why not)."""
    routes = load_routes()
    for prof in routes:
        if _pred_holds(prof["when"], repo):
            linters = []
            for ln in prof.get("linters", []):
                applies = _linter_applies(ln, repo)
                reason = "applicable"
                if not applies and ln.get("mode") == "overlay":
                    reason = f"overlay base config {ln.get('requires_file')!r} not present"
                linters.append({**ln, "applies": applies, "reason": reason})
            out = {"profile": prof["name"], "matched_by": prof["when"], "linters": linters}
            json.dump(out, sys.stdout)
            sys.stdout.write("\n")
            return
    _die("no profile matched", 4)


def _find_profile(routes: list, name: str) -> dict:
    for p in routes:
        if p.get("name") == name:
            return p
    _die(f"no profile named {name!r}", 2)


def cmd_list():
    json.dump(load_routes(), sys.stdout, indent=2)
    sys.stdout.write("\n")


def _parse_json_arg(s: str) -> dict:
    try:
        v = json.loads(s)
    except json.JSONDecodeError as e:
        _die(f"invalid JSON argument ({e})", 2)
    if not isinstance(v, dict):
        _die("expected a JSON object", 2)
    return v


def cmd_add_profile(argv: list):
    prof = _parse_json_arg(argv[0])
    if "name" not in prof or "when" not in prof:
        _die("a profile needs name and when", 2)
    prof.setdefault("linters", [])
    routes = load_routes()
    if any(p.get("name") == prof["name"] for p in routes):
        _die(f"profile {prof['name']!r} already exists", 2)
    at = None
    if "--at" in argv:
        at = int(argv[argv.index("--at") + 1])
    if at is None:
        # insert before a trailing default catch-all so the new profile can win
        at = len(routes)
        for i, p in enumerate(routes):
            if p.get("when", {}).get("default") is True:
                at = i
                break
    routes.insert(at, prof)
    save_routes(routes)
    sys.stdout.write(f"added profile {prof['name']} at index {at}\n")


def cmd_add_linter(argv: list):
    name, linter = argv[0], _parse_json_arg(argv[1])
    if "linter" not in linter or "mode" not in linter:
        _die("a linter needs at least linter and mode", 2)
    routes = load_routes()
    _find_profile(routes, name).setdefault("linters", []).append(linter)
    save_routes(routes)
    sys.stdout.write(f"added linter {linter['linter']} to {name}\n")


def cmd_remove(target: str):
    routes = load_routes()
    if "." in target:
        pname, lname = target.split(".", 1)
        prof = _find_profile(routes, pname)
        before = len(prof.get("linters", []))
        prof["linters"] = [ln for ln in prof.get("linters", []) if ln.get("linter") != lname]
        if len(prof["linters"]) == before:
            _die(f"no linter {lname!r} in {pname}", 2)
    else:
        if not any(p.get("name") == target for p in routes):
            _die(f"no profile named {target!r}", 2)
        routes = [p for p in routes if p.get("name") != target]
    save_routes(routes)
    sys.stdout.write(f"removed {target}\n")


def main(argv: list) -> int:
    if not argv:
        _die("usage: registry <match|list|add-profile|add-linter|remove> ...", 2)
    cmd, rest = argv[0], argv[1:]
    if cmd == "match":
        if not rest:
            _die("match needs a repo root", 2)
        cmd_match(rest[0])
    elif cmd == "explain":
        if not rest:
            _die("explain needs a repo root", 2)
        cmd_explain(rest[0])
    elif cmd == "list":
        cmd_list()
    elif cmd == "add-profile":
        cmd_add_profile(rest)
    elif cmd == "add-linter":
        cmd_add_linter(rest)
    elif cmd == "remove":
        if not rest:
            _die("remove needs <profile>[.<linter>]", 2)
        cmd_remove(rest[0])
    else:
        _die(f"unknown command {cmd!r}", 2)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
