#!/usr/bin/env bats
# Unit tests for lib/emit_tokens.py — the Paper -> CSS reverse direction (U4).
#
# The pure emit (tokens -> CSS) and the R5 round-trip (emit -> parse ->
# build_desired -> diff) are exercised offline via `emit-from-file` and
# `roundtrip` against a fixture Paper token set. The live `run` refuse guards
# (no config, in-place dual-convention) are exercised without a daemon.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    EMIT="$SCRIPT_DIR/lib/emit_tokens.py"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"
    TOKENS="$FIXTURE_DIR/paper_tokens_for_emit.json"
    DA_CONV='[{"type":"data-attribute","attr":"data-theme","value":"dark","primary":true}]'
    MQ_CONV='[{"type":"media-query","query":"(prefers-color-scheme: dark)","primary":true}]'
    CLASS_CONV='[{"type":"class","class":"wcs-dark","primary":true}]'
}

# A two-token Paper set (one base + its dark twin) — small enough to assert the
# emitted bytes exactly, which is what the backward-compat guards need.
minimal_tokens() {
    local path="$BATS_TMPDIR/emit_minimal_tokens.json"
    cat > "$path" <<'JSON'
[
  { "name": "--brand-bg", "type": "color", "value": "#FFFFFF" },
  { "name": "--brand-bg-dark", "type": "color", "value": "#101010" }
]
JSON
    echo "$path"
}

# ============================================================================
# R4 — a base + -dark twin set emits :root + a dark block (data-attribute)
# ============================================================================

@test "emit (data-attribute): base :root block + dark [data-theme] override block" {
    run python3 "$EMIT" emit-from-file --tokens "$TOKENS" --conventions "$DA_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    [[ "$output" == *":root {"* ]]
    [[ "$output" == *'--brand-green-500: #37D895;'* ]]
    [[ "$output" == *':root[data-theme="dark"] {'* ]]
    # dark override carries the dark literal
    [[ "$output" == *'--brand-bg: #101010;'* ]]
}

# ============================================================================
# R4 — media-query primary emits an @media block wrapping :root
# ============================================================================

@test "emit (media-query): dark block is @media (prefers-color-scheme: dark) { :root { … } }" {
    run python3 "$EMIT" emit-from-file --tokens "$TOKENS" --conventions "$MQ_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    [[ "$output" == *"@media (prefers-color-scheme: dark) {"* ]]
    [[ "$output" == *":root {"* ]]
}

# ============================================================================
# KTD4 — the dark alias referent is de-suffixed: var(--x-dark) -> var(--x)
# ============================================================================

@test "emit: a dark alias stored as var(--…-dark) emits as var(--…) in the dark scope" {
    run python3 "$EMIT" emit-from-file --tokens "$TOKENS" --conventions "$DA_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    # accent's dark twin is var(--brand-green-500-dark) in Paper; emitted dark
    # scope must reference the plain name, NOT the -dark twin.
    [[ "$output" == *'--brand-accent: var(--brand-green-500);'* ]]
    [[ "$output" != *'var(--brand-green-500-dark)'* ]]
}

# ============================================================================
# R4 — base aliases keep the var() form, not a resolved literal
# ============================================================================

@test "emit: a base alias stored as var(--x) emits as var(--x), not the resolved literal" {
    run python3 "$EMIT" emit-from-file --tokens "$TOKENS" --conventions "$DA_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    # accent's base value is var(--brand-green-500); it must not resolve to #37D895
    base_line=$(echo "$output" | grep -m1 -- '--brand-accent:')
    [[ "$base_line" == *'var(--brand-green-500)'* ]]
}

# ============================================================================
# Edge — a token with no -dark twin emits base-only
# ============================================================================

@test "emit: a base-only token (no -dark twin) appears only in :root, not the dark block" {
    run python3 "$EMIT" emit-from-file --tokens "$TOKENS" --conventions "$DA_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    [[ "$output" == *'--brand-radius: 8px;'* ]]
    # only one occurrence (base), none in the dark scope
    count=$(echo "$output" | grep -c -- '--brand-radius:')
    [ "$count" -eq 1 ]
}

# ============================================================================
# R5 — the round-trip is a token-model fixed point (empty diff)
# ============================================================================

@test "roundtrip (data-attribute): emit -> parse -> build_desired -> diff is empty" {
    run python3 "$EMIT" roundtrip --tokens "$TOKENS" --conventions "$DA_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    empty=$(echo "$output" | jq -r '.empty')
    [ "$empty" = "true" ]
    # no creates/updates/deletes/recreates
    n=$(echo "$output" | jq '[.diff.creates, .diff.updates, .diff.deletes, .diff.recreates] | map(length) | add')
    [ "$n" -eq 0 ]
}

@test "roundtrip (media-query): emit -> parse -> build_desired -> diff is empty" {
    run python3 "$EMIT" roundtrip --tokens "$TOKENS" --conventions "$MQ_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    empty=$(echo "$output" | jq -r '.empty')
    [ "$empty" = "true" ]
}

# ============================================================================
# Safety — refuse without a config; refuse in-place emit onto a dual-convention
# source (KTD7). Neither touches the daemon.
# ============================================================================

@test "run: --repo with no config refuses (no_config), writes nothing" {
    empty="$BATS_TMPDIR/emit_no_config"
    mkdir -p "$empty"
    # refused path logs a diagnostic to stderr; drop it so $output is pure JSON.
    run bash -c "python3 '$EMIT' run --repo '$empty' 2>/dev/null"
    [ "$status" -eq 2 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "no_config" ]
}

@test "run: in-place emit onto a dual-convention source refuses (KTD7), no daemon call" {
    repo="$BATS_TMPDIR/emit_inplace_dual"
    mkdir -p "$repo/styles"
    printf ':root{}\n' > "$repo/styles/tokens.css"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{
  "fileId": "somefile",
  "source": { "path": "styles/tokens.css" },
  "emitTarget": "styles/tokens.css",
  "themeConventions": [
    { "type": "data-attribute", "attr": "data-theme", "value": "dark", "primary": true },
    { "type": "media-query", "query": "(prefers-color-scheme: dark)" }
  ]
}
JSON
    # Dead daemon: if it reached the network the error would differ; KTD7 fires first.
    PAPER_MCP_URL="http://127.0.0.1:1/mcp" run python3 "$EMIT" run --repo "$repo" --url "http://127.0.0.1:1/mcp"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "refused_in_place_dual_convention" ]
    # the source file was not overwritten
    [ "$(cat "$repo/styles/tokens.css")" = ":root{}" ]
}
# ============================================================================
# U4 — regression guard on the SHARED `VAR_ALIAS_RE` seam.
#
# Widening the alias regex in parse_tokens to accept `var(--x, fallback)`
# silently changes emit too, because `_strip_dark_alias` consumes that same
# seam. A dark twin stored as `var(--z-dark, #eee)` now matches where it did
# not before, and re-emits as `var(--z)` — dropping `#eee`. Emit must still
# de-suffix the referent (the round-trip depends on it) and must SAY that it
# discarded the fallback.
# ============================================================================

@test "seam: a dark alias with a var() fallback still de-suffixes the referent" {
    tokens="$BATS_TMPDIR/emit_fallback_tokens.json"
    cat > "$tokens" <<'JSON'
[
  { "name": "--brand-z", "value": "#37D895", "type": "color" },
  { "name": "--brand-z-dark", "value": "#00B72B", "type": "color" },
  { "name": "--brand-y", "value": "var(--brand-z)", "type": "color" },
  { "name": "--brand-y-dark", "value": "var(--brand-z-dark, #eee)", "type": "color" }
]
JSON
    run bash -c "python3 '$EMIT' emit-from-file --tokens '$tokens' --conventions '$DA_CONV' --prefix=--brand- 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *'--brand-y: var(--brand-z);'* ]]
    # the referent lost its -dark; the dangling twin name must not survive
    [[ "$output" != *'var(--brand-z-dark'* ]]
}

@test "seam: emit WARNS when it discards a dark alias's var() fallback" {
    tokens="$BATS_TMPDIR/emit_fallback_tokens.json"
    cat > "$tokens" <<'JSON'
[
  { "name": "--brand-z", "value": "#37D895", "type": "color" },
  { "name": "--brand-z-dark", "value": "#00B72B", "type": "color" },
  { "name": "--brand-y", "value": "var(--brand-z)", "type": "color" },
  { "name": "--brand-y-dark", "value": "var(--brand-z-dark, #eee)", "type": "color" }
]
JSON
    run bash -c "python3 '$EMIT' emit-from-file --tokens '$tokens' --conventions '$DA_CONV' --prefix=--brand- 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"#eee"* ]]
    [[ "$output" == *"fallback"* ]]
}

@test "seam: a plain var(--x-dark) twin emits unchanged and does NOT warn" {
    run bash -c "python3 '$EMIT' emit-from-file --tokens '$TOKENS' --conventions '$DA_CONV' --prefix=--brand- 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" != *"fallback"* ]]
}

# ============================================================================
# U6 / KTD8 — emit inverts a PREDICATE conjunction to a selector.
#
# Class predicates append to the selector, an attribute predicate appends
# [attr="value"], a media predicate wraps the block. Indentation is two spaces
# per nesting level, which is what the pre-U6 type dispatch already emitted —
# the data-attribute and media-query bytes below are PUBLISHED output (1.0.0)
# and the exact-compare guards exist to keep them that way.
# ============================================================================

@test "emit (class): dark block is :root.wcs-dark { … }" {
    tokens="$(minimal_tokens)"
    python3 "$EMIT" emit-from-file --tokens "$tokens" --conventions "$CLASS_CONV" \
        --prefix=--brand- > "$BATS_TMPDIR/emit_class.css"
    cat > "$BATS_TMPDIR/emit_class.expected" <<'CSS'
:root {
  --brand-bg: #FFFFFF;
}

:root.wcs-dark {
  --brand-bg: #101010;
}
CSS
    diff -u "$BATS_TMPDIR/emit_class.expected" "$BATS_TMPDIR/emit_class.css"
}

@test "regression guard: data-attribute emit bytes are unchanged (published 1.0.0 output)" {
    tokens="$(minimal_tokens)"
    python3 "$EMIT" emit-from-file --tokens "$tokens" --conventions "$DA_CONV" \
        --prefix=--brand- > "$BATS_TMPDIR/emit_da.css"
    cat > "$BATS_TMPDIR/emit_da.expected" <<'CSS'
:root {
  --brand-bg: #FFFFFF;
}

:root[data-theme="dark"] {
  --brand-bg: #101010;
}
CSS
    diff -u "$BATS_TMPDIR/emit_da.expected" "$BATS_TMPDIR/emit_da.css"
}

@test "regression guard: media-query emit bytes are unchanged (published 1.0.0 output)" {
    # media-query desugars to a two-predicate conjunction (KTD3); inverting it
    # must reproduce today's @media wrapper with the :root anchor inside, at
    # four-space declaration indent.
    tokens="$(minimal_tokens)"
    python3 "$EMIT" emit-from-file --tokens "$tokens" --conventions "$MQ_CONV" \
        --prefix=--brand- > "$BATS_TMPDIR/emit_mq.css"
    cat > "$BATS_TMPDIR/emit_mq.expected" <<'CSS'
:root {
  --brand-bg: #FFFFFF;
}

@media (prefers-color-scheme: dark) {
  :root {
    --brand-bg: #101010;
  }
}
CSS
    diff -u "$BATS_TMPDIR/emit_mq.expected" "$BATS_TMPDIR/emit_mq.css"
}

@test "emit (internal conjunction): two class predicates emit :root.wcs-theme.wcs-dark" {
    # KTD2a — `match:[…]` is the INTERNAL predicate form; the config validator
    # rejects it, so this exercises the inverter directly, not a config path.
    tokens="$(minimal_tokens)"
    conv='[{"match":[{"class":"wcs-theme"},{"class":"wcs-dark"}],"primary":true}]'
    run python3 "$EMIT" emit-from-file --tokens "$tokens" --conventions "$conv" --prefix=--brand-
    [ "$status" -eq 0 ]
    [[ "$output" == *':root.wcs-theme.wcs-dark {'* ]]
}

@test "emit (internal conjunction): class + media emits the class on the inner rule, media as wrapper" {
    tokens="$(minimal_tokens)"
    conv='[{"match":[{"media":"(prefers-color-scheme: dark)"},{"class":"wcs-dark"}],"primary":true}]'
    python3 "$EMIT" emit-from-file --tokens "$tokens" --conventions "$conv" \
        --prefix=--brand- > "$BATS_TMPDIR/emit_mixed.css"
    cat > "$BATS_TMPDIR/emit_mixed.expected" <<'CSS'
:root {
  --brand-bg: #FFFFFF;
}

@media (prefers-color-scheme: dark) {
  :root.wcs-dark {
    --brand-bg: #101010;
  }
}
CSS
    diff -u "$BATS_TMPDIR/emit_mixed.expected" "$BATS_TMPDIR/emit_mixed.css"
}

@test "emit: an unknown convention type still raises (unchanged refusal)" {
    tokens="$(minimal_tokens)"
    run bash -c "python3 '$EMIT' emit-from-file --tokens '$tokens' --conventions '[{\"type\":\"bogus\",\"primary\":true}]' --prefix=--brand- 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown themeConvention type"* ]]
}

@test "emit: an unrecognized predicate kind refuses rather than emitting a bad selector" {
    tokens="$(minimal_tokens)"
    conv='[{"match":[{"pseudo":":dark"}],"primary":true}]'
    run bash -c "python3 '$EMIT' emit-from-file --tokens '$tokens' --conventions '$conv' --prefix=--brand- 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"predicate"* ]]
}

# ============================================================================
# U6 / R8 — the round-trip is the ONLY thing that proves emit's selector and
# U2's matcher agree. One per config-authorable shape.
# ============================================================================

@test "roundtrip (class): emit -> parse -> build_desired -> diff is empty" {
    run python3 "$EMIT" roundtrip --tokens "$TOKENS" --conventions "$CLASS_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    empty=$(echo "$output" | jq -r '.empty')
    [ "$empty" = "true" ]
}

@test "roundtrip (@layer-wrapped source): a layered stylesheet still round-trips empty" {
    # @layer is a TRANSPARENT wrapper (a bare :root inside one IS the base), so
    # emitted CSS dropped into a layer must re-parse to the same token model.
    # emit itself never writes @layer, so the wrap happens here.
    run python3 - "$SCRIPT_DIR/lib" "$TOKENS" "$CLASS_CONV" <<'PY'
import json, sys, textwrap
sys.path.insert(0, sys.argv[1])
import classify_tokens, emit_tokens, parse_tokens, sync_tokens

tokens = json.load(open(sys.argv[2]))["tokens"]
conventions = json.loads(sys.argv[3])
css = emit_tokens.emit_css(tokens, conventions, "--brand-")
layered = "@layer tokens {\n%s\n}\n" % textwrap.indent(css.rstrip("\n"), "  ")
records = parse_tokens.parse_tokens(layered, conventions, "--brand-")
desired, _ = sync_tokens.build_desired(classify_tokens.classify_tokens(records))
diff = sync_tokens.diff_tokens(desired, tokens)
print("EMPTY" if sync_tokens.is_empty_diff(diff) else json.dumps(diff, indent=2))
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"EMPTY"* ]]
}

# ============================================================================
# file convention — emit writes BOTH halves or neither (KTD4)
# ============================================================================

@test "emit file convention: emit_pair round-trips across the pair" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import emit_tokens as et, parse_tokens as pt, classify_tokens as ct, sync_tokens as st
conv = [{'type':'file','path':'themes/dark.scss','emitTarget':'themes/dark.gen.scss','primary':True}]
paper = [{'name':'--b-a','type':'color','value':'#FFF'},
         {'name':'--b-a-dark','type':'color','value':'#000'},
         {'name':'--b-x','type':'color','value':'#EEE'}]
base, dark = et.emit_pair(paper, conv)
recs = pt.parse_tokens(base, conv, dark_texts={0: dark})
again, _ = st.build_desired(ct.classify_tokens(recs))
d = st.diff_tokens(again, paper, owned_prefix='--b-')
assert st.is_empty_diff(d), d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "emit file convention: emit_css refuses rather than emitting base-only" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import emit_tokens as et
conv = [{'type':'file','path':'d.scss','primary':True}]
try:
    et.emit_css([{'name':'--b-a','type':'color','value':'#FFF'}], conv)
except ValueError as e:
    assert 'emit_pair' in str(e), e
    print('OK')
else:
    raise AssertionError('emit_css must refuse a file convention, not emit base-only')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "emit file convention: no dark emitTarget -> refuses and writes NOTHING" {
    repo="$BATS_TMPDIR/emitpair"; mkdir -p "$repo/themes"
    printf ':root{--b-a:#fff;}' > "$repo/themes/light.scss"
    printf ':root{--b-a:#000;}' > "$repo/themes/dark.scss"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "F1", "paperDaemonUrl": "http://x",
  "source": { "path": "themes/light.scss", "ref": null, "prefix": "--b-" },
  "emitTarget": "themes/light.gen.scss", "primitivePattern": null,
  "themeConventions": [ { "type": "file", "path": "themes/dark.scss", "primary": true } ],
  "harvest": { "themeSignal": { "type": "data-attribute", "attr": "data-theme", "value": "dark" }, "batch": [] } }
JSON
    run python3 -c "
import sys, os, json; sys.path.insert(0, '$SCRIPT_DIR/lib')
import emit_tokens as et
class Fake:
    def __init__(self,*a,**k): pass
    def get_tokens(self, fid):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--b-a','type':'color','value':'#FFF'},
            {'name':'--b-a-dark','type':'color','value':'#000'}]}}
et.PaperClient = Fake
report, code = et.run(repo='$repo')
assert report.get('error') == 'no_dark_emit_target', report
assert code != 0, code
# the load-bearing part: a refusal must not leave a HALF-updated pair on disk
assert not os.path.exists('$repo/themes/light.gen.scss'), 'base was written despite refusing'
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "classify: a dark value that is not a valid instance of the type is DECLINED" {
    # Pre-existing: the type came from the LIGHT value and the dark twin rode
    # along unchecked, so '--x-dark: #{\$shade100}' was stored in Paper as a color.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt, classify_tokens as ct, sync_tokens as st
src = ':root{--brand-a:#ffffff;}[data-theme=\"dark\"]{--brand-a:#{\$junk};}'
recs = pt.parse_tokens(src, [{'type':'data-attribute','attr':'data-theme','value':'dark','primary':True}])
desired, declined = st.build_desired(ct.classify_tokens(recs))
assert desired == [], desired
assert declined and '#{\$junk}' in declined[0]['reason'], declined
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "classify: a matching dark value still syncs (the fix is not over-broad)" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt, classify_tokens as ct, sync_tokens as st
src = ':root{--brand-a:#ffffff;}[data-theme=\"dark\"]{--brand-a:#000000;}'
recs = pt.parse_tokens(src, [{'type':'data-attribute','attr':'data-theme','value':'dark','primary':True}])
desired, declined = st.build_desired(ct.classify_tokens(recs))
names = sorted(d['name'] for d in desired)
assert names == ['--brand-a', '--brand-a-dark'], names
assert not declined, declined
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}
