#!/usr/bin/env python3
"""reflect scoped-memory CLI (plan 003 U5) — agent-callable + operator tools.

Subcommands (all operate on the canonical store; --store or $REFLECT_MEMORY_DIR
overrides; default is the $HOME-derived store):

  recall  [--query Q] [--cwd D]   active scoped recall (walk-up boost), on demand
  save    --scope S "<body>" [--name N]   save a memory at an explicit scope
  promote <file>                  re-scope a memory to global (repo -> flat root)
  rescope <file> <scope>          move a memory to scope S (repo:<slug> | global)
  list    [--here|--scope S|--cross-repo]   inspect what's stored at a scope

Scope S is `global` or `repo:<slug>` or `repo:.` (current repo from --cwd). Files
live flat (global) or under `_scope/<slug>/`. Re-scoping is a file move + a frontmatter
`scope:` update. Shares scope.py so behavior matches the recall hook.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scope as _scope  # noqa: E402


def store_dir():
    d = os.environ.get("REFLECT_MEMORY_DIR")
    if d:
        return d
    home = os.environ.get("HOME", "")
    slug = _scope.slugify(home) if home else "-root"
    return os.path.join(home, ".claude", "projects", slug, "memory")


def _resolve_scope(s, cwd):
    """'global' -> 'global'; 'repo:.' -> current repo slug; 'repo:<slug>' -> <slug>."""
    if s in (None, "", "global"):
        return "global"
    if s == "repo:.":
        return _scope.resolve_repo_slug(cwd or os.getcwd())
    if s.startswith("repo:"):
        return s[len("repo:"):]
    return s


def _path_for(store, scope_slug, filename):
    if scope_slug == "global":
        return os.path.join(store, filename)
    return os.path.join(store, "_scope", scope_slug, filename)


def _scope_of_path(store, path):
    """Reverse of _path_for: the scope slug a stored file currently lives at."""
    rel = os.path.relpath(path, store)
    parts = rel.split(os.sep)
    if len(parts) >= 3 and parts[0] == "_scope":
        return parts[1]
    return "global"


def _scope_val(scope_slug):
    return "global" if scope_slug == "global" else "repo:" + scope_slug


def cmd_save(args):
    store = store_dir()
    scope_slug = _resolve_scope(_opt(args, "--scope"), _opt(args, "--cwd"))
    name = _opt(args, "--name") or "memory"
    body = _positional(args)
    if not body:
        sys.stderr.write("save: needs a body\n"); return 2
    fn = "".join(c if c.isalnum() or c in "-_" else "-" for c in name.lower())[:60] + ".md"
    dest = _path_for(store, scope_slug, fn)
    text = _scope.set_scope("---\nname: %s\n---\n%s\n" % (name, body), _scope_val(scope_slug))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest, "w", encoding="utf-8").write(text)
    print("saved %s (scope: %s)" % (dest, scope_slug))
    return 0


def _move(store, src, new_scope):
    """Move a body to `new_scope`, atomically, never clobbering a different file."""
    text = _scope.set_scope(open(src, encoding="utf-8", errors="replace").read(),
                            _scope_val(new_scope))
    dest = _path_for(store, new_scope, os.path.basename(src))
    if os.path.abspath(dest) == os.path.abspath(src):
        open(src, "w", encoding="utf-8").write(text)   # same path, just update frontmatter
        return dest
    if os.path.exists(dest):
        raise FileExistsError("a memory named %s already exists at %s"
                              % (os.path.basename(src), new_scope))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, dest)
    os.remove(src)
    return dest


def cmd_rescope(args, to=None):
    store = store_dir()
    pos = _positional_list(args)
    if not pos:
        sys.stderr.write("rescope: needs <file> [<scope>]\n"); return 2
    src = pos[0] if os.path.isabs(pos[0]) else os.path.join(store, pos[0])
    if not os.path.exists(src):
        matches = _find_by_name(store, os.path.basename(pos[0]))
        if len(matches) > 1:
            sys.stderr.write("rescope: %r is ambiguous — give a relative path:\n  %s\n"
                             % (pos[0], "\n  ".join(os.path.relpath(m, store) for m in matches)))
            return 2
        src = matches[0] if matches else src
    if not os.path.exists(src):
        sys.stderr.write("rescope: not found: %s\n" % pos[0]); return 2
    new_scope = to if to is not None else _resolve_scope(pos[1] if len(pos) > 1 else "global",
                                                         _opt(args, "--cwd"))
    cur = _scope_of_path(store, src)
    if cur == new_scope:
        print("noop (already %s): %s" % (new_scope, os.path.basename(src))); return 0
    try:
        _move(store, src, new_scope)
    except (OSError, FileExistsError) as e:
        sys.stderr.write("rescope: %s\n" % e); return 2
    print("rescoped %s: %s -> %s" % (os.path.basename(src), cur, new_scope))
    return 0


def _find_by_name(store, name):
    """All stored paths with this basename (so an ambiguous bare name can error)."""
    return [os.path.join(root, name) for root, _d, files in os.walk(store) if name in files]


def cmd_list(args):
    store = store_dir()
    if "--here" in args:
        scope_slug = _scope.resolve_repo_slug(_opt(args, "--cwd") or os.getcwd())
    elif _opt(args, "--scope"):
        scope_slug = _resolve_scope(_opt(args, "--scope"), _opt(args, "--cwd"))
    else:
        scope_slug = None  # all
    rows = []
    for root, _d, files in os.walk(store):
        for fn in files:
            if not fn.endswith(".md") or fn == "MEMORY.md":
                continue
            p = os.path.join(root, fn)
            sc = _scope_of_path(store, p)
            if scope_slug is None or sc == scope_slug:
                rows.append((sc, fn))
    for sc, fn in sorted(rows):
        print("%-40s %s" % (sc, fn))
    print("(%d memories%s)" % (len(rows), "" if scope_slug is None else " at %s" % scope_slug))
    return 0


def cmd_recall(args):
    """Active scoped recall — shells qmd, then applies the shared select_scoped."""
    import json, subprocess
    q = _opt(args, "--query") or _positional(args)
    cwd = _opt(args, "--cwd") or os.getcwd()
    collection = os.environ.get("SEEDED_RECALL_COLLECTION", "claude-memory")
    try:
        r = subprocess.run(["qmd", "search", "-c", collection, "--format", "json", "--", q or ""],
                           capture_output=True, text=True, timeout=8)
        results = json.loads(r.stdout) if r.returncode == 0 else []
    except Exception:
        results = []
    if not isinstance(results, list):
        results = []
    cur = _scope.resolve_repo_slug(cwd)
    def _f(name):
        try:
            v = os.environ.get(name)
            return float(v) if v else None
        except ValueError:
            return None
    gmin, floor = _f("SEEDED_RECALL_MIN_SCORE"), _f("SEEDED_RECALL_REPO_MIN_SCORE")
    try:
        k = max(1, int(os.environ.get("SEEDED_RECALL_K", "3")))
    except ValueError:
        k = 3
    cands = [x for x in results if isinstance(x, dict) and x.get("file")]
    if gmin is not None:  # mirror the hook's global floor (seeded-recall.sh) so the
        cands = [x for x in cands  # CLI preview matches live recall when it's set
                 if isinstance(x.get("score"), (int, float)) and x["score"] >= gmin]
    sel = _scope.select_scoped(cands, cur, k, floor)
    for x in sel:
        print("%s  (%s)" % (x.get("title") or x.get("file"), _scope.scope_of_qmd_file(x.get("file"))))
    if not sel:
        print("(no memories)")
    return 0


# --- tiny arg helpers (no argparse: keep it shell-friendly) ---
def _opt(args, flag):
    if flag in args:
        i = args.index(flag)
        if i + 1 < len(args):
            return args[i + 1]
    return None


def _positional(args):
    flags = {"--scope", "--name", "--cwd", "--query"}
    out = []
    skip = False
    for i, a in enumerate(args):
        if skip:
            skip = False; continue
        if a in flags:
            skip = True; continue
        if a.startswith("--"):
            continue
        out.append(a)
    return out[0] if out else None


def _positional_list(args):
    flags = {"--scope", "--name", "--cwd", "--query"}
    out, skip = [], False
    for a in args:
        if skip:
            skip = False; continue
        if a in flags:
            skip = True; continue
        if a.startswith("--"):
            continue
        out.append(a)
    return out


def main(argv):
    if not argv:
        sys.stderr.write(__doc__); return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "save":
        return cmd_save(rest)
    if cmd == "promote":
        return cmd_rescope(rest, to="global")
    if cmd == "rescope":
        return cmd_rescope(rest)
    if cmd == "list":
        return cmd_list(rest)
    if cmd == "recall":
        return cmd_recall(rest)
    sys.stderr.write("unknown subcommand: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
