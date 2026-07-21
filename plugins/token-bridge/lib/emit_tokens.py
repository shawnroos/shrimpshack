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
    A non-twin referent (`var(--y)`) or a literal is returned unchanged.

    This shares parse_tokens' alias seam, so it inherited the widening that
    taught that seam about `var(--x, fallback)` — a form this function did not
    previously match at all. It now rewrites `var(--y-dark, #eee)` to
    `var(--y)`, which drops the fallback. Emitting the fallback through is not
    an option (its referent name would still be the dangling `--y-dark`), so
    warn: a silently dropped fallback changes what renders when the referent is
    undefined."""
    if value is None:
        return value
    ref, fallback = parse_tokens.split_var_alias(value)
    if ref is None or not ref.endswith(DARK_SUFFIX):
        return value
    stripped = ref[: -len(DARK_SUFFIX)]
    if fallback is not None:
        _log(
            "WARNING: %s de-suffixes to var(%s) — its fallback %r is discarded. "
            "Inline the fallback or ensure %s is always defined."
            % (value.strip(), stripped, fallback, stripped)
        )
    return "var(%s)" % stripped


def _decls(pairs, depth):
    """Render declarations at `depth` nesting levels — two spaces per level."""
    pad = "  " * depth
    return "\n".join("%s%s: %s;" % (pad, name, val) for name, val in pairs)


def _root_block(pairs):
    return ":root {\n%s\n}" % _decls(pairs, 1)


def _invert_selector(preds):
    """Invert the selector-level predicates of a conjunction into one selector.

    The inverse of `parse_tokens._match_selector_predicate`, and coupled to it:
    whatever this builds, that matcher must accept. Only the round-trip test
    proves they still agree (KTD8).

      {selector: S}       -> S, used as the anchor (media-query's `:root`)
      {class: C}          -> `.C`   appended
      {attr: A, value: V} -> `[A="V"]` appended

    With no explicit anchor the selector is anchored at `:root` — so a lone
    class predicate emits `:root.wcs-dark`, not a bare `.wcs-dark`. That keeps
    the dark block anchored at the same element the base block declares on."""
    anchor = None
    parts = []
    for pred in preds:
        if "media" in pred:
            continue
        if "selector" in pred:
            if anchor is not None:
                raise ValueError(
                    "cannot invert two selector anchors in one conjunction: %r" % (preds,)
                )
            anchor = pred["selector"]
        elif "class" in pred:
            parts.append(".%s" % pred["class"])
        elif "attr" in pred:
            parts.append('[%s="%s"]' % (pred["attr"], pred["value"]))
        else:
            raise ValueError("unrecognized scope predicate: %r" % (pred,))
    if anchor is not None and parts:
        # `{selector: S}` is an EXACT-match predicate in the parser, so appending
        # to it emits a selector the matcher would reject — the round-trip would
        # break silently. Refuse instead.
        raise ValueError(
            "cannot invert an exact selector anchor combined with other selector "
            "predicates: %r" % (preds,)
        )
    if anchor is None and not parts:
        raise ValueError("no selector-level predicate to invert: %r" % (preds,))
    return (anchor or ":root") + "".join(parts)


def _dark_block(conv, pairs):
    """Wrap the dark declarations in the primary convention's scope (KTD8).

    Selector predicates become the rule's selector; a media predicate becomes an
    `@media` wrapper around it. Indentation is two spaces per nesting level, so
    the unwrapped form indents declarations by 2 and the wrapped form by 4 —
    byte-identical to what the pre-predicate type dispatch emitted."""
    preds = parse_tokens.desugar_convention(conv)
    selector = _invert_selector(preds)
    medias = [p["media"] for p in preds if "media" in p]
    if not medias:
        return "%s {\n%s\n}" % (selector, _decls(pairs, 1))
    if len(medias) > 1:
        raise ValueError(
            "cannot invert more than one media predicate in a conjunction: %r" % (preds,)
        )
    return "@media %s {\n  %s {\n%s\n  }\n}" % (medias[0], selector, _decls(pairs, 2))


def emit_css(paper_tokens, conventions, prefix=None):
    """Emit a CSS string from a Paper token set (base + `-dark` twins).

    Partitions base tokens from `-dark` twins by the suffix, emits a `:root`
    base block and a dark override block in the primary convention, inverting
    both the twin name and its alias referents (KTD4). `prefix`, when set,
    restricts output to matching names (the Paper set is already prefix-filtered
    by sync, so this is a belt-and-suspenders match for the round-trip)."""
    primary = parse_tokens.primary_convention(conventions)

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

    if primary.get("type") == "file":
        # A file convention's two halves are two FILES, so one string cannot
        # represent them. emit_pair() is the entry point for that shape; a
        # caller reaching here would silently get a base-only emit, which
        # leaves the dark file stale and drifts the pair apart (KTD4).
        raise ValueError(
            "a 'file' convention emits two files — call emit_pair(), not emit_css()"
        )

    blocks = [_root_block(base_pairs)]
    if dark_pairs:
        blocks.append(_dark_block(primary, dark_pairs))
    return "\n\n".join(blocks) + "\n"


def _same_file(a, b):
    """True when two paths denote the SAME file, resolving symlinks and
    case-insensitive filesystems — os.path.abspath does neither.

    abspath is purely lexical, so it passed two targets that differ only by
    case (APFS is case-insensitive by default) or by a symlinked parent. Both
    then staged to one temp, and the base file ended up holding the dark theme
    while the report claimed nothing was written."""
    if not a or not b:
        return False
    ra, rb = os.path.realpath(a), os.path.realpath(b)
    if ra == rb:
        return True
    # When both paths exist, samefile is authoritative (it resolves case and
    # symlinks). It raises only when a path is MISSING — which is the normal
    # case for emit, since it writes new files — and there we fall back to a
    # case-folded compare so a case-insensitive mount is still caught before we
    # write. The fallback must stay gated on that raise: if samefile can decide
    # and says "different", two case-equal but distinct files must NOT collide.
    try:
        return os.path.samefile(ra, rb)
    except OSError:
        return ra.lower() == rb.lower()


def emit_pair(paper_tokens, conventions, prefix=None):
    """Emit (base_css, dark_css) for a primary `file` convention (KTD4).

    The dark half is a whole file whose own document scope carries the overrides,
    mirroring how parse reads it — so emit and parse stay inverses and the
    round-trip closes across the pair (KTD5)."""
    primary = parse_tokens.primary_convention(conventions)
    if primary.get("type") != "file":
        raise ValueError("emit_pair() is only for a primary 'file' convention")

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
    return _root_block(base_pairs) + "\n", _root_block(dark_pairs) + "\n"


# --- round-trip proof (R5), no daemon ----------------------------------------


def roundtrip(paper_tokens, conventions, prefix=None):
    """Prove the R5 fixed point: emit -> parse -> build_desired -> diff vs the
    Paper set. Returns {css, diff, empty}. `empty` True == round-trip stable."""
    primary = parse_tokens.primary_convention(conventions)
    if primary.get("type") == "file":
        # The pair IS the artifact for a file convention, so the fixed point has
        # to be proven across both halves — emit_css refuses this shape anyway.
        base_css, dark_css = emit_pair(paper_tokens, conventions, prefix)
        css = base_css
        records = parse_tokens.parse_tokens(css, conventions, prefix, {
            conventions.index(primary): dark_css
        })
    else:
        css = emit_css(paper_tokens, conventions, prefix)
        records = parse_tokens.parse_tokens(css, conventions, prefix)
    classified = classify_tokens.classify_tokens(records)
    desired, _declined = sync_tokens.build_desired(classified)
    # Emitted CSS is the only input here, so nothing can be 'declared but
    # unread' — an empty set is the honest value, not a defaulted one.
    diff = sync_tokens.diff_tokens(desired, paper_tokens, unreadable=set())
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

    primary = parse_tokens.primary_convention(conventions)

    # KTD4: a file convention's theme is two FILES. Write both or write neither —
    # emitting only the base leaves the dark file stale and silently drifts the
    # pair apart, which is worse than not emitting at all. The check runs BEFORE
    # any write so a refusal never leaves a half-updated pair on disk.
    if primary.get("type") == "file":
        dark_target = resolve_repo_path(cfg, primary.get("emitTarget"))
        if not dark_target:
            return (
                {
                    "ok": False,
                    "error": "no_dark_emit_target",
                    "note": (
                        "the primary themeConvention is type 'file', so emit writes TWO "
                        "files, but that convention has no 'emitTarget'. Nothing was "
                        "written — emitting only the base would leave the dark theme "
                        "file stale. Add an 'emitTarget' to the file convention."
                    ),
                },
                EXIT_ERROR,
            )
        # Both halves to the SAME path is silent data loss, not a no-op: the
        # loop would write base then overwrite it with dark, report ok:true, and
        # leave a file whose content is dark while the report describes base.
        # Every output must differ from every INPUT as well as from each other.
        # Guarding only the two outputs left the worse case open: writing base
        # content over the dark THEME SOURCE makes the next parse see dark ==
        # base, so no token varies by theme and every -dark twin would then be
        # reported as prunable — a spurious removal list for tokens still in use.
        source_rel = (source or {}).get("path")
        collisions = [
            ("emitTarget", emit_target, "the file convention's emitTarget", dark_target),
            ("emitTarget", emit_target, "source.path", resolve_repo_path(cfg, source_rel)),
            ("emitTarget", emit_target, "the theme file it reads",
             resolve_repo_path(cfg, primary.get("path"))),
            ("the file convention's emitTarget", dark_target, "source.path",
             resolve_repo_path(cfg, source_rel)),
            ("the file convention's emitTarget", dark_target, "the theme file it reads",
             resolve_repo_path(cfg, primary.get("path"))),
        ]
        for a_label, a_path, b_label, b_path in collisions:
            if _same_file(a_path, b_path):
                return (
                    {
                        "ok": False,
                        "refused": True,
                        "error": "emit_targets_collide",
                        "note": (
                            f"{a_label} and {b_label} resolve to the same file "
                            f"({os.path.realpath(a_path)}). Nothing was written — emitting "
                            "would destroy one of them. Point them at distinct files."
                        ),
                    },
                    EXIT_ERROR,
                )

        # PRE-FLIGHT both targets before touching either. Two files cannot be
        # renamed atomically on POSIX — os.replace is atomic per file, so a
        # staged write still replaces base, then dark, and a failure on the
        # second leaves the pair drifted. Staging alone does not deliver KTD4's
        # both-or-neither; catching the predictable failures up front does.
        # (An unstaged write is strictly worse — it fails mid-content.)
        for label, path in (("emitTarget", emit_target),
                            ("the file convention's emitTarget", dark_target)):
            ap = os.path.abspath(path)
            if os.path.isdir(ap):
                return (
                    {"ok": False, "refused": True, "error": "emit_target_is_a_directory",
                     "note": f"{label} ({ap}) is a directory. Nothing was written."},
                    EXIT_ERROR,
                )
            try:
                os.makedirs(os.path.dirname(ap), exist_ok=True)
            except OSError as exc:
                return (
                    {"ok": False, "refused": True, "error": "emit_target_unwritable",
                     "note": f"cannot create the directory for {label} ({ap}): {exc}. "
                             "Nothing was written."},
                    EXIT_ERROR,
                )

        base_css, dark_css = emit_pair(tokens, conventions, prefix)

        # Stage both, then replace both. The residual window (a failure between
        # the two replaces) is not closable with POSIX renames; the pre-flight
        # above removes the reachable causes.
        tmps = []
        replaced = []
        try:
            for path, body in ((emit_target, base_css), (dark_target, dark_css)):
                tmp = os.path.realpath(path) + ".tb-tmp"
                with open(tmp, "w", encoding="utf-8") as fh:
                    fh.write(body)
                tmps.append((tmp, path))
            for tmp, path in tmps:
                os.replace(tmp, path)
                replaced.append(path)
        except OSError as exc:
            for tmp, _ in tmps:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
            return (
                {"ok": False, "error": f"could not write the theme pair: {exc}",
                 "note": (
                     f"{len(replaced)} of 2 files were replaced before the failure"
                     + (f" ({', '.join(replaced)})" if replaced else "")
                     + ". Re-run once the cause is fixed; emit is idempotent."
                 )},
                EXIT_ERROR,
            )
        css = base_css
    else:
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
        needs_repo = parse_tokens.file_convention_needs_repo(conventions)
        if needs_repo:
            _log(needs_repo)
            return EXIT_REFUSED
        sys.stdout.write(emit_css(tokens, conventions, args.prefix))
        return EXIT_OK

    if cmd == "roundtrip":
        tokens = _tokens_from(_load_json_file(args.tokens))
        conventions = json.loads(args.conventions)
        needs_repo = parse_tokens.file_convention_needs_repo(conventions)
        if needs_repo:
            _log(needs_repo)
            return EXIT_REFUSED
        result = roundtrip(tokens, conventions, args.prefix)
        print(json.dumps(result, indent=2))
        return EXIT_OK if result["empty"] else EXIT_ERROR

    parser.print_usage(sys.stderr)
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main())
