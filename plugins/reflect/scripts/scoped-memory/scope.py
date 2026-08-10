#!/usr/bin/env python3
"""Scope resolver + qmd-path scope parser for repo-scoped memory (plan 003).

This is the shared module U1's pre-flight sim and U2/U4 import verbatim (plan 003
KTD1/KTD3, plan 002's anti-divergence discipline). It carries the two pieces the
recall match rests on:

  resolve_repo_slug(cwd)  -> the current repo's scope slug, or "global"
  scope_of_qmd_file(file) -> the scope slug encoded in a qmd search result's `file`
  scope_matches(file, slug) -> the F-A equality the K+1 boost depends on

The F-A gotcha (verified against real qmd output, plan 003 round 3): qmd rewrites
the `file` value of a `_scope/<slug>/x.md` body to
`qmd://<collection>/scope/<slug-without-leading-dash>/x.md` — it strips the leading
`_` from `_scope`, strips the leading `-` from the slug, and adds a `qmd://<coll>/`
prefix. The resolver, following reflect's `$HOME`-slug convention, emits the slug
*with* the leading `-`. So both sides MUST be normalized (drop the URI prefix, treat
`scope`/`_scope` as equal, strip leading `-`/`_` from the slug) before comparing, or
the match silently never fires and the boost never appears.
"""
import os
import subprocess

SCOPE_MARKERS = ("_scope", "scope")  # qmd strips the leading underscore
GLOBAL = "global"


def _run(args, cwd=None, timeout=5):
    try:
        out = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return out.stdout.strip() if out.returncode == 0 else None
    except Exception:
        return None


def set_scope(text, scope_val):
    """Set a single top-level `scope:` line in the frontmatter, body untouched.

    `scope_val` is 'global' or 'repo:<slug>'. Shared by the CLI and the backfill so
    the frontmatter mutation has one source of truth (the module docstring's
    anti-divergence promise). NOT used by re-import, which deliberately prepends
    without dedup to preserve the body hash.
    """
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            fm = [l for l in text[4:end].splitlines() if not l.startswith("scope:")]
            fm.append("scope: " + scope_val)
            return "---\n" + "\n".join(fm) + "\n---\n" + text[end + len("\n---\n"):]
    return "---\nscope: %s\n---\n%s" % (scope_val, text)


def repo_root(cwd, timeout=5):
    """Absolute repo root for `cwd`, folding worktrees to the parent repo, or None.

    Uses `--path-format=absolute --git-common-dir` (NOT --show-toplevel, which
    returns the worktree root; NOT bare --git-common-dir, which returns a relative
    `.git`/`../.git` in the main checkout). The common-dir of a worktree points at
    the PARENT repo's `.git`, so stripping `/.git` folds worktrees to the parent.
    """
    common = _run(["git", "-C", cwd, "rev-parse", "--path-format=absolute",
                   "--git-common-dir"], cwd=cwd, timeout=timeout)
    if not common:
        return None
    common = common.rstrip("/")

    # A SUBMODULE's common-dir is `<super>/.git/modules/<name>`, which ends in
    # neither `/.git` nor a `.git` basename — so both folds below fall through and
    # the caller gets a path INSIDE `.git` as a repo root, producing a scope slug
    # that names neither the submodule nor the superproject. Fold it to the
    # superproject, which is the repo a person would say they are working in.
    marker = "/.git/modules/"
    if marker in common:
        return common[: common.index(marker)]

    return common[: -len("/.git")] if common.endswith("/.git") else (
        os.path.dirname(common) if os.path.basename(common) == ".git" else common)


def slugify(path):
    """reflect's path-slug: /Users/x/p -> -Users-x-p (leading dash, '/'→'-')."""
    p = path.rstrip("/")
    s = "-" + p[1:] if p.startswith("/") else p
    return s.replace("/", "-")


def resolve_repo_slug(cwd, timeout=5):
    """Current repo's scope slug, or GLOBAL when cwd is outside any git repo."""
    root = repo_root(cwd, timeout=timeout)
    return slugify(root) if root else GLOBAL


def _normalize_slug(slug):
    """Strip the leading punctuation qmd drops so both sides compare equal."""
    return (slug or "").lstrip("-_")


def scope_of_qmd_file(file_field):
    """The scope slug encoded in a qmd `file` value, or GLOBAL for a flat-root body.

    Handles the real qmd rewrite: strips a `qmd://<collection>/` prefix, accepts the
    scope marker as either `_scope` or `scope`, and returns the slug segment that
    follows. A body at the flat root (no scope marker) is GLOBAL.
    """
    if not file_field:
        return GLOBAL
    path = file_field
    if path.startswith("qmd://"):
        # qmd://<collection>/<rest...> -> drop scheme + collection
        rest = path[len("qmd://"):]
        path = rest.split("/", 1)[1] if "/" in rest else ""
    parts = [p for p in path.split("/") if p]
    for i, seg in enumerate(parts):
        if seg in SCOPE_MARKERS and i + 1 < len(parts):
            return parts[i + 1]
    return GLOBAL


def scope_matches(qmd_file, repo_slug):
    """True iff the qmd result's scope equals `repo_slug` after normalization.

    GLOBAL never matches a concrete repo slug (global bodies are ancestor-eligible,
    not current-repo). This is the F-A equality the K+1 boost depends on.
    """
    parsed = scope_of_qmd_file(qmd_file)
    if parsed == GLOBAL or repo_slug == GLOBAL:
        return False
    return _normalize_slug(parsed) == _normalize_slug(repo_slug)


def is_ancestor_scope(anc_slug, slug):
    """True iff anc_slug is an ancestor scope of slug (its path-components prefix).

    GLOBAL (the $HOME slug) is an ancestor of every repo slug under it.
    """
    a, b = _normalize_slug(anc_slug), _normalize_slug(slug)
    if a == b:
        return True
    return b.startswith(a + "-")


def classify(qmd_file, cur_slug):
    """Classify a result vs the current repo: 'current' | 'ancestor' | 'sibling'.

    A flat-root (global) body and any ancestor scope are 'ancestor' (always
    eligible); a body whose scope equals the current repo is 'current' (the boost
    candidate); any other repo's body is 'sibling' (suppressed). With cur_slug
    GLOBAL (outside a repo), no body is 'current' and scoped bodies are 'sibling'.
    """
    sc = scope_of_qmd_file(qmd_file)
    if sc == GLOBAL:
        return "ancestor"
    if cur_slug != GLOBAL and scope_matches(qmd_file, cur_slug):
        return "current"
    if cur_slug != GLOBAL and is_ancestor_scope(sc, cur_slug):
        return "ancestor"
    return "sibling"


def select_scoped(results, cur_slug, k, repo_floor=None,
                  file_of=lambda r: r.get("file"),
                  score_of=lambda r: r.get("score")):
    """The plan-003 U4 selection, as a pure function the hook and tests share.

    Takes the top-`k` of the GLOBAL/ancestor pool (siblings suppressed) — the K
    global slots, never displaced — and prepends the single best current-repo body
    above `repo_floor` (a DISTINCT floor from the global one) as a K+1th item. When
    cur_slug is GLOBAL (a session outside any repo) no body is 'current' and every
    scoped body is a 'sibling', so this returns globals-only top-k — repo memories
    don't pollute a home session. (The hook falls back to a plain top-k only when the
    scope module is entirely absent.) Input order is assumed score-descending.
    """
    ancestors, current = [], []
    for r in results:
        c = classify(file_of(r), cur_slug)
        if c == "ancestor":
            ancestors.append(r)
        elif c == "current":
            current.append(r)
        # sibling -> dropped
    if repo_floor is not None:
        current = [r for r in current
                   if isinstance(score_of(r), (int, float)) and score_of(r) >= repo_floor]
    return current[:1] + ancestors[:k]


if __name__ == "__main__":
    import sys
    if len(sys.argv) >= 2:
        print(resolve_repo_slug(sys.argv[1] if len(sys.argv) > 1 else os.getcwd()))
