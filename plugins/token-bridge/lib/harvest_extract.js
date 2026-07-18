// harvest_extract.js — agent-browser `eval` page script for wcs-paper (Unit U6).
//
// Runs INSIDE the WCS editor page. Given a component root selector, walks its DOM
// subtree and records, per node: tag, direct text, and a curated getComputedStyle
// snapshot. Also records the page's active theme (WCS dark class = body.wcs-dark).
//
// WHY getComputedStyle: the browser resolves color-mix() and currentColor down to
// literal values (e.g. rgb(...) / rgba(...)). That is the whole point of harvesting
// from a live page instead of parsing CSS text — it dodges the mangling Paper does
// to color-mix()/currentColor when those reach it as authored strings.
//
// harvest.py injects the selector by replacing the "__WCS_PAPER_SELECTOR__" token
// (quotes included) with a JSON-encoded selector string before passing this to
// `agent-browser eval <js> --json`.
//
// Return shape (the value agent-browser serialises):
//   found:     { "ok": true,  "theme": "dark"|"light", "selector": "...", "root": <node> }
//   not found: { "ok": false, "error": "component_not_found", "theme": "...", "selector": "...", "root": null }
// where <node> = { tag, text, styles: { <prop>: <literal>, ... }, children: [ <node>, ... ] }.

(() => {
  const SELECTOR = "__WCS_PAPER_SELECTOR__";

  // Curated computed-style properties that actually matter for mapping back to
  // WCS design tokens (colors, spacing, borders, typography, layout, background).
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

  // WCS editor dark theme is body.wcs-theme.wcs-dark; light is the absence of wcs-dark.
  const theme = document.body.classList.contains("wcs-dark") ? "dark" : "light";

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
