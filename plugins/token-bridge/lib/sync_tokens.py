#!/usr/bin/env python3
"""Idempotent token-sync — reconcile a codebase's CSS tokens into a Paper file.

This is token-bridge's code -> Paper command. It reads the CSS source declared
by the target codebase's config, parses + classifies it (via the sibling lib
modules), builds the *desired* Paper token set, diffs it against the *live*
Paper file, and applies the minimal reconcile (create / update / delete /
recreate). Re-run against an unchanged source, it writes nothing (R3).

The source, custom-property prefix, and theme conventions all come from the
config found under `--repo <path>` (paper_client.read_config) — nothing about a
particular codebase is hardcoded here.

--------------------------------------------------------------------------------
LIGHT / DARK NAMING SCHEME (KTD2 — frozen)
--------------------------------------------------------------------------------
Paper has no per-file "theme mode" for tokens, so v1's base + one "dark" theme
are written as two *separately named* Paper tokens rather than two modes of one
token:

  * The BASE (light) value keeps the token's own name:   --accent
  * The DARK value gets a "-dark" suffixed twin:          --accent-dark

Only theme-VARYING tokens (parse_tokens gives them a non-null `dark`) get a dark
twin. Mode-invariant tokens (dark == null) are written exactly once, under their
own name, with no twin.

Aliases follow the same scheme *within their theme* (R2 + R3):
  * A LIGHT alias references the plain (light) name:   var(--green-500)
  * A DARK alias references the DARK counterpart —      var(--accent-dark)
    but ONLY when that referent is itself theme-varying (and therefore has a
    "-dark" twin). If the referent is mode-invariant it has no twin, so the dark
    alias references its plain name.

Worked example:
    --nav-active-fg        = var(--accent)        # light twin
    --nav-active-fg-dark   = var(--accent-dark)   # dark twin,
                                                  # NOT var(--accent)

Tier-2 aliases are written as var(--*) references, never resolved to their
literal hex (R2) — parse_tokens' light_alias/dark_alias metadata drives this.

--------------------------------------------------------------------------------
Architecture
--------------------------------------------------------------------------------
The DIFF ENGINE is a pure function (desired, live) -> {creates, updates, deletes,
recreates} with no config and no daemon, so it is unit-testable against fixtures.
Only apply_diff() touches the live daemon. build_desired() is likewise pure over
classified records. Reading the source (parse_tokens.load_source) is the only
file/git-touching step, and it is driven entirely by the config.

CLI:
  python3 sync_tokens.py run --repo PATH        # full pipeline (config + daemon)
  python3 sync_tokens.py build-desired --source-file F --conventions JSON [--prefix P]
  python3 sync_tokens.py diff --desired D --live L
  python3 sync_tokens.py simulate-apply --live L --diff D
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

# Sibling lib modules — READ/import only (never modified by this unit).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import classify_tokens  # noqa: E402
import map_to_tokens  # noqa: E402
import parse_tokens  # noqa: E402
from paper_client import PaperClient, read_config, resolve_repo_path  # noqa: E402

# --- configuration -----------------------------------------------------------

DARK_SUFFIX = "-dark"

# Exit codes — distinct so callers/tests can tell failure kinds apart.
EXIT_OK = 0
EXIT_REFUSED = 2  # safety guard: no fileId / no config / bad config / empty parse
EXIT_ERROR = 4  # source read / daemon / apply failure


def _log(msg: str) -> None:
    print(f"[sync_tokens] {msg}", file=sys.stderr)


# --- value normalization (shared by build + diff, for idempotency) -----------


def _norm_value(v):
    """Normalize a token value for comparison: strip, then uppercase every hex
    run via parse_tokens' own normalizer — one definition of "same value" feeds
    the diff whose emptiness is the R3 idempotency contract. Non-hex values
    (var(...), rgba(...), 8px) are unaffected beyond a strip."""
    if v is None:
        return None
    return parse_tokens.normalize_hex(v.strip())


def _norm_name(name):
    return name.lower()


_VAR_REF = re.compile(r"var\(\s*(--[A-Za-z0-9-]+)\s*\)")


def order_for_create(tokens):
    """Order create tokens so a var() alias is created AFTER its referent.

    Paper's create_tokens processes the array in order and a var(--x) whose
    referent does not exist YET fails silently — so an alphabetically-sorted
    batch drops every Tier-2 alias whose Tier-1 referent sorts later (e.g.
    --accent = var(--green-500)), and any alias chaining through it. Topological
    sort on the in-batch var() dependency; tokens with no in-batch referent keep
    their relative order and come first. Cycles are broken by emitting in
    encounter order."""
    by_name = {t["name"]: t for t in tokens}
    ordered = []
    placed = set()
    visiting = set()

    def visit(t):
        name = t["name"]
        if name in placed or name in visiting:
            return
        visiting.add(name)
        m = _VAR_REF.search(t.get("value") or "")
        if m and m.group(1) in by_name:
            visit(by_name[m.group(1)])
        visiting.discard(name)
        placed.add(name)
        ordered.append(t)

    for t in tokens:
        visit(t)
    return ordered


# --- desired-set construction (pure over classified records) -----------------


def _alias_ref(referent, theme, theme_varying):
    """Resolve an alias referent to the name it should carry in `theme`.

    In the dark theme a referent that is itself theme-varying points at its
    "-dark" twin; otherwise (mode-invariant referent, or the light theme) it
    points at the plain name."""
    if theme == "dark" and referent in theme_varying:
        return referent + DARK_SUFFIX
    return referent


def _light_value(rec, theme_varying):
    """The light-theme write value: a var() alias if the light decl is an alias
    (R2), else the resolved light literal."""
    if rec.get("light_alias"):
        return "var(%s)" % _alias_ref(rec["light_alias"], "light", theme_varying)
    return _norm_value(rec.get("light"))


def _dark_value(rec, theme_varying, dark_literals):
    """The dark-theme write value. Alias precedence:
      1. an explicit dark alias (dark_alias) -> its dark-theme referent;
      2. a *flipping* light alias — the token has NO independent dark
         declaration, and it is theme-varying only because its light referent is
         redeclared in dark. Detected by the referent's resolved dark literal
         equalling this token's dark literal. -> the referent's dark twin.
      3. otherwise the resolved dark literal (an independent dark declaration,
         e.g. --accent aliases a primitive in light but is a literal in dark).
    """
    if rec.get("dark_alias"):
        return "var(%s)" % _alias_ref(rec["dark_alias"], "dark", theme_varying)
    ref = rec.get("light_alias")
    if ref and dark_literals.get(ref) == _norm_value(rec.get("dark")):
        # Pure flip-through: the dark value is the referent's flipped value, not
        # an independent literal. Reference the referent's dark twin.
        return "var(%s)" % _alias_ref(ref, "dark", theme_varying)
    return _norm_value(rec.get("dark"))


def build_desired(classified):
    """Build the desired Paper token list from classified records (pure).

    Returns (desired, declined) where:
      desired  = sorted list of {name, type, value} Paper tokens
      declined = sorted list of {name, reason} for non-writable tokens
    """
    # A referent whose twin was dropped has no `-dark` counterpart, so a dark
    # alias must fall back to its plain name — otherwise we emit
    # var(--x-dark) pointing at a token that is never created, and Paper fails
    # that reference silently.
    theme_varying = {
        r["name"]
        for r in classified
        if r.get("dark") is not None and not r.get("dark_excluded_reason")
    }
    # Each token's effective dark literal (dark value, or light when invariant),
    # keyed by name — used to detect pure flip-through aliases in _dark_value.
    dark_literals = {
        r["name"]: _norm_value(
            r["dark"] if r.get("dark") is not None else r.get("light")
        )
        for r in classified
    }

    desired = []
    declined = []
    for rec in classified:
        if not rec.get("writable"):
            declined.append(
                {"name": rec["name"], "reason": rec.get("excluded_reason")}
            )
            continue

        ptype = rec["paper_type"]
        # Light twin (or the sole token for a mode-invariant value). A token
        # declared only in the dark block would resolve light=None; skip the
        # light twin rather than send value:None to create_tokens.
        light_val = _light_value(rec, theme_varying)
        if light_val is not None:
            desired.append({"name": rec["name"], "type": ptype, "value": light_val})
        # Dark twin — only for theme-varying tokens.
        if rec.get("dark") is not None:
            # A dark half classify could not type is omitted as a TWIN only —
            # the base above still syncs. Dropping the base too would delete a
            # live token over a value classify merely failed to recognise.
            dark_reason = rec.get("dark_excluded_reason")
            if dark_reason:
                declined.append(
                    {"name": rec["name"] + DARK_SUFFIX, "reason": dark_reason}
                )
            else:
                desired.append(
                    {
                        "name": rec["name"] + DARK_SUFFIX,
                        "type": ptype,
                        "value": _dark_value(rec, theme_varying, dark_literals),
                    }
                )

    desired.sort(key=lambda t: t["name"])
    declined.sort(key=lambda t: t["name"])
    return desired, declined


def _same_value(live_val, desired_val):
    """True when the live (Paper-stored) value equals the desired value AFTER
    canonicalizing for Paper's own serialization. Paper rewrites on store —
    `transparent` -> `#00000000`, `rgba(r,g,b,a)` -> `rgb(r g b / a%)`, `0` ->
    `0px` — so a raw string compare churns those tokens on every sync (R3). A
    var() alias has no color/length to canonicalize; it compares as a normalized
    string. map_to_tokens.normalize_value owns the canonical color/length form
    (shared with the harvest path)."""
    a = map_to_tokens.normalize_value(_norm_value(live_val))
    b = map_to_tokens.normalize_value(_norm_value(desired_val))
    return a == b


# --- the diff engine (PURE — no config, no daemon) ---------------------------


def _owns(name, owned_prefix):
    """Whether the plugin OWNS this live token name, and may therefore delete it
    when it's absent from the desired set.

    With a configured `owned_prefix`, ownership is scoped to that namespace: the
    source only defines prefixed tokens (and their `-dark` twins, which also
    start with the prefix), so a token outside it — a Paper-native `--color-*`,
    another team's prefix, a hand-authored token — is NOT ours to delete. With no
    prefix (source is "all custom properties"), the plugin owns the whole file
    and full reconcile applies."""
    if not owned_prefix:
        return True
    return _norm_name(name).startswith(_norm_name(owned_prefix))


def diff_tokens(desired, live, owned_prefix=None, *, unreadable):
    """Diff the desired Paper token set against the live one (pure function).

    Compares with NORMALIZED name (lowercase) and value (uppercased hex) so an
    unchanged source yields an EMPTY diff (R3).

    `unreadable` is REQUIRED, not optional — an optional kwarg let a caller
    silently inherit the destructive behaviour by doing nothing, which is exactly
    how `status` kept deleting after the invariant landed. Pass `set()` only when
    you genuinely have no source to compare against.

    It is the INVARIANT that makes our incompleteness harmless: names the source
    DECLARED but that did not reach the desired set — whether classify could not
    type them, the block walk missed them, or a scope predicate did not match. "I cannot type this
    value" must mean "do not write it" — it must NEVER also mean "delete it".
    Conflating those two is what turned every gap in the recognisers into data
    loss: an unrecognised font size in `rem`, a dark half using `clamp()`, a
    colour function the allowlist had not met yet. Absence from `desired` is
    ambiguous (the source dropped it, OR we failed to read it); this set
    disambiguates, and only the first meaning may delete.

    The recognisers will always be incomplete — CSS keeps adding value syntax.
    This is what makes being incomplete survivable rather than destructive, and
    it is why they can stay STRICT: a false negative now costs a skipped write,
    not a deleted token.

    `owned_prefix` scopes deletions: a live token absent from the desired set is
    deleted only when the plugin OWNS it (see `_owns`). This stops a prefixed
    sync from wiping Paper-native or other-namespace tokens that share the target
    file. Creates/updates/recreates are always driven by the desired set, so they
    are unaffected.

    Returns {creates, updates, deletes, recreates}:
      creates    tokens present in desired, absent from live         -> create
      updates    same name+type, value changed                       -> set value
      deletes    OWNED, present in live, absent from desired, and NOT
                 unreadable                                          -> delete
      recreates  same name, TYPE changed (Paper cannot retype)       -> delete+create
    """
    live_by_name = {}
    for t in live:
        live_by_name[_norm_name(t["name"])] = t

    creates, updates, recreates = [], [], []
    desired_names = set()

    for d in desired:
        key = _norm_name(d["name"])
        desired_names.add(key)
        cur = live_by_name.get(key)
        if cur is None:
            creates.append(d)
            continue
        if cur.get("type") != d.get("type"):
            # Paper cannot change a token's type in place — delete then recreate.
            recreates.append(d)
            continue
        if not _same_value(cur.get("value"), d.get("value")):
            updates.append(d)

    protected = {_norm_name(n) for n in (unreadable or ())}
    deletes = [
        {"name": t["name"]}
        for t in live
        if _norm_name(t["name"]) not in desired_names
        and _norm_name(t["name"]) not in protected
        and _owns(t["name"], owned_prefix)
    ]

    return {
        "creates": creates,
        "updates": updates,
        "deletes": deletes,
        "recreates": recreates,
    }


def is_empty_diff(diff):
    return not (
        diff["creates"] or diff["updates"] or diff["deletes"] or diff["recreates"]
    )


# --- pure apply simulation (for idempotency round-trip tests, no daemon) ------


def simulate_apply(live, diff):
    """Apply a diff to a live-state list in memory and return the new state.

    Mirrors apply_diff()'s semantics without a daemon, so a round-trip
    (diff -> simulate-apply -> re-diff) can be asserted empty in a unit test."""
    state = {_norm_name(t["name"]): dict(t) for t in live}

    for t in diff["deletes"]:
        state.pop(_norm_name(t["name"]), None)
    for t in diff["recreates"]:
        state[_norm_name(t["name"])] = {
            "name": t["name"],
            "type": t["type"],
            "value": t["value"],
        }
    for t in diff["creates"]:
        state[_norm_name(t["name"])] = {
            "name": t["name"],
            "type": t["type"],
            "value": t["value"],
        }
    for t in diff["updates"]:
        cur = state[_norm_name(t["name"])]
        cur["value"] = t["value"]

    return sorted(state.values(), key=lambda t: _norm_name(t["name"]))


# --- apply against the live daemon -------------------------------------------


def apply_diff(client, file_id, diff):
    """Apply a diff via the PaperClient. Returns a per-step result summary.

    Order: deletes (deletes + recreate-old) first, then creates (creates +
    recreate-new), then value updates. Each step's envelope is captured; the
    first non-ok envelope short-circuits with ok:false."""
    steps = []

    # 1. Deletions: the delete half of every recreate. NOTHING ELSE.
    #
    # This function cannot remove a stale token, and that is deliberate rather
    # than a default. Deciding "the user removed this" from "this is absent
    # from my parse" produced fourteen data-loss defects across nine review
    # rounds; every attempt to make the inference safe — four completeness
    # guards, an explicit --prune flag, a fail-closed affirmation model —
    # introduced a new deletion path within one round. The capability is gone,
    # so the class is gone with it. `diff["deletes"]` is still computed and
    # still reported as `prunable`; removing those is the user's job, in Paper,
    # where they can see what they are removing.
    #
    # A recreate is a different animal: same name, deleted and immediately
    # recreated because Paper cannot retype in place. It is bounded and driven
    # by the desired set, not by absence. It is still not free — a Paper-side
    # field this tool does not model does not survive it — and run() says so.
    if diff.get("deletes"):
        raise ValueError(
            "apply_diff was given stale deletes; this tool does not remove "
            "tokens. Report them as `prunable` instead."
        )
    delete_names = [t["name"] for t in diff["recreates"]]
    if delete_names:
        env = client.set_tokens(
            [{"name": n, "delete": True} for n in delete_names], file_id
        )
        steps.append({"step": "delete", "names": delete_names, "envelope": env})
        if not env.get("ok"):
            return {"ok": False, "steps": steps}

    # 2. Creations: fresh creates + the create half of every recreate, ordered
    #    so a var() alias is created after its referent (Paper creates in array
    #    order and a dangling var() alias fails silently).
    create_tokens = order_for_create([
        {"type": t["type"], "name": t["name"], "value": t["value"]}
        for t in diff["creates"] + diff["recreates"]
    ])
    if create_tokens:
        env = client.create_tokens(create_tokens, file_id)
        steps.append(
            {
                "step": "create",
                "names": [t["name"] for t in create_tokens],
                "envelope": env,
            }
        )
        if not env.get("ok"):
            return {"ok": False, "steps": steps}

    # 3. Value updates (same type, changed value).
    if diff["updates"]:
        env = client.set_tokens(
            [{"name": t["name"], "value": t["value"]} for t in diff["updates"]],
            file_id,
        )
        steps.append(
            {
                "step": "update",
                "names": [t["name"] for t in diff["updates"]],
                "envelope": env,
            }
        )
        if not env.get("ok"):
            return {"ok": False, "steps": steps}

    return {"ok": True, "steps": steps}


# --- desired-set construction from source text (pure) ------------------------


def empty_parse_refusal(text, parsed_count, source_path):
    """The empty-parse backstop (R7) — pure. Returns a refusal report, or None.

    A source that parses to zero tokens is indistinguishable, downstream, from a
    codebase that deleted every token: the desired set is empty, so the diff
    turns the whole live set into deletes. That is almost never what happened.
    The usual cause is a scope shape the parser cannot read — a `:root` wrapped
    in `@layer` (standard in Tailwind v4 and Open Props), `@media`, or
    `@supports`, or a class-scoped theme.

    So a source with CONTENT but no tokens refuses. A source that is genuinely
    empty (blank, or comments only) is a legitimate no-op and returns None —
    the reconcile proceeds and its deletes, if any, are real.

    `parsed_count` is every record the pipeline produced — desired PLUS
    declined. Tokens that parsed and were only declined downstream are evidence
    the parse worked; only a total blank is the unparseable-scope signature."""
    if parsed_count > 0:
        return None
    if not parse_tokens.strip_comments(text or "").strip():
        return None
    return {
        "ok": False,
        "refused": True,
        "error": "empty_parse",
        "note": (
            f"{source_path} has content but parsed to zero tokens. Syncing would "
            "delete every live token in the target file, so nothing was written. "
            "The usual cause is a scope shape the parser cannot read — a :root "
            "wrapped in @layer/@media/@supports, or a class-scoped theme."
        ),
    }


def desired_from_source(text, conventions, prefix=None, dark_texts=None):
    """Full pure source pipeline: parse -> classify -> build_desired.

    `conventions` is the config `themeConventions` list; `prefix` restricts
    output to custom properties with that prefix (None/"" takes all).
    `dark_texts` carries the theme text of any `file` convention, keyed by its
    index in `conventions` — see parse_tokens.resolve_dark_texts."""
    records = parse_tokens.parse_tokens(text, conventions, prefix, dark_texts)
    classified = classify_tokens.classify_tokens(records)
    return build_desired(classified)


# --- top-level orchestration -------------------------------------------------


def run(repo=".", url=None, apply=True):
    """The end-to-end reconcile. Returns (report_dict, exit_code).

    THIS DOES NOT DELETE. It creates, updates, and recreates retyped tokens.
    A live token absent from the parse is reported under `prunable` and left
    alone; removing it is the user's job, in Paper.

    That is not caution, it is the conclusion of nine review rounds. Deciding
    "the user removed this" from "this is absent from my parse" produced
    fourteen data-loss defects, and every attempt to make the inference safe
    introduced a new deletion path within one round. The inference is gone.
    `apply_diff` raises if handed stale deletes, so this is a missing
    capability rather than a default someone can flip back on.
    """
    file_id, cfg, err = read_config(repo)
    if err is not None:
        # no_config / bad_config / no_target_file — all refuse before any write.
        return (
            {
                "ok": False,
                "refused": True,
                "error": err.get("error"),
                "note": err.get("note"),
            },
            EXIT_REFUSED,
        )

    # Source (config working-tree path by default; the git-ref mode when
    # source.ref is set — both handled inside parse_tokens.load_source).
    try:
        text = parse_tokens.load_source(cfg)
    except RuntimeError as exc:
        return ({"ok": False, "error": str(exc)}, EXIT_ERROR)

    conventions = cfg.get("themeConventions") or []
    prefix = (cfg.get("source") or {}).get("prefix")
    # A `file` convention's dark theme lives in another file, so it has to be
    # read here — parse cannot reach outside the text it is given. Sharing the
    # load_source try/except: both are "could not read the source" failures and
    # both must refuse rather than proceed with a partial view.
    try:
        dark_texts = parse_tokens.resolve_dark_texts(cfg)
    except RuntimeError as exc:
        return ({"ok": False, "refused": True, "error": "theme_file_unreadable",
                 "note": str(exc)}, EXIT_REFUSED)

    # Checked AFTER resolve_dark_texts so the THEME graph's unresolved imports
    # are covered by the same refusal — round 5 checked before it ran, so the
    # dark half's misses could not be seen even once they were recorded.
    missing = parse_tokens.missing_imports()
    if missing and not (cfg.get("source") or {}).get("allowMissingImports"):
        listed = ", ".join(f"{spec!r} (from {whence})" for spec, whence in missing[:5])
        return (
            {
                "ok": False, "refused": True, "error": "unresolved_imports",
                "note": (
                    f"{len(missing)} import(s) could not be resolved: {listed}. Nothing was "
                    "written — tokens declared in an unresolved file are invisible to this "
                    "parse and would look deleted. Fix the path, or set "
                    "source.allowMissingImports: true to accept the risk."
                ),
            },
            EXIT_REFUSED,
        )

    desired, declined = desired_from_source(text, conventions, prefix, dark_texts)

    # Empty-parse backstop (R7): a source with content that yields no tokens is
    # a parse failure, not a mass deletion. Refuse BEFORE the daemon is touched.
    refusal = empty_parse_refusal(
        text,
        len(desired) + len(declined),
        resolve_repo_path(cfg, (cfg.get("source") or {}).get("path")),
    )
    if refusal is not None:
        _log(refusal["note"])
        return (refusal, EXIT_REFUSED)

    # Live Paper tokens.
    client = PaperClient(url=url or cfg.get("paperDaemonUrl"))
    live_env = client.get_tokens(file_id)
    if not live_env.get("ok"):
        return (
            {"ok": False, "error": "get_tokens failed", "envelope": live_env},
            EXIT_ERROR,
        )
    live = live_env.get("result", {}).get("tokens", []) or []

    # Scope deletes to the owned prefix so a prefixed sync never wipes
    # Paper-native or other-namespace tokens sharing the target file.
    # Protect everything the SOURCE TEXT declares that did not reach `desired`,
    # plus its `-dark` twin. Derived from the text rather than from the parsed
    # records so a token the parser never saw is protected too — a declined
    # base's twin, or a name lost to a scope predicate, leaves no record to
    # inspect but is plainly there in the source.
    # An incomplete parse no longer decides anything destructive — nothing
    # deletes — so this reports rather than refuses. The information still
    # matters: an unread import means stale values and missing tokens, and a
    # user who sees `prunable` should know whether the parse was whole before
    # acting on it in Paper.
    complete, reasons = parse_tokens.source_completeness()
    if not complete:
        listed = "; ".join(
            f"{what}{f' (from {where})' if where else ''}"
            for _kind, what, where in reasons[:5]
        )
        _log(
            f"this parse did not read the whole source: {listed}. Values from "
            "those may be stale, and tokens they declare will appear under "
            "`prunable` even though you have not removed them — do not act on "
            "that list until the source reads whole."
        )

    # Declined tokens parsed FINE — Paper simply cannot represent them (shadows,
    # motion, filters). They are in the source, so they must not be deleted, and
    # they are disclosed in the `declined` report field rather than silently
    # suppressed. This is the whole of the protection now.
    #
    # The old text-sweep protection is gone. It existed because sync used to
    # delete automatically, so it had to guess at what the parser might have
    # missed; with a complete parse there is nothing unread to protect, and with
    # an incomplete one we refused above. Keeping it only ever suppressed
    # deletions the user explicitly asked for: a token moved from `:root` into a
    # component rule became permanently unprunable and silently so.
    protected = {d["name"] for d in declined}
    protected |= {n + DARK_SUFFIX for n in protected}
    unreadable = protected

    # A live token whose declaration is only commented out shows up as
    # `prunable` like any other absent name — but its absence has a specific,
    # recoverable cause worth naming, because the user may think commenting the
    # line out already retired it.
    commented = parse_tokens.commented_only_names(text, prefix)
    for dark_text in (dark_texts or {}).values():
        commented |= parse_tokens.commented_only_names(dark_text, prefix)
    live_names = {t["name"] for t in live}
    pinned = sorted(n for n in commented if n in live_names)
    for n in pinned:
        _log(
            f"{n} is live in the target file but only appears inside a comment in the "
            "source, which is why it is listed as prunable. Commenting the declaration "
            "out does not remove the token — delete the line, then remove it in Paper."
        )

    diff = diff_tokens(desired, live, owned_prefix=prefix, unreadable=unreadable)

    # Blank-source backstop (R7, second arm). The pre-daemon check above cannot
    # fire on a BLANK source — a truncated or emptied file is legitimately "no
    # content", so it falls through — and this arm needs the live set, which
    # that one does not have.
    #
    # Nothing deletes any more, so this no longer prevents a wipe. It prevents
    # the ADVICE to wipe: zero desired against a populated owned set reports
    # every live token as `prunable`, and a user acting on that list deletes
    # their whole file by hand. A truncated source must not produce a
    # confident-looking removal list.
    if not desired and diff["deletes"]:
        note = (
            f"{resolve_repo_path(cfg, (cfg.get('source') or {}).get('path'))} parsed to zero "
            f"tokens while {len(diff['deletes'])} owned token(s) are live. Every one of them "
            "would be listed as prunable, which is almost certainly wrong — if the source was "
            "truncated or emptied by mistake, restore it. Nothing was written either way."
        )
        _log(note)
        return (
            {"ok": False, "refused": True, "error": "empty_parse", "note": note},
            EXIT_REFUSED,
        )

    report = {
        "ok": True,
        "fileId": file_id,
        "created": [t["name"] for t in diff["creates"]],
        "updated": [t["name"] for t in diff["updates"]],
        # Split by whether it actually happened. `prunable` is what a sync
        # would once have destroyed silently.
        "prunable": [t["name"] for t in diff["deletes"]],
        "parseComplete": complete,
        "recreated": [t["name"] for t in diff["recreates"]],
        "declined": declined,
        "pinnedByComment": pinned,
        "empty": is_empty_diff(diff),
    }

    if diff["recreates"]:
        names = ", ".join(t["name"] for t in diff["recreates"][:8])
        _log(
            f"{len(diff['recreates'])} token(s) changed Paper type and are being "
            f"recreated: {names}. Paper cannot retype in place, so each is a delete "
            "followed by a create — and any "
            "Paper-side field this tool does not model (a hand-written description) "
            "does not survive it."
        )

    if diff["deletes"]:
        names = ", ".join(t["name"] for t in diff["deletes"][:8])
        _log(
            f"{len(diff['deletes'])} live token(s) are absent from this parse and were "
            f"NOT removed: {names}. Absence is not proof of removal — a parse gap looks "
            "identical to a deletion. Remove them in Paper if you meant to retire them."
        )
        # Drop them from the applied diff entirely; they stay reported.
        diff = dict(diff, deletes=[])

    if apply and not is_empty_diff(diff):
        apply_result = apply_diff(client, file_id, diff)
        report["applied"] = apply_result["ok"]
        report["apply_steps"] = apply_result["steps"]
        if not apply_result["ok"]:
            report["ok"] = False
            return (report, EXIT_ERROR)
    else:
        report["applied"] = False

    return (report, EXIT_OK)


# --- CLI ---------------------------------------------------------------------


def _load_json_file(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="sync_tokens.py", description=__doc__)
    sub = parser.add_subparsers(dest="cmd")

    p_run = sub.add_parser("run", help="Full reconcile (config source + live daemon).")
    p_run.add_argument("--repo", default=".", help="Target codebase root holding token-bridge.config.json")
    p_run.add_argument("--url", default=None, help="Paper daemon URL override")
    p_run.add_argument("--no-apply", action="store_true", help="Diff + report only")

    p_bd = sub.add_parser("build-desired", help="Build the desired set from one CSS source + conventions.")
    p_bd.add_argument("--source-file", required=True, help="CSS/SCSS source file to parse")
    p_bd.add_argument("--conventions", required=True, help="JSON array of themeConventions")
    p_bd.add_argument("--prefix", default=None, help="Only include custom properties with this prefix")

    p_diff = sub.add_parser("diff", help="Pure diff of desired vs live JSON files.")
    p_diff.add_argument("--desired", required=True)
    p_diff.add_argument("--live", required=True)
    p_diff.add_argument("--owned-prefix", default=None,
                        help="Only delete live tokens with this prefix (plugin ownership scope)")

    p_sim = sub.add_parser("simulate-apply", help="Pure in-memory apply of a diff to a live state.")
    p_sim.add_argument("--live", required=True)
    p_sim.add_argument("--diff", required=True)

    args = parser.parse_args(argv)
    cmd = args.cmd or "run"

    if cmd == "run":
        # `run` is also the bare-invocation default.
        report, code = run(
            repo=getattr(args, "repo", "."),
            url=getattr(args, "url", None),
            apply=not getattr(args, "no_apply", False),
        )
        print(json.dumps(report, indent=2))
        if report.get("refused"):
            _log(report.get("note") or report.get("error", "refused"))
        return code

    if cmd == "build-desired":
        try:
            conventions = json.loads(args.conventions)
        except json.JSONDecodeError as exc:
            _log(f"--conventions is not valid JSON: {exc}")
            return EXIT_REFUSED
        if not isinstance(conventions, list):
            _log("--conventions must be a JSON array of convention objects")
            return EXIT_REFUSED
        needs_repo = parse_tokens.file_convention_needs_repo(conventions)
        if needs_repo:
            _log(needs_repo)
            return EXIT_REFUSED
        with open(args.source_file, encoding="utf-8") as fh:
            text = fh.read()
        desired, declined = desired_from_source(text, conventions, args.prefix)
        print(json.dumps({"desired": desired, "declined": declined}, indent=2))
        return EXIT_OK

    if cmd == "diff":
        desired = _load_json_file(args.desired)
        if isinstance(desired, dict):  # accept a build-desired envelope too
            desired = desired["desired"]
        live = _load_json_file(args.live)
        if isinstance(live, dict):  # accept a get_tokens result envelope too
            live = live.get("tokens", live.get("result", {}).get("tokens", []))
        # No source text here — this subcommand diffs two given token sets — so
        # there is nothing we "declared but could not read". Stated, not defaulted.
        print(json.dumps(
            diff_tokens(desired, live, owned_prefix=args.owned_prefix, unreadable=set()),
            indent=2,
        ))
        return EXIT_OK

    if cmd == "simulate-apply":
        live = _load_json_file(args.live)
        if isinstance(live, dict):
            live = live.get("tokens", live.get("result", {}).get("tokens", []))
        diff = _load_json_file(args.diff)
        print(json.dumps(simulate_apply(live, diff), indent=2))
        return EXIT_OK

    parser.print_usage(sys.stderr)
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main())
