#!/usr/bin/env python3
"""Normalize a codebase's CSS design tokens into a base+dark token model.

The parser is config-driven: it is told the target codebase's *theme
conventions* (how the dark scope is declared) rather than assuming any fixed
selectors. v1 is base + exactly one "dark" theme.

  parse_tokens(text, conventions, prefix=None) -> list[dict]
      Resolves each custom property's *effective* base ("light") and dark value
      (chasing var() aliases per-scope) and emits one record per token:

        {
          "name":        "--accent",
          "light":       "#37D895",   # resolved base literal
          "dark":        "#00B72B",   # resolved dark literal, or null when the
                                      # effective value is theme-invariant
          "light_alias": "--green-500",# referent when the BASE declaration is a
                                      # var(), else null
          "dark_alias":  null          # referent when the DARK declaration is a
                                      # var(), else null
        }

      A token carries a non-null `dark` whenever its effective value differs by
      theme — INCLUDING an alias declared only in the base scope whose referent
      is redeclared in the dark scope (the value flips because the referent
      flips). This alias-flip invariant is theme-convention agnostic — only the
      block-finding is driven by config.

Theme-scope resolution (KTD2):
  - The BASE scope is the top-level, unscoped `:root { … }` (brace-depth 0). A
    `:root` nested inside an `@media` block, and a `:root[data-theme="dark"]`
    attribute-scoped block, are NOT the base.
  - A data-attribute convention `{attr, value}` resolves the CSS rule whose
    selector targets `[attr="value"]` (both `[data-theme="dark"]` and
    `:root[data-theme="dark"]` match).
  - A media-query convention `{query}` descends the `@media <query> { … }` block
    (brace-aware) and reads its inner `:root`.

When more than one convention is configured, one is `primary`. Parsing reads the
primary's dark scope; if the primary and a non-primary convention BOTH declare a
token whose resolved dark value disagrees, a warning is emitted (KTD3) and the
primary's value is used. Warnings go to stderr and are also returned by
parse_with_diagnostics so they are assertable without capturing stderr.

Normalization makes output idempotent (parsing the same input twice is
byte-identical): token names are lowercased, hex literals are uppercased,
records are sorted by name.

CLI:
  cat tokens.css | python3 parse_tokens.py --conventions '<json array>' \
      [--prefix '--brand-']   # -> JSON array on stdout, warnings on stderr
"""

import argparse
import json
import re
import sys

# A custom-property declaration inside a block body: `--name: value;`
# Values never contain a semicolon, so `[^;]+` is a safe value grab (box-shadows,
# rgba() with internal commas, cubic-bezier(), etc. all lack `;`).
_DECL = re.compile(r"--([A-Za-z0-9-]+)\s*:\s*([^;]+);")

# A pure `var(--other)` alias (no fallbacks are used anywhere in the source).
_VAR = re.compile(r"^var\(\s*(--[A-Za-z0-9-]+)\s*\)$")

# Hex color literals (3/4/6/8 digit). Uppercased for stable output.
_HEX = re.compile(r"#[0-9a-fA-F]+")


def _log(msg):
    """Diagnostics/warnings go to stderr so stdout stays clean JSON."""
    print(f"[parse_tokens] {msg}", file=sys.stderr)


def strip_comments(text):
    """Strip `/* … */` block comments and `//` line comments.

    The `//` handling guards against `://` (URL protocols) so a value like
    url(https://…) is not truncated."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    out = []
    for line in text.splitlines():
        idx = line.find("//")
        while idx != -1:
            if idx > 0 and line[idx - 1] == ":":
                idx = line.find("//", idx + 2)
                continue
            line = line[:idx]
            break
        out.append(line)
    return "\n".join(out)


# --- brace-aware block scanning ----------------------------------------------


def _match_brace(text, open_idx):
    """Given the index of a `{` at text[open_idx], return (body, close_idx):
    the substring between the matched braces (exclusive) and the index of the
    matching `}`. Brace-aware, so nested blocks (e.g. inside @media) are handled.
    On an unbalanced source, returns the remainder and len(text)."""
    depth = 0
    n = len(text)
    i = open_idx
    while i < n:
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1 : i], i
        i += 1
    return text[open_idx + 1 :], n


def _top_level_rules(text):
    """Yield (selector, body) for each `selector { … }` rule at brace-depth 0.

    Nested blocks are consumed whole by _match_brace, so a rule nested inside an
    @media block does NOT appear here — call _top_level_rules again on an
    @media body to reach its inner rules. At-statements without a block (e.g.
    `@import "x";`) carry no braces; any such prefix is trimmed from the next
    rule's selector via the trailing-`;` split."""
    rules = []
    n = len(text)
    i = 0
    sel_start = 0
    while i < n:
        if text[i] == "{":
            selector = text[sel_start:i].split(";")[-1].strip()
            body, close_idx = _match_brace(text, i)
            rules.append((selector, body))
            i = close_idx + 1
            sel_start = i
            continue
        i += 1
    return rules


def _norm_ws(s):
    """Collapse runs of whitespace to a single space and strip the ends."""
    return re.sub(r"\s+", " ", s).strip()


def _canon_media(q):
    """Canonicalize a media-query condition for EXACT comparison: drop all
    whitespace so `(prefers-color-scheme:dark)` and `(prefers-color-scheme: dark)`
    compare equal, while a compound query (`… and (min-width: 800px)`) stays
    distinct — so it is NOT mistaken for the bare dark query."""
    return re.sub(r"\s+", "", q)


def _is_bare_root(selector):
    """True when `selector` is (or contains as a group member) a bare `:root` —
    NOT `:root[…]` and NOT an at-rule."""
    if selector.startswith("@"):
        return False
    return any(part.strip() == ":root" for part in selector.split(","))


def _base_block(text):
    """Return the body of the top-level unscoped `:root { … }` block, or ''."""
    for selector, body in _top_level_rules(text):
        if _is_bare_root(selector):
            return body
    return ""


def _data_attribute_block(text, attr, value):
    """Return the body of the top-level rule whose selector targets
    [attr="value"] (matching both `[attr="value"]` and `:root[attr="value"]`),
    or ''."""
    pat = re.compile(
        r"\[\s*" + re.escape(attr) + r"\s*=\s*[\"']?" + re.escape(value) + r"[\"']?\s*\]"
    )
    for selector, body in _top_level_rules(text):
        if selector.startswith("@"):
            continue
        if pat.search(selector):
            return body
    return ""


def _media_query_block(text, query):
    """Descend the top-level `@media <query> { … }` block and return its inner
    `:root` body, or ''. Brace-aware: the @media body may contain sibling rules
    alongside the :root."""
    target = _canon_media(query)
    for selector, body in _top_level_rules(text):
        if not selector.startswith("@media"):
            continue
        # EXACT match (whitespace-insensitive) — a compound query that merely
        # CONTAINS the target (`… and (min-width: 800px)`) is a different scope
        # and must not be grabbed as the dark scope.
        if _canon_media(selector[len("@media") :]) == target:
            return _base_block(body)
    return ""


def _scope_decls(text, conv):
    """Resolve one convention's dark-scope declarations into a raw decl dict."""
    ctype = conv.get("type")
    if ctype == "data-attribute":
        body = _data_attribute_block(text, conv.get("attr"), conv.get("value"))
    elif ctype == "media-query":
        body = _media_query_block(text, conv.get("query"))
    else:
        raise ValueError(f"unknown themeConvention type: {ctype!r}")
    return _parse_decls(body)


def _primary_convention(conventions):
    """The primary convention: the sole entry when there is one, else the one
    flagged `primary` (read_config guarantees exactly one when there are >1)."""
    if not conventions:
        raise ValueError("themeConventions must have at least one entry")
    if len(conventions) == 1:
        return conventions[0]
    for conv in conventions:
        if conv.get("primary"):
            return conv
    raise ValueError(
        "with more than one themeConvention, exactly one must set 'primary': true"
    )


def _conv_label(conv):
    """A short human label for a convention, used in warning text."""
    ctype = conv.get("type")
    if ctype == "data-attribute":
        return f'[{conv.get("attr")}="{conv.get("value")}"]'
    if ctype == "media-query":
        return f'@media {conv.get("query")}'
    return str(ctype)


# --- declaration parsing + effective-value resolution ------------------------


def _parse_decls(body):
    """Return an ordered dict of `--name` -> raw value (names lowercased)."""
    decls = {}
    for name, val in _DECL.findall(body):
        decls["--" + name.lower()] = val.strip()
    return decls


def _alias_of(raw):
    """Referent (`--other`) when raw is a `var(--other)` alias, else None."""
    if raw is None:
        return None
    m = _VAR.match(raw)
    return m.group(1).lower() if m else None


def _resolve(name, primary, fallback):
    """Resolve a token to its effective literal in one scope.

    `primary` is the scope's own dict; `fallback` (base) is consulted when the
    token/referent is absent from `primary` (dark falls through to base).
    Chases var() aliases until a literal is reached. Cycle-guarded."""
    seen = set()
    cur = name
    while cur not in seen:
        seen.add(cur)
        raw = primary.get(cur)
        if raw is None and fallback is not None:
            raw = fallback.get(cur)
        if raw is None:
            return None
        m = _VAR.match(raw)
        if m:
            cur = m.group(1).lower()
            continue
        return raw
    return None


def _normalize_hex(value):
    if value is None:
        return None
    return _HEX.sub(lambda m: m.group(0).upper(), value)


# --- public seam for sibling modules -----------------------------------------
# sync_tokens and emit_tokens share this module's token model and deliberately
# reuse these three internals. They are re-exported under public names so the
# cross-module dependency is an explicit contract: a refactor that renames the
# underscore-prefixed originals must keep these public aliases pointing at the
# equivalent behavior. Do NOT reach past this seam into other `_`-prefixed
# helpers from another module.
VAR_ALIAS_RE = _VAR  # compiled regex matching a bare `var(--x)` alias
normalize_hex = _normalize_hex  # uppercase every hex run in a value (idempotent)
primary_convention = _primary_convention  # the primary themeConvention resolver


def parse_with_diagnostics(text, conventions, prefix=None):
    """Parse `text` into the base+dark token model, returning both the token
    records and any warnings.

    Returns {"tokens": [record, …], "warnings": [str, …]}.

    `conventions` is the config `themeConventions` list. `prefix`, when a
    non-empty string, restricts output to custom properties whose name starts
    with it; None/"" includes all."""
    text = strip_comments(text)
    base = _parse_decls(_base_block(text))

    primary = _primary_convention(conventions)
    dark = _scope_decls(text, primary)

    warnings = []
    # Cross-check every non-primary convention against the primary (KTD3): for a
    # token both scopes DECLARE, a disagreeing effective dark value is a warning.
    for conv in conventions:
        if conv is primary:
            continue
        other = _scope_decls(text, conv)
        for name in sorted(set(dark) & set(other)):
            pv = _normalize_hex(_resolve(name, dark, base))
            ov = _normalize_hex(_resolve(name, other, base))
            if pv != ov:
                msg = (
                    f"{name}: dark value differs between conventions "
                    f"(primary {_conv_label(primary)}={pv}, "
                    f"{_conv_label(conv)}={ov}); using primary"
                )
                warnings.append(msg)
                _log("WARNING: " + msg)

    records = []
    included = {n for n in (set(base) | set(dark)) if not (prefix and not n.startswith(prefix))}
    for name in sorted(set(base) | set(dark)):
        if prefix and not name.startswith(prefix):
            continue
        light_val = _normalize_hex(_resolve(name, base, None))
        dark_val = _normalize_hex(_resolve(name, dark, base))
        light_alias = _alias_of(base.get(name))
        dark_alias = _alias_of(dark.get(name))
        # Dangling-alias warning: an included token that aliases a referent the
        # prefix filter EXCLUDED. build_desired keeps the alias as var(--referent),
        # but that referent is never synced, so Paper drops the dangling reference.
        for ref in (light_alias, dark_alias):
            if not ref or ref in included:
                continue
            # Two distinct causes: the referent exists but the prefix filter
            # excluded it, or it is simply not declared anywhere. Attribute the
            # warning accurately (a "widen the prefix" fix is nonsense when the
            # referent is undeclared, or when no prefix is set).
            if prefix and not ref.startswith(prefix):
                cause = f"is outside the prefix filter ({prefix!r})"
                fix = "Widen the prefix or inline the value."
            else:
                cause = "is not declared in the source"
                fix = "Declare it or inline the value."
            msg = (
                f"{name} aliases {ref}, which {cause} — Paper will drop the "
                f"dangling var({ref}) reference. {fix}"
            )
            warnings.append(msg)
            _log("WARNING: " + msg)
        records.append(
            {
                "name": name,
                "light": light_val,
                # null when the effective value does not differ by theme
                "dark": None if dark_val == light_val else dark_val,
                "light_alias": light_alias,
                "dark_alias": dark_alias,
            }
        )
    return {"tokens": records, "warnings": warnings}


def parse_tokens(text, conventions, prefix=None):
    """Parse `text` into the base+dark token model (the records only).

    See parse_with_diagnostics for the record shape and semantics; this is the
    thin wrapper the deterministic-diff callers use when they don't need the
    warnings list (warnings still reach stderr)."""
    return parse_with_diagnostics(text, conventions, prefix)["tokens"]


# --- source loading ----------------------------------------------------------


def load_source(cfg):
    """Read the config's source CSS text.

    `cfg` is the dict returned by paper_client.read_config (it carries `_repo`).
    The source path resolves relative to the repo root. When `source.ref` is set
    (a git ref like 'origin/main'), the file is read at that ref via
    `git show <ref>:<relative-path>`; otherwise the working-tree file is read.
    Raises RuntimeError on a git failure or a missing/unreadable file."""
    import os
    import subprocess

    # Sibling lib module — resolve_repo_path lives beside this file.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from paper_client import resolve_repo_path  # noqa: E402

    source = cfg.get("source") or {}
    rel = source.get("path")
    if not rel:
        raise RuntimeError("config 'source.path' is required to load the CSS source")

    ref = source.get("ref")
    if ref:
        repo = cfg.get("_repo")
        if not repo:
            raise RuntimeError(
                "config is missing '_repo'; load it via read_config before load_source"
            )
        spec = f"{ref}:{rel}"
        try:
            result = subprocess.run(
                ["git", "-C", repo, "show", spec],
                capture_output=True,
                text=True,
                check=True,
            )
        except FileNotFoundError as exc:  # git not installed
            raise RuntimeError(f"git is not available to read {spec}: {exc}") from exc
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or "").strip() or (exc.stdout or "").strip()
            raise RuntimeError(
                f"could not read source at ref '{spec}' in {repo}: {detail}"
            ) from exc
        return result.stdout

    abs_path = resolve_repo_path(cfg, rel)
    try:
        with open(abs_path, "r", encoding="utf-8") as fh:
            return fh.read()
    except OSError as exc:
        raise RuntimeError(f"could not read source file {abs_path}: {exc}") from exc


# --- CLI ---------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="parse_tokens.py",
        description=(
            "Parse a codebase's CSS design tokens (stdin) into the base+dark "
            "token model, driven by the configured theme conventions."
        ),
    )
    parser.add_argument(
        "--conventions",
        required=True,
        help="JSON array of themeConventions (data-attribute / media-query).",
    )
    parser.add_argument(
        "--prefix",
        default=None,
        help="Only include custom properties whose name starts with this prefix.",
    )
    args = parser.parse_args(argv)

    try:
        conventions = json.loads(args.conventions)
    except json.JSONDecodeError as exc:
        _log(f"--conventions is not valid JSON: {exc}")
        return 2
    if not isinstance(conventions, list):
        _log("--conventions must be a JSON array of convention objects")
        return 2

    text = sys.stdin.read()
    try:
        result = parse_with_diagnostics(text, conventions, args.prefix)
    except ValueError as exc:
        _log(str(exc))
        return 2

    print(json.dumps(result["tokens"], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
