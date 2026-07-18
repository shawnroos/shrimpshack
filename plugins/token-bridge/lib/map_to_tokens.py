#!/usr/bin/env python3
"""map_to_tokens.py — rewrite harvested literal style values back to --wcs-* token
references, matching against the theme the component was harvested in.

Unit U7 of the wcs-paper plugin.

INPUTS
------
1. The resolved token set — output of lib/parse_tokens.py: a JSON array of records
     {name, light, dark, light_alias, dark_alias}
   where `dark` is null when the token's effective value is theme-invariant. A
   token's EFFECTIVE value is `light` in the light theme, and `dark` (falling back
   to `light` when null) in the dark theme.

2. The harvested component — output of lib/harvest.py: a success envelope
     {ok, name, selector, route, theme, root, nodes}
   where `nodes` is a flat list of {path, tag, text, styles, theme} and each
   `styles` value is a getComputedStyle literal (hex/rgb color, px length, ...).

WHAT IT DOES
------------
For each node, every style literal is compared — by NORMALIZED equivalence, not
string identity — against every token's EFFECTIVE value FOR THE NODE'S HARVESTED
THEME:

  - match in the harvested theme      -> the literal is replaced by `var(--wcs-x)`.
  - match only in the OTHER theme      -> the literal is left as-is and a record is
                                          added to `near_misses` (a human can then
                                          see the theme mismatch).
  - no match in either theme           -> the literal is left unchanged.

So a dark-rendered #00b72b matches --wcs-accent (dark-effective #00B72B), and is
NOT left unmapped by comparing it against the light-effective #37D895.

NORMALIZATION (both sides go through normalize_value before comparison)
  - Colors collapse to a canonical `rgba(r,g,b,a)` tuple, so
    #ccc == #cccccc == #ccccccff == rgb(204,204,204) == rgba(204,204,204,1).
  - A bare `0` length token is normalized to `0px` (so `0` == `0px`); other px
    values compare as-is (`8px` == `8px`).
  This makes matching independent of the exact serialization the browser emitted.

DETERMINISTIC TIE-BREAK
  When a literal matches MORE THAN ONE token's effective value (e.g. an accent
  color that a primitive AND its semantic aliases all resolve to), the winner is
  chosen deterministically:
    1. prefer a SEMANTIC (Tier-2) token over a PRIMITIVE (Tier-1). A primitive is
       detected by name shape — its final `-`-delimited segment is all digits
       (a numbered scale step, e.g. `--wcs-green-500`); everything else is
       semantic (e.g. `--wcs-accent`, `--wcs-nav-item-active-fg`).
    2. among tokens of the same tier, pick the alphabetically-first `name`.
  Same input -> same winner, every run.

CLI:
  cat harvested.json | python3 map_to_tokens.py --tokens tokens.json   # -> JSON
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys

# A color literal: a hex triplet/quad/sextet/octet, or an rgb()/rgba() function.
_COLOR_RE = re.compile(r"#[0-9a-fA-F]+|rgba?\([^)]*\)", re.IGNORECASE)


def _canon_color(tok: str):
    """Canonicalize one color literal to `rgba(r,g,b,a)` (a as 3-decimal 0..1),
    or return None when the token isn't a color we can parse (caller keeps the
    original text unchanged in that case)."""
    tok = tok.strip()
    try:
        if tok.startswith("#"):
            h = tok[1:]
            if len(h) == 3:
                r, g, b = (int(c * 2, 16) for c in h)
                a255 = 255
            elif len(h) == 4:
                r, g, b, a255 = (int(c * 2, 16) for c in h)
            elif len(h) == 6:
                r, g, b = (int(h[i : i + 2], 16) for i in (0, 2, 4))
                a255 = 255
            elif len(h) == 8:
                r, g, b, a255 = (int(h[i : i + 2], 16) for i in (0, 2, 4, 6))
            else:
                return None  # 5/7-digit hex is not valid CSS
            a = a255 / 255.0
        else:
            inner = tok[tok.index("(") + 1 : tok.rindex(")")]
            # Legacy `r, g, b, a` and modern `r g b / a` (the form Paper stores
            # and getComputedStyle returns) both parse here. Alpha may be a
            # 0..1 number or a percentage.
            if "/" in inner:
                rgb_part, _, a_part = inner.partition("/")
                comps = rgb_part.replace(",", " ").split()
                a_str = a_part.strip() or None
            elif "," in inner:
                parts = [p.strip() for p in inner.split(",") if p.strip() != ""]
                comps, a_str = parts[:3], (parts[3] if len(parts) == 4 else None)
            else:
                comps = inner.split()
                a_str = None
            if len(comps) != 3:
                return None
            r, g, b = (int(round(float(c))) for c in comps)
            if a_str is None:
                a = 1.0
            elif a_str.endswith("%"):
                a = float(a_str[:-1]) / 100.0
            else:
                a = float(a_str)
    except (ValueError, IndexError):
        return None
    return f"rgba({r},{g},{b},{a:.3f})"


def normalize_value(value):
    """Canonical form of a style value for equivalence comparison.

    Colors -> canonical rgba() tuples; a standalone `0` length -> `0px`. Returns
    None for None, "" for empty. Idempotent (normalizing twice == once)."""
    if value is None:
        return None
    s = str(value).strip().lower()
    if s == "":
        return ""
    # `transparent` is the keyword Paper stores as #00000000 — canonicalize both
    # to the same rgba tuple so a transparent token doesn't churn every sync.
    s = re.sub(r"\btransparent\b", "rgba(0,0,0,0)", s)
    s = _COLOR_RE.sub(lambda m: _canon_color(m.group(0)) or m.group(0).lower(), s)
    # Normalize whitespace and treat a bare zero length as `0px`.
    parts = ["0px" if p == "0" else p for p in s.split()]
    return " ".join(parts)


def effective_value(token: dict, theme: str):
    """The token's effective literal in `theme`: dark falls back to light when the
    token's `dark` is null (theme-invariant)."""
    if theme == "dark":
        dark = token.get("dark")
        return dark if dark is not None else token.get("light")
    return token.get("light")


def _is_primitive(name: str) -> bool:
    """A Tier-1 primitive is a numbered scale step: its final `-`-segment is all
    digits (e.g. --wcs-green-500). Everything else is treated as semantic."""
    return name.rsplit("-", 1)[-1].isdigit()


def pick_token(names) -> str:
    """Deterministic tie-break: semantic over primitive, then alphabetical."""
    semantic = sorted(n for n in names if not _is_primitive(n))
    primitive = sorted(n for n in names if _is_primitive(n))
    return (semantic or primitive)[0]


def build_index(tokens, theme: str) -> dict:
    """normalized-effective-value -> winning token name, for one theme."""
    buckets: dict = {}
    for tok in tokens:
        norm = normalize_value(effective_value(tok, theme))
        if not norm:
            continue
        buckets.setdefault(norm, set()).add(tok["name"])
    return {norm: pick_token(names) for norm, names in buckets.items()}


def map_styles(styles: dict, theme: str, light_idx: dict, dark_idx: dict):
    """Rewrite one styles dict for a node harvested in `theme`.

    Returns (new_styles, near_misses) where near_misses is a list of
    {prop, value, token, theme} for literals that matched only the other theme.
    """
    own_idx = dark_idx if theme == "dark" else light_idx
    other_idx = light_idx if theme == "dark" else dark_idx
    other_theme = "light" if theme == "dark" else "dark"

    new_styles: dict = {}
    near_misses = []
    for prop, value in styles.items():
        norm = normalize_value(value)
        if norm and norm in own_idx:
            new_styles[prop] = f"var({own_idx[norm]})"
        else:
            new_styles[prop] = value
            if norm and norm in other_idx:
                near_misses.append(
                    {
                        "prop": prop,
                        "value": value,
                        "token": other_idx[norm],
                        "theme": other_theme,
                    }
                )
    return new_styles, near_misses


def _map_node_tree(node: dict, envelope_theme: str, light_idx: dict, dark_idx: dict):
    """Rewrite styles across a nested root tree (replacements only — near-misses are
    collected from the authoritative flat `nodes` list, not here, to avoid dupes)."""
    theme = node.get("theme") or envelope_theme
    node["styles"], _ = map_styles(node.get("styles", {}) or {}, theme, light_idx, dark_idx)
    for child in node.get("children", []) or []:
        _map_node_tree(child, envelope_theme, light_idx, dark_idx)


def map_component(harvest: dict, tokens: list) -> dict:
    """Map a harvested component envelope, returning a copy with style literals
    rewritten to var(--wcs-*) refs and a top-level `near_misses` list."""
    out = copy.deepcopy(harvest)

    # A non-success envelope (error) has nothing to map.
    if not out.get("ok") or not isinstance(tokens, list):
        out["near_misses"] = []
        return out

    light_idx = build_index(tokens, "light")
    dark_idx = build_index(tokens, "dark")
    envelope_theme = out.get("theme") or "light"

    all_near_misses = []
    for node in out.get("nodes", []) or []:
        theme = node.get("theme") or envelope_theme
        new_styles, near = map_styles(
            node.get("styles", {}) or {}, theme, light_idx, dark_idx
        )
        node["styles"] = new_styles
        for nm in near:
            all_near_misses.append({"path": node.get("path"), **nm})

    # Keep the nested root tree consistent with the flattened nodes.
    if isinstance(out.get("root"), dict):
        _map_node_tree(out["root"], envelope_theme, light_idx, dark_idx)

    out["near_misses"] = all_near_misses
    return out


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Rewrite harvested style literals back to --wcs-* token refs."
    )
    parser.add_argument(
        "--tokens",
        required=True,
        help="Path to the parse_tokens.py JSON array (the resolved token set).",
    )
    parser.add_argument(
        "--harvest",
        help="Path to the harvest.py envelope JSON (default: read from stdin).",
    )
    args = parser.parse_args(argv)

    with open(args.tokens) as fh:
        tokens = json.load(fh)

    if args.harvest:
        with open(args.harvest) as fh:
            harvest = json.load(fh)
    else:
        harvest = json.loads(sys.stdin.read())

    print(json.dumps(map_component(harvest, tokens), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
