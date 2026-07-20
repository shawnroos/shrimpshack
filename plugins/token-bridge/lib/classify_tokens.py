#!/usr/bin/env python3
"""Decide each token's Paper type and which tokens are safe to write.

Reads the per-token model emitted by parse_tokens.py (a JSON array on stdin,
each record `{name, light, dark, light_alias, dark_alias}`) and annotates every
record with:

  paper_type       one of Paper's token types, or null when the token has no
                   representable Paper type (motion, shadow, filter, …)
  writable         True when paper_type is set (safe to write into Paper)
  excluded_reason  a human-readable reason when writable is False, else null

Paper's ONLY token types (there is no shadow/filter/easing/transition type):

    breakpoint  color  container  fontFamily  fontSize  fontWeight
    letterSpacing  lineHeight  radius  spacing

Classification is about the value SHAPE, which is identical for a token's light
and dark declarations — so we classify once per token off whichever resolved
literal is present (light, falling back to dark). The light/dark split is the
sync command's concern, not ours.

THE COERCION GUARD (the whole reason this plugin exists): Paper silently stores
a value that only *partially* parses as a color as a mangled solid color — e.g.
a box-shadow `0px 1px 3px #000` becomes `#000000`. So `color` is only ever
assigned to a value that matches a color pattern *in its entirety* (a strict
full-match). Anything that is not a clean single color is never `color`; when
nothing matches, the token is excluded with a reason rather than guessed.

CLI:
  … | python3 parse_tokens.py | python3 classify_tokens.py   # -> JSON array
"""

import json
import re
import sys

# --- value-shape predicates -------------------------------------------------

# A clean single hex color: #rgb / #rgba / #rrggbb / #rrggbbaa (nothing else).
_HEX_FULL = re.compile(r"#(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{3})")
# A single rgb()/rgba() functional color: 3 or 4 numeric components (the 4th,
# alpha, optional), comma- or space-separated, each optionally a percentage.
# `rgba(junk)` must NOT match — a non-color at type color is the silent-#000000
# trap the guard exists to prevent.
_NUM = r"\s*\d*\.?\d+%?\s*"
_RGB_FULL = re.compile(rf"rgba?\({_NUM}[,\s]{_NUM}[,\s]{_NUM}(?:[,/\s]{_NUM})?\)")
# A bare pixel length: 8px, 0.5px, 999px.
_PX_FULL = re.compile(r"\d*\.?\d+px")
# A bare unitless integer: 600.
_INT_FULL = re.compile(r"\d+")
# A time value anywhere in the value: 0.15s, 150ms, .2s.
_TIME = re.compile(r"(?<![\w.])\d*\.?\d+m?s(?![\w])")
# A font-stack signal: a generic family keyword or a platform font.
_FONT_STACK = re.compile(r"\b(?:sans-serif|serif|monospace|system-ui|cursive|fantasy)\b|-apple-system")


def _is_color(v):
    """True only when the ENTIRE value is one clean color. This is the coercion
    guard: a partial color (box-shadow, gradient, layered value) returns False
    so it is never mis-typed as `color` and silently mangled by Paper."""
    return (
        v == "transparent"
        or _HEX_FULL.fullmatch(v) is not None
        or _RGB_FULL.fullmatch(v) is not None
    )


def _is_px(v):
    return _PX_FULL.fullmatch(v) is not None


def _has_top_level_comma(v):
    """A comma outside any parentheses == a layered/multi-part value (box-shadow
    layers, a font stack). Commas inside rgba(…) are balanced away, so a single
    functional color reads as NOT multi-part."""
    depth = 0
    for ch in v:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        elif ch == "," and depth == 0:
            return True
    return False


# --- classification ---------------------------------------------------------


def classify_value(name, value):
    """Return (paper_type, excluded_reason). Exactly one is non-null.

    Order matters: font stacks are recognized before the multi-part exclusion
    (they carry a top-level comma), and every non-color/motion/filter shape is
    checked against a STRICT color full-match before any type is assigned."""
    if value is None:
        return None, "token has no resolved value"
    v = value.strip()

    # 1. fontFamily — a font stack (before multi-part exclusion, which its comma
    #    would otherwise trip).
    if "font-family" in name or _FONT_STACK.search(v):
        return "fontFamily", None

    # 2. Exclude by name — motion / shadow / filter have no Paper type.
    if "shadow" in name:
        return None, "shadow token: Paper has no shadow/filter type (not representable)"
    if "transition" in name:
        return None, "motion token (transition): Paper has no transition type"
    if "ease" in name or "easing" in name:
        return None, "motion token (easing): Paper has no easing type"

    # 3. Exclude by value shape — motion / filter / layered values.
    if "cubic-bezier(" in v:
        return None, "easing curve (cubic-bezier): Paper has no easing type"
    if "drop-shadow(" in v:
        return None, "filter value (drop-shadow): Paper has no filter type"
    if _TIME.search(v):
        return None, "motion duration (time value): Paper has no transition type"
    if _has_top_level_comma(v):
        # Layered value (e.g. a box-shadow). MUST NOT become `color` — the
        # coercion guard. No single Paper type represents it.
        return None, "multi-part/layered value: no single Paper type (would be mangled as color)"

    # 4. color — strict full-match only (coercion guard).
    if _is_color(v):
        return "color", None

    # 5. radius — a px length named as a radius.
    # Unitless `0` is idiomatic, spec-legal CSS and the spacing branch below
    # already accepts it. Radius omitting it was an asymmetry, not a rule —
    # and once classify validates BOTH halves, `--card-radius: 8px` in light
    # with `0` in dark declined the whole token, which DELETES the live pair
    # from the design file on the next sync.
    if (_is_px(v) or v == "0") and "radius" in name:
        return "radius", None

    # 6. spacing — a px length or bare 0 named as spacing.
    if (_is_px(v) or v == "0") and re.search(r"space|margin|padding|gap|inset", name):
        return "spacing", None

    # 7. fontWeight — a bare unitless number named as a weight.
    if _INT_FULL.fullmatch(v) and "weight" in name:
        return "fontWeight", None

    # 8. fontSize — a px length named as a font/title/text size.
    if _is_px(v) and "size" in name:
        return "fontSize", None

    # 9. Nothing matched — exclude rather than guess.
    return None, "value %r matches no Paper token type" % v


def classify_tokens(records):
    """Annotate each parsed record with paper_type / writable / excluded_reason."""
    out = []
    for rec in records:
        value = rec.get("light")
        if value is None:
            value = rec.get("dark")
        paper_type, reason = classify_value(rec["name"], value)

        # BOTH halves must be representable, not just the one the type came
        # from. The `-dark` twin is written with the type derived here, so a
        # dark value that isn't a valid instance of that type would ride into
        # Paper unchecked — `--x-dark: #{$shade100}` stored as a *color*. That
        # is the silent-wrong-value class this codebase keeps closing, and it
        # is exactly what an uncompiled Sass dark scope produces.
        if paper_type is not None:
            dark = rec.get("dark")
            if dark is not None and dark != value:
                dark_type, dark_reason = classify_value(rec["name"], dark)
                if dark_type != paper_type:
                    light_type = paper_type   # rec has no paper_type yet — that
                    paper_type = None         # key is only set on `annotated`
                    reason = (
                        f"dark value {dark!r} is not a {light_type} "
                        f"value ({dark_reason or 'type mismatch'}); declining rather than "
                        "writing it into Paper untyped"
                    )

        annotated = dict(rec)
        annotated["paper_type"] = paper_type
        annotated["writable"] = paper_type is not None
        annotated["excluded_reason"] = None if paper_type is not None else reason
        out.append(annotated)
    return out


def main(argv):
    records = json.load(sys.stdin)
    result = classify_tokens(records)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
