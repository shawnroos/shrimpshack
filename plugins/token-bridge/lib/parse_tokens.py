#!/usr/bin/env python3
"""Normalize the WCS design-token SCSS into a per-theme token model.

Two entry points, both operating on SCSS *text* (never a path) so they are
trivially fixture-testable:

  parse_tokens(text) -> list[dict]
      Parses the two flat custom-property blocks
      (`body.wcs-theme { … }` light, `body.wcs-theme.wcs-dark { … }` dark),
      resolves each token's *effective* light and dark value (chasing var()
      aliases per-theme), and emits one record per token:

        {
          "name":        "--wcs-accent",
          "light":       "#37D895",        # resolved light literal
          "dark":        "#00B72B",        # resolved dark literal, or null when
                                           # the effective value is theme-invariant
          "light_alias": "--wcs-green-500",# referent when the LIGHT declaration
                                           # is a var(), else null
          "dark_alias":  null              # referent when the DARK declaration
                                           # is a var(), else null (null if the
                                           # token has no dark declaration)
        }

      A token carries a non-null `dark` whenever its effective value differs by
      theme. That INCLUDES component aliases declared only in the light block
      whose referent is redeclared in dark (e.g. --wcs-timeline-playhead =
      var(--wcs-accent)): the alias line only appears in light, but its resolved
      value flips because --wcs-accent flips.

  parse_general(text) -> dict
      Targeted extraction of exactly --font-family from a full nested SCSS file
      (it lives inside an `html, body { … }` block amid @imports and @keyframes).
      Emits one theme-invariant record.

Normalization makes output idempotent (parsing the same input twice is
byte-identical): token names are lowercased, hex literals are uppercased,
records are sorted by name.

CLI:
  cat tokens.scss  | python3 parse_tokens.py            # -> JSON array
  cat general.scss | python3 parse_tokens.py --general  # -> JSON object
"""

import json
import re
import sys

# A custom-property declaration inside a flat block: `--name: value;`
# Values never contain a semicolon, so `[^;]+` is a safe value grab (box-shadows,
# rgba() with internal commas, cubic-bezier(), etc. all lack `;`).
_DECL = re.compile(r"--([A-Za-z0-9-]+)\s*:\s*([^;]+);")

# A pure `var(--other)` alias (no fallbacks are used anywhere in the source).
_VAR = re.compile(r"^var\(\s*(--[A-Za-z0-9-]+)\s*\)$")

# Hex color literals (3/4/6/8 digit). Uppercased for stable output.
_HEX = re.compile(r"#[0-9a-fA-F]+")


def strip_comments(text):
    """Strip `//` line comments. Guards against `://` (URL protocols) so a
    value like url(https://…) is not truncated — the token file has none, but
    the general file does."""
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


def _extract_block(text, selector_pattern):
    """Return the flat body of the first `<selector> { … }` block, or ''.
    The token blocks contain no nested braces, so `[^}]*` is exact."""
    m = re.search(selector_pattern + r"\s*\{([^}]*)\}", text)
    return m.group(1) if m else ""


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
    """Resolve a token to its effective literal in one theme.

    `primary` is the theme's own dict; `fallback` (light) is consulted when the
    token/referent is absent from `primary` (dark falls through to light).
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


def parse_tokens(text):
    """Parse the two theme blocks into a normalized per-token model."""
    text = strip_comments(text)
    # The light selector (`body.wcs-theme`) is a prefix of the dark one
    # (`body.wcs-theme.wcs-dark`), but requiring `{` after the selector keeps
    # them distinct: only the light block has `{` immediately after
    # `body.wcs-theme`.
    light = _parse_decls(_extract_block(text, r"body\.wcs-theme"))
    dark = _parse_decls(_extract_block(text, r"body\.wcs-theme\.wcs-dark"))

    records = []
    for name in sorted(set(light) | set(dark)):
        light_val = _normalize_hex(_resolve(name, light, None))
        dark_val = _normalize_hex(_resolve(name, dark, light))
        records.append(
            {
                "name": name,
                "light": light_val,
                # null when the effective value does not differ by theme
                "dark": None if dark_val == light_val else dark_val,
                "light_alias": _alias_of(light.get(name)),
                "dark_alias": _alias_of(dark.get(name)),
            }
        )
    return records


def parse_general(text):
    """Extract exactly --font-family from a nested SCSS file's `html, body`
    block, ignoring @imports and @keyframes."""
    text = strip_comments(text)
    m = re.search(r"html\s*,\s*body\s*\{([^{}]*)\}", text, re.S)
    body = m.group(1) if m else ""
    fm = re.search(r"--font-family\s*:\s*([^;]+);", body)
    value = fm.group(1).strip() if fm else None
    return {
        "name": "--font-family",
        "light": _normalize_hex(value),
        "dark": None,
        "light_alias": _alias_of(value),
        "dark_alias": None,
    }


def main(argv):
    text = sys.stdin.read()
    if "--general" in argv:
        result = parse_general(text)
    else:
        result = parse_tokens(text)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
