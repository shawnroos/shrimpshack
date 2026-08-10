#!/usr/bin/env python3
"""reflect scoped-memory CLI (plan 003 U5) — agent-callable + operator tools.

Subcommands (all operate on the canonical store; --store or $REFLECT_MEMORY_DIR
overrides; default is the $HOME-derived store):

  recall  [--query Q] [--cwd D] [--store D] [--here] [--deliberate]
                                  THE mid-session recall call: declared triggers,
                                  then qmd vsearch, then the local BM25 index —
                                  with bodies and an always-printed status line
  save    --scope S "<body>" [--name N]   save a memory at an explicit scope
  promote <file>                  re-scope a memory to global (repo -> flat root)
  rescope <file> <scope>          move a memory to scope S (repo:<slug> | global)
  list    [--here|--scope S|--cross-repo]   inspect what's stored at a scope

Scope S is `global` or `repo:<slug>` or `repo:.` (current repo from --cwd). Files
live flat (global) or under `_scope/<slug>/`. Re-scoping is a file move + a frontmatter
`scope:` update. Shares scope.py so behavior matches the recall hook.

`recall` flags:
  --query Q      what to search for (a bare positional works too)
  --cwd D        directory whose git root decides the current repo scope
  --store D      memory store to search (default $REFLECT_MEMORY_DIR / $HOME-derived)
  --here         repo-scoped recall: this repo's memories plus ancestor/global ones,
                 never a sibling repo's; says so when you are not in a repo
  --deliberate   a human explicitly asked — widen K and relax the local confidence
                 gate (the ambient path stays quiet; this one is allowed to guess).
                 It does NOT bypass an armed qmd cooldown: re-probing a wedged qmd
                 is exactly what the shared health stamp exists to prevent.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scope as _scope  # noqa: E402

# Retrieval layers. Every import is fail-open: a missing or broken layer costs its
# own results and a named line in the status output, never a traceback — recall is
# a help, and a help that can crash the caller is not one.
try:
    import retrieval as _retrieval
except Exception:                                  # pragma: no cover
    _retrieval = None
try:
    import local_index as _local
except Exception:                                  # pragma: no cover
    _local = None
try:
    import triggers as _triggers
except Exception:                                  # pragma: no cover
    _triggers = None
try:
    import telemetry as _telemetry
except Exception:                                  # pragma: no cover
    _telemetry = None


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


#: Deliberate mode. `/memories` and `/reflect regroup` mean "a human just asked" —
#: the calculus that makes the ambient path prefer silence (a wrong memory costs
#: more than no memory) is inverted when someone is sitting there waiting for an
#: answer, so K widens and the local gate relaxes. Relaxation is expressed ONLY as
#: parameters the layers already take: nothing here re-implements a gate.
DELIBERATE_K = 8
DELIBERATE_COVERAGE_FACTOR = 0.5   # deliberate HALVES the relevance bar: a human
                                   # asked, so a marginal hit costs them one line to
                                   # read and discard, while silence costs the memory
DELIBERATE_RATIO = 1.0             # separation off — 1.0 is "top1 >= top2", always true
DELIBERATE_MIN_BUDGET = 12.0       # a person is waiting; give qmd longer than a hook does


def _safe(s):
    """Neutralize a literal closing tag so a memory body can't break out of the
    wrapper a caller may inject it into — same trick, same reason, as the hook
    (`hooks/seeded-recall.sh`): a zero-width space after `<` kills the literal tag
    while staying visually identical."""
    return (s or "").replace("</recalled-memories>", "<​/recalled-memories>")


def _read_body(store, relpath, max_body):
    """A stored body, truncated to the hook's max-body convention. None if
    unreadable — a body we cannot read is simply not surfaced."""
    try:
        with open(os.path.join(store, relpath), encoding="utf-8",
                  errors="replace") as fh:
            text = fh.read().strip()
    except OSError:
        return None
    if len(text) > max_body:
        text = text[:max_body].rstrip() + "\n…(truncated)"
    return text


def _mem_name(relpath):
    """Display/telemetry name for a body: its filename stem. Bodies are identified
    by store-relative path, but the use and recall logs record a name."""
    base = os.path.basename(relpath or "")
    return base[:-3] if base.endswith(".md") else base


def cmd_recall(args):
    """The one mid-session recall call (plan U2, KTD8).

    Three layers, in this order, because each is cheaper and more precise than the
    one after it:

      1. DECLARED TRIGGERS — a memory that named this situation itself. Milliseconds,
         no ranking, no qmd. A trigger match is surfaced FIRST and marked, whatever
         a ranker would have thought of it: the memory's author already answered the
         relevance question.
      2. QMD VSEARCH — semantic, via the shared `retrieval` engine, so this path and
         the session-start hook run the same subcommand, the same wall budget, the
         same activation floor, the same `select_scoped`, and the same cooldown
         stamp. `vsearch`, never `search`: the plugin's own spike measured recall@3
         at 0.75 vector vs 0.25 BM25, and the CLI used to be on the wrong one.
      3. LOCAL BM25 INDEX — qmd-free, always available, used when qmd is skipped
         (armed cooldown), unavailable, or answered with nothing.

    An armed cooldown SKIPS layer 2 outright rather than re-probing: a wedged qmd
    costs its full budget per call, and paying that on every deliberate recall is
    the tax the shared health state exists to stop. The reason is printed, not
    swallowed — a silent degradation is indistinguishable from "nothing matched",
    which is the failure this whole plan exists to remove.

    Always exits 0 for a retrieval outcome, including "nothing confident matched"
    (fail-open): recall is a help, and a help must not fail a caller's pipeline.
    """
    store = _opt(args, "--store") or store_dir()
    cwd = _opt(args, "--cwd") or os.getcwd()
    q = (_opt(args, "--query") or _positional(args) or "").strip()
    here = "--here" in args
    deliberate = "--deliberate" in args
    recall_log = os.path.join(store, "RECALL.log")

    if not q:
        sys.stderr.write("recall: needs a query (--query Q, or a bare argument)\n")
        return 2

    cur = _scope.GLOBAL
    try:
        cur = _scope.resolve_repo_slug(cwd)
    except Exception:
        pass

    max_body = 1200
    k = 3
    if _retrieval is not None:
        try:
            probe = _retrieval.Config()
            max_body, k = probe.max_body, probe.k
        except Exception:
            pass
    if deliberate:
        k = max(k, DELIBERATE_K)

    items = []          # [(name, relpath_or_pointer, scope_label, layer, body)]
    seen = set()
    notes = []          # status-line fragments, in layer order

    def add(name, pointer, layer, body):
        if not body or name in seen:
            return
        # `--here` is repo-scoped recall: this repo's own memories and its
        # ancestors' (global included), never a sibling repo's. Each layer already
        # scopes its own results; this is the flag making that guarantee explicit
        # at the one place the user asked for it.
        if here:
            try:
                if _scope.classify(pointer, cur) == "sibling":
                    return
            except Exception:
                pass
        seen.add(name)
        items.append((name, pointer, _scope.scope_of_qmd_file(pointer), layer, body))

    # ---- layer 1: declared triggers -----------------------------------------
    if _triggers is not None:
        try:
            manifest = _triggers.load_manifest(store)
            hits, timeouts = _triggers.match(manifest, q, cwd=cwd)
            for memory, src in timeouts:
                sys.stderr.write("recall: %s — trigger pattern exceeded its "
                                 "evaluation bound, skipped: %s\n"
                                 % (memory, (src or "")[:80]))
            for entry in hits:
                rel = entry.get("path", "")
                add(entry.get("memory") or _mem_name(rel), rel, "trigger",
                    _read_body(store, rel, max_body))
            if hits:
                notes.append("%d declared trigger match%s"
                             % (len(hits), "" if len(hits) == 1 else "es"))
        except Exception:
            notes.append("trigger layer errored (skipped)")

    # ---- layer 2: qmd vsearch, under the shared budget and health state ------
    qmd_status = "no-engine"
    if _retrieval is not None:
        try:
            cfg = _retrieval.Config(source="cli", memory_dir=store, k=k)
            if deliberate:
                cfg.budget = max(cfg.budget, DELIBERATE_MIN_BUDGET)
            # Budget asymmetry (retrieval.py decision 2): honoring the shared stamp
            # is unconditional, but this path may only ARM it if it waited at least
            # as long as session-start recall would have. Without this, a deliberate
            # call with a long budget and a hook budget pinned short would black out
            # every session's recall for the whole TTL.
            cfg.stamp_min_budget = _retrieval._f("SEEDED_RECALL_TIMEOUT",
                                                 _retrieval.DEFAULT_BUDGET)
            # `recall()` reads the shared cooldown stamp itself and returns
            # "cooldown" WITHOUT calling qmd — that is the skip, and it stamps
            # failures through the one health signal the hook uses. Nothing here
            # reads or writes the stamp directly; a second stamping path is exactly
            # the drift KTD8 ends.
            res = _retrieval.recall(q, config=cfg, cwd=cwd)
            qmd_status = res.status
            for it in res.items:
                add(_mem_name(it.pointer), it.pointer, "qmd", it.body)
            if res.status == "ok":
                notes.append("qmd vsearch answered")
                if res.pending_embeddings:
                    notes.append("qmd index has pending embeddings — recall may be "
                                 "incomplete (run `qmd embed -c %s`)" % cfg.collection)
            elif res.status == "cooldown":
                notes.append("qmd SKIPPED: the shared failure cooldown is armed "
                             "(a recent probe hung or failed) — not re-probing")
            elif res.status == "unavailable":
                notes.append("qmd unavailable (missing, timed out, or failed)")
            else:
                notes.append("qmd returned nothing (%s)" % res.status)
        except Exception:
            qmd_status = "error"
            notes.append("qmd layer errored")
    else:
        notes.append("qmd layer unavailable (retrieval module not importable)")

    # ---- layer 3: local BM25 index ------------------------------------------
    # Runs whenever qmd did not answer. It is the always-available layer: no
    # subprocess, no network, ~1ms after the build, and correct on a memory saved
    # ten seconds ago.
    local_used = False
    if qmd_status != "ok" and _local is not None:
        local_used = True
        try:
            min_score = min_ratio = None
            if deliberate:
                # Relax the condition the gate ACTUALLY uses. The shipped relevance
                # test is coverage, so halving a raw-score floor here relaxed nothing
                # — it silently pinned an absolute floor instead, and pinning is
                # stricter than the default path, not looser.
                os.environ["MEMORY_LOCAL_MIN_COVERAGE"] = str(
                    _local.DEFAULT_MIN_COVERAGE * DELIBERATE_COVERAGE_FACTOR)
                min_ratio = DELIBERATE_RATIO
            try:
                lres = _local.search(store, q, cwd=cwd, k=k,
                                     min_score=min_score, min_ratio=min_ratio)
            finally:
                if deliberate:
                    os.environ.pop("MEMORY_LOCAL_MIN_COVERAGE", None)
            for h in lres.hits:
                rel = h.get("file", "")
                # "local-fallback", matching retrieval.RecallItem.source. RECALL.log
                # is ONE shared log written by the hook and the CLI both, so a second
                # token for the same layer silently splits it into two buckets for any
                # consumer that groups by layer — which is the measurement split's
                # whole purpose (KTD9).
                add(_mem_name(rel), rel, "local-fallback", _read_body(store, rel, max_body))
            notes.append("local index: %s (%s)" % (lres.status, lres.reason))
        except Exception:
            notes.append("local index errored")

    # ---- output --------------------------------------------------------------
    for name, _pointer, scope_label, layer, body in items:
        label = "declared trigger" if layer == "trigger" else layer
        print("### %s  [scope: %s]  [via: %s]" % (_safe(name), scope_label, label))
        print(_safe(body))
        print()
        if _telemetry is not None:
            try:
                _telemetry.append_recall(recall_log, name, "cli", layer)
            except Exception:
                pass

    scope_note = ("repo-scoped to %s" % cur) if here else None
    if here and cur == _scope.GLOBAL:
        scope_note = "--here asked for repo scope, but %s is not inside a git repo" % cwd
    if scope_note:
        notes.append(scope_note)
    if deliberate:
        notes.append("deliberate mode (K=%d, relaxed local gate)" % k)

    if items:
        answered = "declared triggers" if items[0][3] == "trigger" else (
            "qmd" if qmd_status == "ok" else "the local index")
        print("recall: %d memor%s surfaced — answered by %s. %s"
              % (len(items), "y" if len(items) == 1 else "ies", answered,
                 "; ".join(notes)))
    else:
        print("recall: no confident match. %s" % "; ".join(notes))
        hint = ("Try a different phrasing, or `--deliberate` to widen the search "
                "and relax the confidence gate")
        if not here:
            hint += ", or `--here` to scope it to this repo"
        if local_used:
            hint += ". Nothing was suppressed silently — the reasons above are the "\
                    "whole story"
        print("recall: %s." % hint)
    return 0


# --- tiny arg helpers (no argparse: keep it shell-friendly) ---
#: Flags that CONSUME the next argument. A value-taking flag missing from this set
#: has its value read as a positional — which is how `recall --store /x "query"`
#: would end up searching for `/x`. Valueless flags (`--here`, `--deliberate`) need
#: no entry: the generic `--` skip below covers them.
_VALUE_FLAGS = {"--scope", "--name", "--cwd", "--query", "--store"}


def _opt(args, flag):
    if flag in args:
        i = args.index(flag)
        if i + 1 < len(args):
            return args[i + 1]
    return None


def _positional(args):
    out = _positional_list(args)
    return out[0] if out else None


def _positional_list(args):
    out, skip = [], False
    for a in args:
        if skip:
            skip = False; continue
        if a in _VALUE_FLAGS:
            skip = True; continue
        if a.startswith("--"):
            continue
        out.append(a)
    return out


def main(argv):
    if not argv:
        sys.stderr.write(__doc__); return 2
    cmd, rest = argv[0], argv[1:]
    if cmd in ("-h", "--help", "help"):
        sys.stdout.write(__doc__); return 0
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
