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

      A base declaration of `light-dark(A, B)` fills BOTH fields on its own, so
      such a token needs no dark-scope entry at all (KTD9). A dark scope that
      also declares it wins — it is the more specific signal — and parse warns
      rather than silently picking between the two.

Theme-scope resolution:
  A scope is a PREDICATE over a declaration block's context — the chain of
  enclosing at-rules plus the block's own selector. The stylesheet is walked
  recursively, and EVERY block whose context satisfies a convention's
  predicates contributes its declarations, merged in source order.

  - The BASE scope is a bare, unscoped DOCUMENT scope — `:root`, `html`, or
    `body` — with no conditional at-rule in its context. `:root[data-theme="dark"]`
    and `html.wcs-dark` are not the base; neither is a `:root` inside `@media`.
    Component selectors are never the base, however many custom properties
    they declare.
  - At-rules split by conditionality. `@layer` (and other grouping wrappers)
    are TRANSPARENT: a bare `:root` inside one IS the base. `@media`,
    `@supports` and `@container` are CONDITIONAL: they stay in the context, so
    a `:root` inside one is never the base, only a dark candidate.
  - The three named convention types are sugar over predicates (see
    desugar_convention): `class` → a boundary-anchored class match,
    `data-attribute` → an `[attr="value"]` match, `media-query` → a two-
    predicate conjunction of the media query AND a `:root` selector anchor.
  - Predicates within one convention compose with AND; the conventions array
    composes with OR, with `primary` as the tiebreak.

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

# The NAME half of a custom-property declaration: `--name:`. The value half is
# scanned character-wise (see _iter_decls) rather than matched, because a value
# CAN contain a semicolon — `url("data:image/svg+xml;utf8,…")` is the case that
# proves it, and a `[^;]+` grab truncates it mid-URI.
_DECL_NAME = re.compile(r"--([A-Za-z0-9_-]+)\s*:")

# `!important` is a CSS-level priority marker, not part of the token's value.
# Left in, it rides into Paper as literal text and classify_tokens declines the
# token (`#fff !important` is not a clean color full-match).
_IMPORTANT = re.compile(r"\s*!\s*important\s*$", re.I)

# A `var(--other)` alias, with an OPTIONAL fallback: `var(--other, #eee)`.
# The fallback group is deliberately loose (a fallback can be any value, nested
# functions included); `var_alias` balance-checks it so a composite value like
# `var(--a, #eee) var(--b, #fff)` is not mistaken for a single alias.
_VAR = re.compile(r"^var\(\s*(--[A-Za-z0-9_-]+)\s*(?:,\s*(.*?)\s*)?\)$", re.S)

# Hex color literals (3/4/6/8 digit). Uppercased for stable output.
_HEX = re.compile(r"#[0-9a-fA-F]+")

# A `light-dark(A, B)` call occupying the WHOLE value. The inner group is
# deliberately greedy-to-the-last-`)` and balance-checked by light_dark_args, so
# a composite like `light-dark(a,b) light-dark(c,d)` is rejected rather than
# read as one call with a mangled argument. CSS function names are
# case-insensitive, hence re.I.
_LIGHT_DARK = re.compile(r"^light-dark\((.*)\)$", re.S | re.I)


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
        out.append(_strip_line_comment(line))
    return "\n".join(out)


def _strip_line_comment(line):
    """Drop a `//` line comment, treating strings and url() as data.

    The old guard was `the char before // is not ':'`, which covers `https://`
    and nothing else. A base64 data URI containing `//`, or a protocol-relative
    `url(//cdn…)`, truncated the line — and since `declared_names` shares this
    pre-pass, every declaration after that point became invisible to the PARSE
    and to the PROTECTION at once. A guard that fails together with the thing it
    guards protects nothing, which is the one shape "safe by construction" does
    not cover. Scan with the same string awareness the value scanner already
    uses."""
    i, n = 0, len(line)
    depth_url = 0
    while i < n:
        c = line[i]
        if c in "\"'":
            j = _skip_quoted(line, i)
            if j != i:
                i = j
                continue
        if line.startswith("url(", i):
            depth_url += 1
            i += 4
            continue
        if c == ")" and depth_url:
            depth_url -= 1
        elif c == "/" and line.startswith("//", i) and not depth_url:
            return line[:i]
        i += 1
    return line


# --- brace-aware block scanning ----------------------------------------------


def _skip_interpolation(text, i):
    """If `text[i:i+2]` opens a SCSS interpolation `#{`, return the index just
    PAST its matching `}`; otherwise return `i` unchanged.

    `#{$brand-blue}` is a value, not a nested rule — but its brace is UNQUOTED,
    so the quote-skipping guard doesn't cover it. Left unhandled, the block
    splitter read `--accent: #{$x};` as the start of a child block and dropped
    the declaration entirely: exactly the same silent-token-loss (and therefore
    silent-DELETE) path as a brace inside a string, through a different door.
    Interpolations nest and can contain strings, so track depth and step over
    quotes while scanning. `#fff` is not interpolation — the `{` must be the
    very next character."""
    if not text.startswith("#{", i):
        return i
    n = len(text)
    depth = 0
    j = i + 1  # sits on the '{'
    while j < n:
        c = text[j]
        if c in "\"'":
            k = _skip_quoted(text, j)
            if k != j:
                j = k
                continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


def _skip_quoted(text, i):
    """If `text[i]` opens a quoted string, return the index just PAST its closing
    quote; otherwise return `i` unchanged. Backslash escapes are honored, and an
    unterminated string stops at end-of-text rather than running away.

    Braces are structural in CSS *except* inside a string, where they are data.
    A `{` in a quoted value is entirely legal and not rare — an inline-SVG data
    URI carrying `<style>.a{fill:red}</style>` is the realistic case. Treating
    that `{` as the start of a nested rule made the enclosing declaration vanish
    from the parse with no error, and a token missing from a parse becomes a
    DELETE in the sync diff — the same silent-wipe class the empty-parse
    backstop exists to stop, reached through a different door. Both scanners
    below must therefore step over strings, not through them."""
    q = text[i]
    if q not in "\"'":
        return i
    n = len(text)
    j = i + 1
    while j < n:
        if text[j] == "\\":
            j += 2
            continue
        if text[j] == q:
            return j + 1
        j += 1
    return n


def _match_brace(text, open_idx):
    """Given the index of a `{` at text[open_idx], return (body, close_idx):
    the substring between the matched braces (exclusive) and the index of the
    matching `}`. Brace-aware and STRING-aware (see _skip_quoted), so nested
    blocks are handled and a brace inside a quoted value is treated as data.
    On an unbalanced source, returns the remainder and len(text)."""
    depth = 0
    n = len(text)
    i = open_idx
    while i < n:
        c = text[i]
        if c in "\"'":
            j = _skip_quoted(text, i)
            if j != i:
                i = j
                continue
        if c == "#":
            j = _skip_interpolation(text, i)
            if j != i:
                i = j
                continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1 : i], i
        i += 1
    return text[open_idx + 1 :], n


def _split_body(text):
    """Partition a block body into (own_text, rules) — KTD6.

    `own_text` is the text belonging to THIS block: its declarations, with every
    nested child block excised. `rules` is [(selector, body), …] for each direct
    child, in source order; nested blocks are consumed whole by _match_brace, so
    a rule inside an @media block does NOT appear here — the walk recurses to
    reach it.

    The split point before a child's `{` is that child's SELECTOR, and it starts
    after the last `;` — everything before that terminator is a declaration of
    the enclosing block. This also trims a blockless at-statement prefix
    (`@import "x";`) off the next rule's selector.

    Excising children is what makes declaration reads block-local. Scanning a
    parent body that still contained its children read a nested dark override as
    if it were the parent's own last declaration, which INVERTED light and dark
    under CSS/SCSS nesting."""
    own = []
    rules = []
    n = len(text)
    i = 0
    seg_start = 0
    while i < n:
        if text[i] in "\"'":
            # A brace inside a string is data, not a nested rule (see
            # _skip_quoted). Stepping over the string keeps the enclosing
            # declaration intact instead of silently dropping it.
            j = _skip_quoted(text, i)
            if j != i:
                i = j
                continue
        if text[i] == "#":
            # Same for a SCSS interpolation `#{…}` — its brace is unquoted, so
            # the guard above does not cover it (see _skip_interpolation).
            j = _skip_interpolation(text, i)
            if j != i:
                i = j
                continue
        if text[i] == "{":
            head = text[seg_start:i]
            cut = head.rfind(";")
            own.append(head[: cut + 1])
            body, close_idx = _match_brace(text, i)
            rules.append((head[cut + 1 :].strip(), body))
            i = close_idx + 1
            seg_start = i
            continue
        i += 1
    own.append(text[seg_start:])
    return "".join(own), rules


def _norm_ws(s):
    """Collapse runs of whitespace to a single space and strip the ends."""
    return re.sub(r"\s+", " ", s).strip()


def _canon_media(q):
    """Canonicalize a media-query condition for EXACT comparison: drop all
    whitespace so `(prefers-color-scheme:dark)` and `(prefers-color-scheme: dark)`
    compare equal, while a compound query (`… and (min-width: 800px)`) stays
    distinct — so it is NOT mistaken for the bare dark query."""
    return re.sub(r"\s+", "", q)


# The document-level scopes. `:root` and `html` select the SAME element (`:root`
# just has higher specificity); `body` is the other element custom properties are
# conventionally hung on, and they inherit from it to everything rendered.
#
# Nothing beyond these three. A component selector like `.tooltip { --bs-tooltip-bg: … }`
# also declares custom properties, but those are component-local, not theme
# tokens — pulling them into the base would sync a component's internals into
# Paper as though they were design tokens.
_DOCUMENT_SCOPES = frozenset({":root", "html", "body"})


def _is_document_scope(selector):
    """True when `selector` is (or contains as a group member) a bare document
    scope — `:root`, `html`, or `body` — carrying no further qualification.

    A group member must match EXACTLY. `html.dark`, `:root[data-theme="dark"]`
    and `body.theme-dark` are theme scopes, not the base, and a descendant form
    like `html body` is deliberately excluded as too loose to assume."""
    if selector.startswith("@"):
        return False
    return any(part.strip() in _DOCUMENT_SCOPES for part in selector.split(","))


# Back-compat alias: the old name said `:root` only, which is no longer what it
# means. Kept so any external caller keeps working.
_is_bare_root = _is_document_scope


# --- the scope walk (KTD5) ----------------------------------------------------

# At-rules that constrain WHEN a block applies. They stay in a block's context,
# and a bare `:root` inside one is therefore NEVER the base — only a dark-scope
# candidate when a matching media predicate holds. Every other at-rule (@layer
# and friends) is a grouping wrapper: transparent, so a `:root` inside one IS
# the base. Getting this backwards reintroduces the light/dark inversion this
# module exists to avoid, for every media-query user.
_CONDITIONAL_AT_RULES = ("media", "supports", "container")

_AT_NAME = re.compile(r"^@([A-Za-z-]+)")


def _split_at_rule(selector):
    """('media', '(prefers-color-scheme: dark)') for an at-rule selector, else
    (None, None)."""
    m = _AT_NAME.match(selector)
    if not m:
        return None, None
    name = m.group(1).lower()
    return name, selector[m.end() :].strip()


def _nest_selector(parent, child):
    """Resolve a nested child selector against its parent (CSS Nesting / SCSS).

    `&` is replaced by the parent selector; without an `&` the nesting is a
    DESCENDANT relationship, so the resolved selector is `parent child`. Both
    sides may be comma groups, so this is a cross product — matching the cascade
    rather than approximating it.

    Resolving rather than passing the raw child through is what lets the
    ordinary predicates work unchanged at depth: `&[data-theme="dark"]` inside
    `:root` becomes `:root[data-theme="dark"]`, which the attribute predicate
    already matches, while `.card` inside `:root` becomes `:root .card` — a
    descendant, correctly matching NEITHER the base nor a theme scope."""
    if not parent:
        return child
    parts = []
    for c in (m.strip() for m in child.split(",")):
        if not c:
            continue
        for p in (m.strip() for m in parent.split(",")):
            if not p:
                continue
            parts.append(c.replace("&", p) if "&" in c else p + " " + c)
    return ", ".join(parts)


def _walk(text, context, blocks, parent=None):
    """Collect (context, selector, own_body) for every selector block in `text`,
    at any depth, in source order.

    `context` is the chain of enclosing CONDITIONAL at-rules as (name, prelude)
    tuples; grouping at-rules are descended without extending it. `parent` is the
    enclosing selector, carried so nested blocks resolve against it.

    `own_body` is block-LOCAL (KTD6): each block's own declarations only. Child
    blocks are not left in it — they are walked as blocks in their own right,
    under their own resolved selector."""
    _own, rules = _split_body(text)
    for selector, body in rules:
        name, prelude = _split_at_rule(selector)
        if name is not None:
            nxt = context + [(name, prelude)] if name in _CONDITIONAL_AT_RULES else context
            _walk(body, nxt, blocks, parent)
            continue
        resolved = _nest_selector(parent, selector)
        own, _child_rules = _split_body(body)
        blocks.append((context, resolved, own))
        _walk(body, context, blocks, resolved)
    return blocks


def _collect_blocks(text):
    """Every selector block in the stylesheet, at any depth, in source order."""
    return _walk(text, [], [])


# --- predicates (KTD1-KTD4) ---------------------------------------------------


def desugar_convention(conv):
    """Desugar one themeConvention entry into its list of predicates.

    The named types are sugar over the predicate model (KTD3); the `match` form
    is what they desugar TO, and is internal — `paper_client._validate_config`
    is what keeps it out of user-authored config (KTD2a).

      {type:'class',          class:C}         -> [{class: C}]
      {type:'data-attribute', attr:A, value:V} -> [{attr: A, value: V}]
      {type:'media-query',    query:Q}         -> [{media: Q}, {selector: ':root'}]

    The `:root` anchor on media-query is load-bearing: a media predicate
    constrains only the enclosing at-rule chain, never which block inside it is
    selected, so without it every rule in the dark @media would match."""
    if "match" in conv:
        return list(conv["match"])
    ctype = conv.get("type")
    if ctype == "file":
        # A file convention names a DIFFERENT text; there is nothing in this
        # text's block context to predicate on (KTD3). It is resolved at load
        # and never reaches the predicate walk, so desugaring it would be a
        # category error — returning [] here would silently match nothing,
        # which reads downstream as "no token varies by theme".
        raise ValueError(
            "a 'file' convention is resolved at load, not desugared into predicates"
        )
    if ctype == "class":
        return [{"class": conv.get("class")}]
    if ctype == "data-attribute":
        return [{"attr": conv.get("attr"), "value": conv.get("value")}]
    if ctype == "media-query":
        return [{"media": conv.get("query")}, {"selector": ":root"}]
    raise ValueError(f"unknown themeConvention type: {ctype!r}")


def _class_pattern(cls):
    """A boundary-anchored matcher for `.cls` (KTD4): the class token must end
    at a non-identifier character, so `.wcs-dark` does not match `.wcs-darker`
    or `.wcs-dark-alt`.

    Two boundaries beyond the trailing-identifier one, both real false positives:

    - A CSS identifier ESCAPE (`\\:`) continues the same identifier, so a bare
      trailing-char check reads `.dark\\:text-white` as `.dark`. That matters a
      lot: Tailwind v4's default `darkMode: 'class'` token is literally `dark`,
      so in a bundled stylesheet every `.dark\\:*` utility would be mistaken for
      the dark scope. Reject a `\\` immediately after the class token.
    - A LEADING `\\` means the dot itself is escaped (part of an identifier, not
      a class delimiter), so require the `.` not be preceded by a backslash."""
    return re.compile(r"(?<!\\)\." + re.escape(cls) + r"(?![A-Za-z0-9_-])(?!\\)")


def _attr_pattern(attr, value):
    """A matcher for `[attr="value"]` — quoting-tolerant. The brackets give this
    one boundary safety for free."""
    return re.compile(
        r"\[\s*" + re.escape(attr) + r"\s*=\s*[\"']?" + re.escape(value) + r"[\"']?\s*\]"
    )


_QUOTED = re.compile(r"""(['"])(?:\\.|(?!\1).)*\1""")


def _mask_quoted(member):
    """Blank out quoted attribute VALUES, preserving length and the quotes.

    A class token that appears inside a quoted attribute value is text, not a
    class selector — `a[href$=".dark"]` must not satisfy a `{class: "dark"}`
    predicate. Masking the value (rather than deleting it) keeps offsets stable
    so the surrounding selector still matches normally."""
    return _QUOTED.sub(lambda m: m.group(1) + " " * (len(m.group(0)) - 2) + m.group(1), member)


def _match_selector_predicate(pred, member):
    """Does one selector-level predicate hold for a single selector group
    member (`member` is one comma-separated part, already whitespace-normal)?"""
    if "class" in pred:
        return bool(_class_pattern(pred["class"]).search(_mask_quoted(member)))
    if "attr" in pred:
        return bool(_attr_pattern(pred["attr"], pred["value"]).search(member))
    if "selector" in pred:
        return member == _norm_ws(pred["selector"])
    raise ValueError(f"unrecognized scope predicate: {pred!r}")


def _match_media_predicate(pred, context):
    """Does an enclosing @media in `context` match this predicate's query?

    EXACT (whitespace-insensitive) comparison — a compound query that merely
    CONTAINS the target (`… and (min-width: 800px)`) is a different scope and
    must not be grabbed as the dark scope."""
    target = _canon_media(pred["media"])
    return any(
        name == "media" and _canon_media(prelude) == target for name, prelude in context
    )


def _matches(preds, context, selector):
    """True when every predicate holds for this block's context.

    At-rule predicates are tested against the enclosing chain; selector-level
    predicates must all hold for the SAME selector group member, so
    `.wcs-theme, .wcs-dark` does not satisfy a two-class conjunction."""
    sel_preds = [p for p in preds if "media" not in p]
    for pred in preds:
        if "media" in pred and not _match_media_predicate(pred, context):
            return False
    # A match list with no selector-level predicate would select every block
    # inside the at-rule; desugaring guarantees an anchor, so this is a
    # malformed internal predicate list rather than a "matches everything".
    if not sel_preds:
        raise ValueError(
            "a scope match list needs at least one selector-level predicate: "
            f"{preds!r}"
        )
    if selector.startswith("@"):
        return False
    return any(
        all(_match_selector_predicate(p, _norm_ws(member)) for p in sel_preds)
        for member in selector.split(",")
    )


def _document_scope_decls(blocks):
    """Merge every unconditional document-scope block's declarations.

    Shared by the base scope and by a `file` convention's dark scope, so
    "the scope of a theme file" has exactly one definition (KTD2)."""
    # Merge in three tiers: html < :root < body. Two different rules are at
    # work and neither source order nor specificity alone gets both right.
    #   html vs :root — the SAME element. `:root` is (0,1,0), `html` is
    #     (0,0,1), so `:root` wins whichever appears later.
    #   body vs either — a DIFFERENT, deeper element. Custom properties
    #     inherit, so a declaration on `body` shadows the root value for every
    #     rendered descendant. Specificity never enters into it; body wins.
    # Getting the second one backwards synced the one value the page never
    # displays. Source order still breaks ties WITHIN a tier.
    html_t, root_t, body_t = {}, {}, {}
    for context, selector, body in blocks:
        if context:
            continue
        if not _is_document_scope(selector):
            continue
        parts = [p.strip() for p in selector.split(",")]
        if any(p == "body" for p in parts):
            target = body_t
        elif any(p == ":root" for p in parts):
            target = root_t
        else:
            target = html_t
        target.update(_parse_decls(body))
    decls = dict(html_t)
    decls.update(root_t)
    decls.update(body_t)
    return decls


def _base_decls(blocks):
    """Merge the declarations of every base block, in source order.

    The base is a bare document scope (`:root`/`html`/`body`) with no CONDITIONAL
    at-rule in its context — one inside `@layer` qualifies, one inside `@media`
    does not. Multiple base blocks merge in tiers — `html` < `:root` < `body`,
    matching how a browser resolves them — with source order breaking ties
    within a tier."""
    return _document_scope_decls(blocks)


def _scope_decls(blocks, conv, dark_blocks=None):
    """Merge the declarations of every block matching one convention's scope,
    in source order. Later declarations win, as they do in CSS.

    A `file` convention names a DIFFERENT text (KTD3), so its declarations come
    from `dark_blocks` — that file's own blocks — and its scope within that file
    is the DOCUMENT scope, the same rule as the base (KTD2). Everything else is a
    predicate over the blocks of the text being parsed."""
    if conv.get("type") == "file":
        if dark_blocks is None:
            # Never fall through to "no blocks matched". An empty dark scope
            # reads downstream as "no token varies by theme", which sync applies
            # by DELETING every -dark twin.
            raise ValueError(
                "a 'file' convention needs its file's blocks; load_source must "
                "supply them (see resolve_dark_texts)"
            )
        return _document_scope_decls(dark_blocks)
    preds = desugar_convention(conv)
    decls = {}
    for context, selector, body in blocks:
        if _matches(preds, context, selector):
            decls.update(_parse_decls(body))
    return decls


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
    """A short human label for a convention's predicate conjunction, used in
    warning text (origin KTD3's disagreement warning).

    The `:root` anchor a media-query desugars to is dropped from the label when
    an at-rule part is present — it is machinery, not something the user wrote,
    and keeping it out holds the existing warning text unchanged."""
    try:
        preds = desugar_convention(conv)
    except ValueError:
        return str(conv.get("type"))
    at_parts = []
    sel_parts = []
    for pred in preds:
        if "media" in pred:
            at_parts.append(f'@media {pred["media"]}')
        elif "class" in pred:
            sel_parts.append(f'.{pred["class"]}')
        elif "attr" in pred:
            sel_parts.append(f'[{pred["attr"]}="{pred["value"]}"]')
        elif "selector" in pred:
            sel_parts.append(pred["selector"])
    if at_parts and sel_parts == [":root"]:
        sel_parts = []
    return " ".join(at_parts + ["".join(sel_parts)]).strip()


# --- declaration parsing + effective-value resolution ------------------------


# Declarations the parser KNOWS it failed to read — an unterminated string or an
# unclosed paren swallows the rest of its block, and which names were lost is
# precisely what we cannot determine. Recorded rather than only logged, because
# the pipeline used to print "any declaration after it was not read" and then
# delete exactly that token.
_PARSE_LOSS = []


def parse_loss():
    """Malformed-source events from the last parse, as (token, reason)."""
    return list(_PARSE_LOSS)


def clear_parse_loss():
    _PARSE_LOSS.clear()


def _iter_decls(body):
    """Yield (name, raw_value) for each custom-property declaration in a body.

    The value is scanned character-wise rather than regex-matched, which buys
    three real-world robustness properties a `[^;]+;` grab cannot have (R9):

      - A `;` inside a quoted string or inside `url()` does NOT end the value,
        so a data URI survives whole instead of truncating mid-string.
      - The trailing `;` is OPTIONAL at end of body, so the last declaration in
        a block is captured. This is also why minified CSS used to parse to
        nothing: a minifier drops exactly that terminator.
      - Parens nest to any depth, so `linear-gradient(rgba(…), …)` is one value.

    Scanning resumes PAST each value, so a `var(--x)` inside a value is never
    re-read as a declaration of its own."""
    pos = 0
    n = len(body)
    while True:
        m = _DECL_NAME.search(body, pos)
        if not m:
            return
        i = start = m.end()
        depth = 0
        quote = None
        stray_close = False
        while i < n:
            c = body[i]
            if quote is not None:
                if c == "\\":
                    i += 2
                    continue
                if c == quote:
                    quote = None
            elif c in "\"'":
                quote = c
            elif c == "(":
                depth += 1
            elif c == ")":
                # CLAMPED at zero. An unmatched extra `)` — `--a: red);`, or the
                # very ordinary `calc(100% - 10px))` typo — would otherwise drive
                # depth negative, and once negative the `depth == 0` test below
                # never fires again, so the value swallows every following
                # declaration to end-of-block. Those tokens then vanish from the
                # parse, and a token missing from a parse becomes a DELETE in the
                # sync diff. Clamping keeps `;` working as a boundary, so the
                # rest of the block still parses; `stray_close` remembers that
                # the source was malformed so it can be reported.
                if depth == 0:
                    stray_close = True
                else:
                    depth -= 1
            elif c == ";" and depth == 0:
                break
            i += 1
        # Malformed source — report it rather than losing declarations quietly.
        # An unterminated string or an unclosed `(` still swallows to end-of-body
        # (there is no safe recovery point); a stray `)` is recovered above but
        # is still worth naming, since the value itself is now suspect.
        if i >= n and (quote is not None or depth > 0):
            what = "unterminated string" if quote is not None else "unbalanced parentheses"
            _PARSE_LOSS.append((f"--{m.group(1)}", what))
            _log(
                f"--{m.group(1)}: {what} — the value ran to the end of its block, so any "
                "declaration after it was not read. Check the source for a missing "
                f"{'quote' if quote is not None else ')'}."
            )
        elif stray_close:
            _log(
                f"--{m.group(1)}: unmatched ')' in the value. The declaration boundary was "
                "recovered so later declarations still parse, but check this value."
            )
        yield m.group(1), body[start:i]
        pos = i + 1


def _parse_decls(body):
    """Return an ordered dict of `--name` -> raw value (names lowercased).

    `body` must already be block-local (children excised by _split_body).
    `!important` is stripped from the value; a declaration whose value is empty
    after stripping is not a token and is skipped."""
    decls = {}
    for name, val in _iter_decls(body):
        val = _IMPORTANT.sub("", val.strip()).strip()
        if not val:
            continue
        decls["--" + name.lower()] = val
    return decls


def _is_balanced(s):
    """True when every paren and quote in `s` closes. Used to reject a composite
    value that merely LOOKS like one aliased var() — see var_alias."""
    depth = 0
    quote = None
    esc = False
    for c in s:
        if esc:
            esc = False
        elif quote is not None:
            if c == "\\":
                esc = True
            elif c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0 and quote is None


def var_alias(value):
    """Split a pure `var()` alias into (referent, fallback); (None, None) if the
    value is not a single alias. `fallback` is None when none was written.

    The balance check is load-bearing. `_VAR`'s fallback group is loose enough
    that `var(--a, #eee) var(--b, #fff)` would otherwise match with a fallback
    of `#eee) var(--b, #fff` — reading a two-value composite as an alias to
    `--a` and silently discarding the second half."""
    if value is None:
        return None, None
    m = _VAR.match(value.strip())
    if not m:
        return None, None
    fallback = m.group(2)
    if fallback is not None and not _is_balanced(fallback):
        return None, None
    return m.group(1).lower(), fallback


def _alias_of(raw):
    """Referent (`--other`) when raw is a `var(--other[, fallback])` alias."""
    return var_alias(raw)[0]


def light_dark_args(value):
    """Top-level arguments of a whole-value `light-dark(…)` call, or None when
    `value` is not such a call (KTD9).

    Splitting is PAREN- and STRING-aware, so either side may itself be a
    function: `light-dark(rgba(0,0,0,.5), rgba(255,255,255,.5))` is TWO
    arguments, not four. A naive `split(",")` here would hand the caller
    `rgba(0` as the light value — a plausible-looking wrong color, which is
    exactly the silent-failure class this module exists to avoid.

    Arity is NOT enforced here: a well-formed call has two arguments, but the
    caller is the one that can name the offending token in a warning, so this
    returns whatever it found and lets the caller judge."""
    if value is None:
        return None
    m = _LIGHT_DARK.match(value.strip())
    if not m:
        return None
    inner = m.group(1)
    # `light-dark(a,b) light-dark(c,d)` matches the regex (it ends in `)`) with
    # an unbalanced inner; it is a composite value, not one call.
    if not _is_balanced(inner):
        return None
    args = []
    depth = 0
    quote = None
    start = 0
    i = 0
    n = len(inner)
    while i < n:
        c = inner[i]
        if quote is not None:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == "," and depth == 0:
            args.append(inner[start:i].strip())
            start = i + 1
        i += 1
    args.append(inner[start:].strip())
    return args


def _light_dark_pair(value):
    """(light, dark) for a well-formed `light-dark(A, B)`, else None.

    None covers both "not a light-dark() call" and "malformed one" — callers
    that need to WARN about the malformed case ask light_dark_args directly."""
    args = light_dark_args(value)
    if args is None or len(args) != 2 or not all(args):
        return None
    return args[0], args[1]


def _resolve(name, primary, fallback, side="light", malformed=None):
    """Resolve a token to its effective literal in one scope.

    `primary` is the scope's own dict; `fallback` (base) is consulted when the
    token/referent is absent from `primary` (dark falls through to base).
    Chases var() aliases until a literal is reached. Cycle-guarded.

    `side` selects which half of a `light-dark(A, B)` value is taken (KTD9).
    The split happens INSIDE the chase loop, not after it, for two reasons: a
    light-dark() can be reached through an alias (`--surface: var(--base)` where
    `--base` is the light-dark), and either half can itself be a var() that
    still needs chasing (`light-dark(var(--x), var(--y))`).

    `malformed`, when given, is a set that collects (token, value) for any
    light-dark() call that did not have exactly two non-empty arguments. Such a
    value is left ALONE — passed through as an opaque literal — rather than
    guessed at, and the caller warns about it. Guessing here (taking the single
    argument for both sides) would produce a token that looks correctly parsed
    and syncs a wrong value into Paper with nothing to notice."""
    seen = set()
    cur = name
    while cur not in seen:
        seen.add(cur)
        raw = primary.get(cur)
        if raw is None and fallback is not None:
            raw = fallback.get(cur)
        if raw is None:
            return None
        pair = _light_dark_pair(raw)
        if pair is not None:
            raw = pair[0] if side == "light" else pair[1]
        elif malformed is not None and light_dark_args(raw) is not None:
            malformed.add((cur, _norm_ws(raw)))
        ref, _fallback = var_alias(raw)
        if ref is not None:
            cur = ref
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
VAR_ALIAS_RE = _VAR  # compiled regex matching a `var(--x[, fallback])` alias
# Prefer var_alias() over VAR_ALIAS_RE: the regex ALONE over-matches a composite
# value (see var_alias), and it hands back a fallback the caller must decide
# what to do with. Both halves are seam contract — emit_tokens consumes them.
split_var_alias = var_alias  # (referent, fallback) | (None, None)
normalize_hex = _normalize_hex  # uppercase every hex run in a value (idempotent)
primary_convention = _primary_convention  # the primary themeConvention resolver


def parse_with_diagnostics(text, conventions, prefix=None, dark_texts=None):
    """Parse `text` into the base+dark token model, returning both the token
    records and any warnings.

    Returns {"tokens": [record, …], "warnings": [str, …]}.

    `conventions` is the config `themeConventions` list. `prefix`, when a
    non-empty string, restricts output to custom properties whose name starts
    with it; None/"" includes all."""
    # Per-parse, not cumulative — a stale entry from an earlier call would
    # refuse a prune on a source that is perfectly readable.
    _PARSE_LOSS.clear()
    text = strip_comments(text)
    blocks = _collect_blocks(text)
    base = _base_decls(blocks)

    # A `file` convention's dark scope lives in its own text (KTD3). Collect
    # those blocks once, keyed by the convention's index in the array.
    dark_texts = dark_texts or {}
    # strip_comments FIRST, exactly as the base text is treated at the top of
    # this function. Without it a `// note` line above a rule is swallowed into
    # that rule's selector ("//ground surface\n\n:root"), which then matches no
    # scope — and a file convention that matches nothing is an empty dark scope,
    # i.e. every -dark twin looks deleted.
    dark_blocks = {i: _collect_blocks(strip_comments(txt)) for i, txt in dark_texts.items()}

    def _decls_for(conv):
        i = conventions.index(conv)
        return _scope_decls(blocks, conv, dark_blocks.get(i))

    primary = _primary_convention(conventions)
    dark = _decls_for(primary)

    warnings = []
    # Cross-check every non-primary convention against the primary (KTD3): for a
    # token both scopes DECLARE, a disagreeing effective dark value is a warning.
    for conv in conventions:
        if conv is primary:
            continue
        other = _decls_for(conv)
        for name in sorted(set(dark) & set(other)):
            pv = _normalize_hex(_resolve(name, dark, base, "dark"))
            ov = _normalize_hex(_resolve(name, other, base, "dark"))
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
        malformed = set()
        light_val = _normalize_hex(_resolve(name, base, None, "light", malformed))
        dark_val = _normalize_hex(_resolve(name, dark, base, "dark", malformed))

        # KTD9 alias fields. A light-dark() in the BASE declaration carries both
        # sides, so its second argument is where the dark alias comes from when
        # no dark scope declares the token. The `name in dark` branch keeps this
        # backward-compatible: absent a light-dark(), dark_alias is read from the
        # dark scope alone, exactly as before.
        base_raw = base.get(name)
        base_pair = _light_dark_pair(base_raw)
        light_alias, light_fb = var_alias(base_pair[0] if base_pair else base_raw)
        if name in dark:
            dark_alias, dark_fb = var_alias(dark.get(name))
        elif base_pair:
            dark_alias, dark_fb = var_alias(base_pair[1])
        else:
            dark_alias, dark_fb = None, None

        # A malformed light-dark() is passed through as an opaque literal (see
        # _resolve). Say so: the token still appears in the parse, so without
        # this the only symptom is a nonsense value syncing into Paper.
        for token, value in sorted(malformed):
            msg = (
                f"{token}: {value} is not a valid light-dark() — it needs exactly "
                "two non-empty arguments. It is left as an opaque literal rather than "
                "guessed at, so classify will almost certainly DECLINE it (a "
                "light-dark(...) string matches no Paper token type). Check the "
                "'declined' list — if this token is already live in Paper, being "
                "declined drops it from the desired set and the next sync deletes it."
            )
            warnings.append(msg)
            _log("WARNING: " + msg)

        # A NESTED light-dark() — `light-dark(light-dark(#fff,#eee), #000)`. The
        # split runs once, so an inner call survives verbatim into the resolved
        # value and syncs as the literal string "light-dark(#fff,#eee)". Nesting
        # expresses nothing CSS can act on (there is no third mode), so this is
        # a source mistake rather than a shape to support — but it resolves to a
        # plausible-looking record, which is exactly the silent-wrong-answer
        # shape worth naming instead of passing through.
        for fld, val in (("light", light_val), ("dark", dark_val)):
            if isinstance(val, str) and _LIGHT_DARK.match(val.strip()):
                msg = (
                    f"{name}: the resolved {fld} value is still a light-dark() call "
                    f"({val}) — nested light-dark() is not split and will sync as a "
                    "literal string. Flatten it in the source."
                )
                warnings.append(msg)
                _log("WARNING: " + msg)

        # Two sources of dark truth for one token. The dark scope is the more
        # specific signal so it wins, but the light-dark()'s second argument is
        # now dead code in the source — the author almost certainly expects one
        # of the two to apply and cannot tell which from reading the CSS.
        if base_pair and name in dark:
            msg = (
                f"{name}: declared as light-dark(…, {base_pair[1]}) in the base scope "
                f"AND overridden in the dark scope ({_conv_label(primary)}) — the dark "
                f"scope wins, so {base_pair[1]!r} is ignored. Drop one of the two."
            )
            warnings.append(msg)
            _log("WARNING: " + msg)
        # Discarded-fallback warning: the record keeps only the referent, and
        # build_desired writes the alias back as a bare `var(--referent)`, so a
        # `var(--x, #eee)` loses its `#eee`. That fallback is what renders when
        # the referent is undefined, so dropping it CHANGES rendered output —
        # name it rather than letting it vanish silently.
        for scope, ref, fallback in (
            ("base", light_alias, light_fb),
            ("dark", dark_alias, dark_fb),
        ):
            if not ref or fallback is None:
                continue
            msg = (
                f"{name}: the {scope} alias var({ref}, {fallback}) is synced as "
                f"var({ref}) — its fallback {fallback!r} is discarded. Inline the "
                f"fallback or ensure {ref} is always defined."
            )
            warnings.append(msg)
            _log("WARNING: " + msg)
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


def parse_tokens(text, conventions, prefix=None, dark_texts=None):
    """Parse `text` into the base+dark token model (the records only).

    See parse_with_diagnostics for the record shape and semantics; this is the
    thin wrapper the deterministic-diff callers use when they don't need the
    warnings list (warnings still reach stderr)."""
    return parse_with_diagnostics(text, conventions, prefix, dark_texts)["tokens"]


# --- source loading ----------------------------------------------------------


# --- @use / @import following (multi-file sources) ----------------------------

# A module-loading at-statement: @use / @forward / @import "path" [as x] [with (…)];
# Only the quoted path matters here; everything after it is Sass semantics we
# deliberately do not implement (see the module docstring).
_AT_LOAD = re.compile(
    r"""@(use|forward|import)\s+(?:url\()?["']([^"']+)["']\)?[^;{]*;""", re.I
)

# Loads that reach outside the file graph and can't be read as text: Sass's
# built-in modules, and remote CSS.
_BUILTIN_LOAD = re.compile(r"^(sass:|https?://|//)", re.I)

# Specs a relative resolver can never find: Sass load-path / package imports.
# Reporting these as "missing" turned any SCSS entry that pulls in a package
# into a hard refusal whose only remedy was allowMissingImports — which reopens
# the deletion hole for genuinely renamed LOCAL partials at the same time. They
# are not followed, and that is expected, not an error.
_NON_RELATIVE_LOAD = re.compile(r"^(~|pkg:|@[A-Za-z0-9_-]+/)", re.I)


def _is_non_relative(spec):
    """True only when `spec` is UNAMBIGUOUSLY a load-path/package import.

    Deliberately narrow. Sass lets a relative spec omit `./`, so `@use "palette"`
    and `@use "theme/palette"` are relative — treating every non-dotted spec as
    a package made those "not followed", which silently reopened the hole the
    unresolved-import refusal exists to close. A bare multi-segment spec like
    `bootstrap/scss/variables` is genuinely indistinguishable from a local
    partial, so it stays in the refusing path: a renamed local partial and a
    package import look identical, and the safe reading is the one that refuses."""
    return bool(_NON_RELATIVE_LOAD.match(spec))


def _import_candidates(spec, from_dir):
    """Sass/CSS resolution order for one load spec, relative to `from_dir`.

    Sass allows the extension and a leading underscore (a "partial") to be
    omitted, and a directory to stand in for its `_index` file. Try the literal
    path first so an explicit `foo.css` is never shadowed by a `_foo.scss`."""
    import os

    base = os.path.normpath(os.path.join(from_dir, spec))
    head, tail = os.path.split(base)
    out = [base]
    for ext in (".scss", ".sass", ".css"):
        out.append(base + ext)
        out.append(os.path.join(head, "_" + tail + ext))
    for ext in (".scss", ".sass", ".css"):
        out.append(os.path.join(base, "_index" + ext))
        out.append(os.path.join(base, "index" + ext))
    return out


def resolve_source_graph(entry_path, read_file=None, max_depth=32, exists=None):
    """Read `entry_path` and everything it @use/@import/@forwards, depth-first.

    Returns (text, loaded, missing): the concatenated source with DEPENDENCIES
    FIRST, the list of files read in order, and the list of (spec, from_file)
    that could not be resolved.

    Dependency-first ordering is the load-bearing part. The merge is
    later-declaration-wins, and that has to agree with the cascade: an importing
    file overriding a token it pulled in must win, which it only does if its own
    text comes after its dependencies'. Reversing this silently inverts an
    override — the same wrong-value class the parser has been closing.

    A file is read at most once (Sass's own `@use` semantics, and it makes an
    import cycle terminate rather than recurse forever). `sass:*` built-ins and
    remote URLs are skipped, not treated as missing — they carry no custom
    properties we could read, and reporting them as missing would be noise.

    `read_file` and `exists` are both injectable so a git-ref source resolves
    the WHOLE graph at that ref. Injecting only the reader was not enough:
    which imports exist was still decided by the working tree, so a partial
    present at the pinned ref but renamed in the working tree was dropped from
    the graph — and its tokens deleted. `source.ref` exists precisely to
    decouple a sync from working-tree state."""
    import os

    if read_file is None:
        def read_file(path):
            with open(path, "r", encoding="utf-8") as fh:
                return fh.read()
    if exists is None:
        exists = os.path.isfile

    seen = set()
    loaded = []
    missing = []
    not_followed = []
    chunks = []

    def visit(path, depth):
        real = os.path.normpath(path)
        if real in seen:
            return
        seen.add(real)
        if depth > max_depth:
            missing.append((real, f"exceeded max import depth {max_depth}"))
            return
        try:
            text = read_file(real)
        except OSError as exc:
            missing.append((real, str(exc)))
            return
        here = os.path.dirname(real)
        # Comments are stripped before scanning so a commented-out @use is not
        # followed, and so a `//`-commented path can't inject a phantom edge.
        for _kw, spec in _AT_LOAD.findall(strip_comments(text)):
            if _BUILTIN_LOAD.match(spec):
                continue
            if _is_non_relative(spec):
                # A build tool's load path resolves these; a relative walk never
                # can. Not an error — just not followed.
                not_followed.append((spec, real))
                continue
            for cand in _import_candidates(spec, here):
                if exists(cand):
                    visit(cand, depth + 1)
                    break
            else:
                missing.append((spec, real))
        # AFTER the recursion: dependencies first, this file's own text last.
        # `loaded` is appended here too so it reports the CONCATENATION order,
        # not the visit order — a diagnostic that says "dependencies first" and
        # then lists the entry file first is worse than no diagnostic.
        chunks.append(text)
        loaded.append(real)

    visit(entry_path, 0)
    if not_followed:
        specs = sorted({s for s, _ in not_followed})
        _log(
            f"not followed (resolved by your build tool's load path, not relatively): "
            f"{', '.join(specs)}. Tokens they declare are not in this parse."
        )
    return "\n".join(chunks), loaded, missing


def file_convention_needs_repo(conventions):
    """A message when `conventions` contains a `file` type but the caller has no
    repo to resolve its theme file against — else None.

    Shared by every single-file CLI entry point (`sync build-desired`,
    `status drift`, `emit-from-file`, `emit roundtrip`, this module's own CLI).
    Each of those was fixed one at a time as it was reported, and each fix
    missed the siblings; one predicate is what stops the class regrowing."""
    for i, conv in enumerate(conventions or []):
        if isinstance(conv, dict) and conv.get("type") == "file":
            return (
                f"themeConventions[{i}] is a 'file' convention, whose dark theme lives in "
                f"{conv.get('path')!r} — but this subcommand reads a single file and has no "
                "repo to resolve that against. Use the `run --repo PATH` form instead."
            )
    return None


def _read_at_ref(cfg, rel, ref):
    """Read `rel` at git `ref` from the config's repo. Shared by load_source and
    resolve_dark_texts so both halves of a theme come from ONE revision."""
    import subprocess

    repo = cfg.get("_repo")
    if not repo:
        raise RuntimeError(
            "config is missing '_repo'; load it via read_config before reading at a ref"
        )
    spec = f"{ref}:{rel}"
    try:
        result = subprocess.run(
            ["git", "-C", repo, "show", spec],
            capture_output=True, text=True, check=True,
        )
    except FileNotFoundError as exc:
        raise RuntimeError(f"git is not available to read {spec}: {exc}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or "").strip() or (exc.stdout or "").strip()
        raise RuntimeError(
            f"could not read source at ref '{spec}' in {repo}: {detail}"
        ) from exc
    return result.stdout


def _guard_theme_not_empty(txt, index, whence):
    """Refuse a theme file that yields an EMPTY DARK SCOPE, for any reason.

    The first version of this guard asked "does the text declare any custom
    property", which is a PROXY for the hazard rather than the hazard itself.
    A theme file scoped by class — `html.dark { --accent: … }` — declares plenty
    and still resolves to nothing, because a file convention reads the DOCUMENT
    scope (`:root`/`html`/`body`). The guard went green while the thing it
    guards was red, and every `-dark` twin was deleted at exit 0.

    So assert on the resolution the parse will actually perform. The two arms
    give different advice, because the fixes differ: nothing declared at all is
    a wrong path or a truncated file; declared-but-out-of-scope means the theme
    is scoped by a selector, which is what the `class` convention is for."""
    blocks = _collect_blocks(strip_comments(txt))
    if _document_scope_decls(blocks):
        return txt

    if not declared_names(txt):
        raise RuntimeError(
            f"themeConventions[{index}] (file): {whence} declares no custom "
            "properties. Refusing rather than treating the dark theme as empty — "
            "an empty dark scope would delete every -dark twin in the target file."
        )

    selectors = sorted({
        sel.strip() for ctx, sel, _ in blocks if not ctx and sel.strip()
    })[:4]
    raise RuntimeError(
        f"themeConventions[{index}] (file): {whence} declares custom properties, but "
        f"none at document scope (:root/html/body) — they are under {selectors}. A "
        "'file' convention reads the document scope, so the dark theme would resolve "
        "EMPTY and every -dark twin in the target file would be deleted. If the theme "
        "is scoped by a selector, use a 'class' or 'data-attribute' convention instead "
        "of 'file'."
    )


def resolve_dark_texts(cfg):
    """Read the text of every `file` convention's theme file.

    Returns {convention_index: text}. Honors `source.followImports` for each, so
    a dark theme split across partials resolves the same way the base does.

    A missing or unreadable file RAISES (R7). Returning an empty string would
    give the convention an empty dark scope, which reads as "no token varies by
    theme" — and sync applies that by deleting every `-dark` twin in the Paper
    file. A loud failure is the only safe direction here."""
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from paper_client import resolve_repo_path  # noqa: E402

    follow = bool((cfg.get("source") or {}).get("followImports"))
    ref = (cfg.get("source") or {}).get("ref")
    out = {}
    for i, conv in enumerate(cfg.get("themeConventions") or []):
        if conv.get("type") != "file":
            continue
        rel = conv.get("path")
        abs_path = resolve_repo_path(cfg, rel)
        if follow:
            # ref must compose with followImports, not be shadowed by it. The
            # graph walk already accepts an injectable reader for exactly this;
            # without it the base came from the pinned revision and the theme
            # from the working tree — the cross-revision diff this whole ref
            # handling exists to prevent.
            reader, exists = None, None
            if ref:
                repo_root = cfg.get("_repo") or ""
                reader, exists = _ref_readers(cfg, ref, repo_root)

            text, loaded, missing = resolve_source_graph(
                abs_path, read_file=reader, exists=exists
            )
            for spec, whence in missing:
                _log(
                    f"unresolved import {spec!r} (from {whence}) in theme file {rel!r} — "
                    "its tokens are NOT in this parse."
                )
            # Record, don't just log — round 5 made this a refusal for the BASE
            # graph and the theme graph kept the old log-and-drop behaviour, so
            # a renamed partial under the dark theme still deleted its twins.
            # Extend rather than clear: load_source ran first and its misses
            # must survive to the same check.
            _MISSING_IMPORTS.extend(missing)
            if not loaded:
                raise RuntimeError(
                    f"themeConventions[{i}] (file): could not read theme file {abs_path}"
                )
            out[i] = _guard_theme_not_empty(text, i, f"the theme graph rooted at {rel!r}")
            continue
        try:
            # Honour source.ref for the theme file too. Reading the base at a
            # pinned revision and its dark half from the working tree computes
            # every theme delta ACROSS TWO REVISIONS — uncommitted dark edits
            # surface as theme variance against a pinned base, and sync writes
            # those phantom twins. source.ref exists to sync a known revision;
            # reading only half of it at that revision defeats the point.
            if ref:
                out[i] = _guard_theme_not_empty(_read_at_ref(cfg, rel, ref), i, f"{rel!r} at ref {ref!r}")
                continue
            with open(abs_path, "r", encoding="utf-8") as fh:
                out[i] = _guard_theme_not_empty(fh.read(), i, repr(rel))
        except OSError as exc:
            raise RuntimeError(
                f"themeConventions[{i}] (file): could not read theme file {abs_path}: {exc}. "
                "Refusing rather than treating the dark theme as empty — an empty dark "
                "scope would delete every -dark twin in the Paper file."
            ) from exc
    return out


# Unresolved imports from the most recent load_source call. `missing` used to be
# logged and dropped, so a renamed partial's tokens reached neither the parse nor
# the protection set and were DELETED — the log line even predicted it. Callers
# read this and refuse.
_MISSING_IMPORTS = []


def missing_imports():
    """Unresolved import specs from the last load_source call, as (spec, from)."""
    return list(_MISSING_IMPORTS)


def _ref_readers(cfg, ref, repo_root):
    """(read_file, exists) that resolve against a git ref instead of the tree."""
    import os
    import subprocess

    def _rel(path):
        return os.path.relpath(path, repo_root)

    def read_file(path):
        return _read_at_ref(cfg, _rel(path), ref)

    def exists(path):
        try:
            return subprocess.run(
                ["git", "-C", repo_root, "cat-file", "-e", f"{ref}:{_rel(path)}"],
                capture_output=True,
            ).returncode == 0
        except OSError:
            return False

    return read_file, exists


def commented_only_names(text, prefix=None):
    """Names that appear ONLY inside comments — protected, but possibly retired.

    Over-protection is the right default (see declared_names), but it must not
    be silent: commenting a declaration out is a normal way to retire a token,
    and the raw sweep pins it in the target file forever with no signal."""
    raw = text or ""
    stripped = strip_comments(raw)
    in_raw = {"--" + m.group(1).lower() for m in _DECL_NAME.finditer(raw)}
    in_stripped = {"--" + m.group(1).lower() for m in _DECL_NAME.finditer(stripped)}
    names = in_raw - in_stripped
    if prefix:
        names = {n for n in names if n.startswith(prefix)}
    return names


def declared_names(text, prefix=None):
    """Every custom-property name the source TEXT declares, found by a flat sweep
    that does not depend on the block walk succeeding.

    This exists because absence from the desired set is ambiguous: the source may
    have dropped the token, or we may simply have failed to read it — and only
    the first meaning may delete. Deriving that distinction from records that
    SURVIVED parsing cannot work, because a token the parser never saw leaves no
    record to inspect. A textual sweep sees it regardless of whether the block
    walk, the classifier, or a scope predicate handled it correctly, so a future
    parser gap of a shape nobody anticipated is protected by construction rather
    than by another guard."""
    # Union the RAW text with the comment-stripped text. If strip_comments ever
    # truncates wrongly again, the raw sweep still sees the declaration, so the
    # failure lands on the OVER-protect side (a stale token) instead of the
    # destructive one (a deleted token). The cost is that a name appearing only
    # inside a comment is protected — harmless, since it can never have reached
    # `desired` and so was never created in the target file.
    raw = text or ""
    names = {"--" + m.group(1).lower() for m in _DECL_NAME.finditer(raw)}
    names |= {"--" + m.group(1).lower() for m in _DECL_NAME.finditer(strip_comments(raw))}
    if prefix:
        names = {n for n in names if n.startswith(prefix)}
    return names


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
    if ref and not source.get("followImports"):
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

    # Multi-file sources are OPT-IN via `source.followImports`. Default off: a
    # config written against 1.1.x must keep reading exactly one file, and
    # silently widening the token set under an existing config would change what
    # sync owns — and therefore what it can delete.
    if source.get("followImports"):
        # Compose with ref rather than letting either silently win. Reading the
        # entry file at a ref while dropping every partial it imports deleted
        # those partials' tokens — they reach neither `desired` nor the
        # protected set, because the parser never saw them.
        reader, exists = None, None
        if ref:
            repo_root = cfg.get("_repo") or ""
            reader, exists = _ref_readers(cfg, ref, repo_root)

        text, loaded, missing = resolve_source_graph(
            abs_path, read_file=reader, exists=exists
        )
        _MISSING_IMPORTS.clear()
        _MISSING_IMPORTS.extend(missing)
        for spec, whence in missing:
            _log(
                f"unresolved import {spec!r} (from {whence}) — its tokens are NOT in "
                "this parse. If it declares any, they will look deleted to sync."
            )
        if len(loaded) > 1:
            _log(f"followImports: read {len(loaded)} files, dependencies first")
        if not loaded:
            raise RuntimeError(f"could not read source file {abs_path}")
        return text

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
        help="JSON array of themeConventions (data-attribute / media-query / class).",
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
