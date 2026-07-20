// harvest_extract.js — agent-browser `eval` page script for token-bridge.
//
// Runs INSIDE the target codebase's live page. Given a component root selector,
// walks its DOM subtree and records, per node: tag, direct text, and a curated
// getComputedStyle snapshot. Also records the page's active theme, decided by an
// injected theme SIGNAL (config-driven — no hardcoded framework class).
//
// WHY getComputedStyle: the browser resolves color-mix() and currentColor down to
// literal values (e.g. rgb(...) / rgba(...)). That is the whole point of harvesting
// from a live page instead of parsing CSS text — it dodges the mangling Paper does
// to color-mix()/currentColor when those reach it as authored strings.
//
// harvest.py injects two tokens before passing this to `agent-browser eval <js> --json`:
//   - the selector: it replaces the quoted "__TB_SELECTOR__" token with a
//     JSON-encoded selector string.
//   - the theme signal: it replaces the bare __TB_THEME_SIGNAL__ token with a
//     JSON object describing how to read the active theme from the live page:
//       { "type": "data-attribute", "attr": "data-theme", "value": "dark" }
//       { "type": "media-query", "query": "(prefers-color-scheme: dark)" }
//
// Return shape (the value agent-browser serialises):
//   found:     { "ok": true,  "theme": "dark"|"light", "selector": "...", "root": <node> }
//   not found: { "ok": false, "error": "component_not_found", "theme": "...", "selector": "...", "root": null }
// where <node> = { tag, text, styles: { <prop>: <literal>, ... }, children: [ <node>, ... ] }.

(() => {
  const SELECTOR = "__TB_SELECTOR__";
  const THEME_SIGNAL = __TB_THEME_SIGNAL__;

  // Curated computed-style properties that actually matter for mapping back to
  // design tokens (colors, spacing, borders, typography, layout, background).
  // Deliberately NOT the full ~350-property dump — that would bury the signal.
  const STYLE_PROPS = [
    // color / background
    "color",
    "background-color",
    "background-image",
    "opacity",
    // borders
    "border-top-color",
    "border-right-color",
    "border-bottom-color",
    "border-left-color",
    "border-top-width",
    "border-right-width",
    "border-bottom-width",
    "border-left-width",
    "border-top-style",
    "border-right-style",
    "border-bottom-style",
    "border-left-style",
    "border-top-left-radius",
    "border-top-right-radius",
    "border-bottom-right-radius",
    "border-bottom-left-radius",
    "outline-color",
    "outline-width",
    "outline-style",
    "box-shadow",
    // typography
    "font-family",
    "font-size",
    "font-weight",
    "font-style",
    "line-height",
    "letter-spacing",
    "text-align",
    "text-transform",
    "text-decoration-line",
    "text-decoration-color",
    "white-space",
    "text-shadow",
    // spacing
    "padding-top",
    "padding-right",
    "padding-bottom",
    "padding-left",
    "margin-top",
    "margin-right",
    "margin-bottom",
    "margin-left",
    // box / layout
    "width",
    "height",
    "min-width",
    "max-width",
    "min-height",
    "max-height",
    "box-sizing",
    "display",
    "flex-direction",
    "justify-content",
    "align-items",
    "gap",
    "column-gap",
    "row-gap",
    "vertical-align",
    // svg fills (icons rendered inline)
    "fill",
    "stroke",
    "stroke-width",
    "cursor",
  ];

  // Resolve the active theme from the injected signal (config-driven). A
  // data-attribute signal reads the attribute off <html> or <body>; a
  // media-query signal evaluates the query via matchMedia. Anything else (or a
  // missing signal) falls back to "light".
  let theme = "light";
  if (THEME_SIGNAL && THEME_SIGNAL.type === "data-attribute") {
    const attr = THEME_SIGNAL.attr;
    const value = THEME_SIGNAL.value;
    theme =
      document.documentElement.getAttribute(attr) === value ||
      document.body.getAttribute(attr) === value
        ? "dark"
        : "light";
  } else if (THEME_SIGNAL && THEME_SIGNAL.type === "class") {
    // classList.contains matches a whole class token, so `.wcs-darker` does NOT
    // satisfy a `.wcs-dark` signal — which a substring test on className would.
    const cls = THEME_SIGNAL.class;
    theme =
      document.documentElement.classList.contains(cls) ||
      document.body.classList.contains(cls)
        ? "dark"
        : "light";
  } else if (THEME_SIGNAL && THEME_SIGNAL.type === "media-query") {
    theme = window.matchMedia(THEME_SIGNAL.query).matches ? "dark" : "light";
  }

  const root = document.querySelector(SELECTOR);
  if (!root) {
    return {
      ok: false,
      error: "component_not_found",
      theme: theme,
      selector: SELECTOR,
      root: null,
    };
  }

  // Guard against runaway subtrees (a bad selector matching the whole app).
  const MAX_NODES = 500;
  let count = 0;

  const styleOf = (el) => {
    const cs = getComputedStyle(el);
    const out = {};
    for (const prop of STYLE_PROPS) {
      const v = cs.getPropertyValue(prop);
      if (v !== "" && v != null) {
        const trimmed = String(v).trim();
        if (trimmed !== "") out[prop] = trimmed;
      }
    }
    return out;
  };

  const walk = (el) => {
    count++;
    const tag = el.tagName.toLowerCase();

    // An inline <svg> (icons) is self-contained geometry — its <path> d/viewBox/
    // stroke attributes are NOT computed styles, so walking its children loses the
    // glyph and it renders blank. Capture the raw markup instead, resolving
    // currentColor to the element's computed color (Paper drops currentColor).
    if (tag === "svg") {
      const color = getComputedStyle(el).color;
      const svgHtml = el.outerHTML.replace(/currentColor/g, color);
      return {
        tag: "svg",
        text: "",
        styles: styleOf(el),
        svgHtml: svgHtml,
        children: [],
      };
    }

    // An <img> renders blank unless its src is captured (src is an attribute, not
    // a computed style). Record the resolved URL; a same-origin/data src renders,
    // an expiring signed CDN src may not — no worse than the blank it replaces.
    if (tag === "img") {
      return {
        tag: "img",
        text: "",
        styles: styleOf(el),
        imgSrc: el.currentSrc || el.src || "",
        children: [],
      };
    }

    const node = {
      tag: tag,
      // Direct text nodes only — descendants' text is captured on their own nodes,
      // so this avoids duplicating a heading's text onto every ancestor.
      text: Array.from(el.childNodes)
        .filter((n) => n.nodeType === 3)
        .map((n) => n.textContent)
        .join("")
        .trim(),
      styles: styleOf(el),
      children: [],
    };
    if (count < MAX_NODES) {
      for (const child of el.children) {
        node.children.push(walk(child));
      }
    }
    return node;
  };

  return { ok: true, theme: theme, selector: SELECTOR, root: walk(root) };
})();
