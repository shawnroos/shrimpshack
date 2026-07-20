#!/usr/bin/env bats
# Unit tests for lib/sync_tokens.py — the idempotent token reconcile.
#
# The DIFF ENGINE (diff_tokens) and desired-set builder (build_desired) are PURE
# functions with no git and no daemon, exercised here through the `build-desired`,
# `diff`, and `simulate-apply` subcommands against fixtures. The top-level `run`
# refuse guard is exercised through a --repo pointing at a config with an empty
# fileId (and a --repo with no config at all) — it must short-circuit BEFORE any
# daemon call.
#
# The desired set is regenerated from a single CSS source fixture in setup() (via
# the real parse -> classify -> build pipeline, driven by the config's theme
# conventions + prefix) so these tests always track the pipeline rather than a
# frozen copy.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$SCRIPT_DIR/lib/sync_tokens.py"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"
    SOURCE="$FIXTURE_DIR/reconcile_source.css"
    LIVE="$FIXTURE_DIR/reconcile_live.json"
    # The dark scope's convention + the source prefix (as the config would carry).
    CONVENTIONS='[{"type":"data-attribute","attr":"data-theme","value":"dark","primary":true}]'
    PREFIX="--brand-"

    # Regenerate the desired set from the single source (the {desired, declined}
    # envelope) using the config-driven build-desired path.
    DESIRED="$BATS_TMPDIR/desired.json"
    # --prefix uses the =VALUE form: a bare "--brand-" would be read as a flag.
    python3 "$LIB" build-desired \
        --source-file "$SOURCE" --conventions "$CONVENTIONS" --prefix="$PREFIX" > "$DESIRED"
}

# helper: the diff (creates/updates/deletes/recreates) of desired vs the given live file
diff_vs() { # <live-file>
    python3 "$LIB" diff --desired "$DESIRED" --live "$1"
}

# ============================================================================
# R3 idempotency: desired == live yields an empty diff, zero writes
# ============================================================================

@test "reconcile: R3 idempotent — desired vs identical live is an empty diff" {
    # Use the desired set itself as the live state (a fully-synced file).
    jq '.desired' "$DESIRED" > "$BATS_TMPDIR/live_synced.json"
    run diff_vs "$BATS_TMPDIR/live_synced.json"
    [ "$status" -eq 0 ]
    for bucket in creates updates deletes recreates; do
        n=$(echo "$output" | jq --arg b "$bucket" '.[$b] | length')
        [ "$n" -eq 0 ]
    done
}

# ============================================================================
# R3 idempotency round-trip — apply a divergent diff to the live state, then a
# re-diff is empty. Also exercises create/update/delete/recreate in one pass.
# ============================================================================

@test "reconcile: R3 round-trip — apply diff to live then re-diff yields empty" {
    python3 "$LIB" diff --desired "$DESIRED" --live "$LIVE" > "$BATS_TMPDIR/d1.json"
    # sanity: the first diff is non-empty (there is real work to reconcile)
    [ "$(jq '[.creates,.updates,.deletes,.recreates] | flatten | length' "$BATS_TMPDIR/d1.json")" -gt 0 ]

    python3 "$LIB" simulate-apply --live "$LIVE" --diff "$BATS_TMPDIR/d1.json" > "$BATS_TMPDIR/live2.json"

    run python3 "$LIB" diff --desired "$DESIRED" --live "$BATS_TMPDIR/live2.json"
    [ "$status" -eq 0 ]
    for bucket in creates updates deletes recreates; do
        n=$(echo "$output" | jq --arg b "$bucket" '.[$b] | length')
        [ "$n" -eq 0 ]
    done
}

# ============================================================================
# R2 — a theme-varying token creates a base token AND a -dark twin; the dark
# twin carries the dark value; a dark alias references the dark twin.
# ============================================================================

@test "reconcile: R2 — a theme-varying literal creates both light and dark twins" {
    # The live fixture omits --brand-lasso-fill and its -dark twin entirely.
    run diff_vs "$LIVE"
    [ "$status" -eq 0 ]
    names=$(echo "$output" | jq -r '.creates[].name')
    [[ "$names" == *"--brand-lasso-fill"* ]]
    [[ "$names" == *"--brand-lasso-fill-dark"* ]]
    # the dark twin carries the dark literal, the light twin the light literal
    [ "$(echo "$output" | jq -r '.creates[] | select(.name=="--brand-lasso-fill").value')" = "rgba(55, 216, 149, 0.18)" ]
    [ "$(echo "$output" | jq -r '.creates[] | select(.name=="--brand-lasso-fill-dark").value')" = "rgba(136, 200, 46, 0.16)" ]
}

@test "reconcile: R2 — an alias token is written as var(--brand-*), its dark twin references the dark counterpart" {
    # --brand-nav-active-fg aliases --brand-accent in the base scope.
    light=$(jq -r '.desired[] | select(.name=="--brand-nav-active-fg").value' "$DESIRED")
    [ "$light" = "var(--brand-accent)" ]
    [[ "$light" != *"#"* ]]

    # The dark twin references the DARK counterpart (--brand-accent-dark),
    # never the light name (the -dark alias-flip invariant).
    dark=$(jq -r '.desired[] | select(.name=="--brand-nav-active-fg-dark").value' "$DESIRED")
    [ "$dark" = "var(--brand-accent-dark)" ]

    # The accent itself: base is the var() alias, its dark twin the dark literal.
    [ "$(jq -r '.desired[] | select(.name=="--brand-accent").value' "$DESIRED")" = "var(--brand-green-500)" ]
    [ "$(jq -r '.desired[] | select(.name=="--brand-accent-dark").value' "$DESIRED")" = "#00B72B" ]
}

# ============================================================================
# Decline — a shadow token is reported in declined, never written
# ============================================================================

@test "reconcile: a declined shadow token is reported, never written" {
    # --brand-panel-shadow is a multi-part box-shadow: no Paper type.
    declined=$(jq -r '.declined[].name' "$DESIRED")
    [[ "$declined" == *"--brand-panel-shadow"* ]]

    # It must never appear in the desired write set (neither twin).
    hits=$(jq -r '.desired[].name' "$DESIRED" | grep -c 'panel-shadow' || true)
    [ "$hits" -eq 0 ]

    # And therefore never in any diff bucket against the live fixture.
    run diff_vs "$LIVE"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '[.creates,.updates,.recreates] | flatten | .[].name')" != *"panel-shadow"* ]]
    [[ "$(echo "$output" | jq -r '.deletes[].name')" != *"panel-shadow"* ]]
}

# ============================================================================
# Prefix filter — an unprefixed custom property is excluded from the desired set
# ============================================================================

@test "reconcile: an unprefixed property is excluded by the prefix filter" {
    hits=$(jq -r '[.desired[],.declined[]] | .[].name' "$DESIRED" | grep -c 'other-thing' || true)
    [ "$hits" -eq 0 ]
}

# ============================================================================
# Safety — empty fileId: the command refuses and calls no daemon
# ============================================================================

@test "reconcile: refuses when fileId is empty, writing nothing" {
    repo="$BATS_TMPDIR/repo_empty"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "", "paperDaemonUrl": "http://127.0.0.1:1/mcp",
  "source": { "path": "tokens.css" },
  "themeConventions": [ { "type": "data-attribute", "attr": "data-theme", "value": "dark" } ] }
JSON
    # Diagnostics go to stderr; drop it so $output is the pure JSON report.
    run bash -c "python3 '$LIB' run --repo '$repo' 2>/dev/null"
    # non-zero, distinct refuse code
    [ "$status" -eq 2 ]

    [ "$(echo "$output" | jq -r '.refused')" = "true" ]
    [ "$(echo "$output" | jq -r '.error')" = "no_target_file" ]

    # actionable message names the config key to set
    note=$(echo "$output" | jq -r '.note')
    [[ "$note" == *"fileId"* ]]

    # PROOF no daemon call happened: had it reached get_tokens against the dead
    # port it would report a daemon/get_tokens error, not a refusal.
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
    [[ "$note" != *"get_tokens"* ]]
    [[ "$note" != *"daemon"* ]]
}

@test "reconcile: refuses when no config is found under --repo, writing nothing" {
    repo="$BATS_TMPDIR/repo_none"
    mkdir -p "$repo"
    run bash -c "python3 '$LIB' run --repo '$repo' 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.refused')" = "true" ]
    [ "$(echo "$output" | jq -r '.error')" = "no_config" ]
    # never reached the daemon
    [[ "$(echo "$output" | jq -r '.note')" != *"daemon"* ]]
}

# ============================================================================
# Create ordering — a var() alias must be created AFTER its referent, else
# Paper (which creates in array order) silently drops the alias. Regression for
# the live bug where alphabetical ordering dropped --brand-accent
# (var(--brand-green-500)) and every alias chaining through it.
# ============================================================================

@test "order_for_create: referents precede the aliases that point at them" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
# alphabetical order puts the alias BEFORE its referent; a chain too.
toks = [
  {'name':'--brand-accent','type':'color','value':'var(--brand-green-500)'},
  {'name':'--brand-green-500','type':'color','value':'#37D895'},
  {'name':'--brand-nav-fg','type':'color','value':'var(--brand-accent)'},
]
ordered = [t['name'] for t in sync_tokens.order_for_create(toks)]
# each referent index < its alias index
assert ordered.index('--brand-green-500') < ordered.index('--brand-accent'), ordered
assert ordered.index('--brand-accent') < ordered.index('--brand-nav-fg'), ordered
print('OK', ordered)
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

# ============================================================================
# Serialization idempotency — Paper REWRITES values on store (transparent ->
# #00000000, rgba(r,g,b,a) -> rgb(r g b / a%), 0 -> 0px). The diff must treat
# those as unchanged, else the same tokens churn on every sync (R3). Regression
# for the live bug where 9 tokens re-updated forever.
# ============================================================================

@test "reconcile: Paper's re-serialized values are NOT seen as changes" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
desired = [
  {'name':'--brand-transparent','type':'color','value':'transparent'},
  {'name':'--brand-lasso-fill','type':'color','value':'rgba(55, 216, 149, 0.18)'},
  {'name':'--brand-space-0','type':'spacing','value':'0'},
  {'name':'--brand-accent','type':'color','value':'var(--brand-green-500)'},
]
# what Paper echoes back after storing them
live = [
  {'name':'--brand-transparent','type':'color','value':'#00000000'},
  {'name':'--brand-lasso-fill','type':'color','value':'rgb(55 216 149 / 18%)'},
  {'name':'--brand-space-0','type':'spacing','value':'0px'},
  {'name':'--brand-accent','type':'color','value':'var(--brand-green-500)'},
]
diff = sync_tokens.diff_tokens(desired, live, unreadable=set())
assert sync_tokens.is_empty_diff(diff), diff
# but a genuine change is still caught
live2 = [dict(live[1], value='rgb(1 2 3 / 50%)')] + live[:1] + live[2:]
diff2 = sync_tokens.diff_tokens(desired, live2, unreadable=set())
assert any(u['name']=='--brand-lasso-fill' for u in diff2['updates']), diff2
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

# ============================================================================
# Ownership-scoped deletes — a prefixed sync must NOT delete tokens outside its
# namespace (Paper-native --color-*, another prefix, hand-authored). Only tokens
# the plugin owns (prefix-matching) and absent from source are deleted. With no
# prefix (source is "all custom properties"), the plugin owns the whole file.
# ============================================================================

@test "reconcile: a prefixed sync deletes only owned (prefixed) tokens, never foreign ones" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
# Source defines exactly one owned token.
desired = [{'name':'--brand-accent','type':'color','value':'#37D895'}]
# Live has: the owned token (kept), a STALE owned token (delete), and two
# FOREIGN tokens the plugin doesn't own (must survive a prefixed sync).
live = [
  {'name':'--brand-accent','type':'color','value':'#37D895'},
  {'name':'--brand-stale','type':'color','value':'#111111'},
  {'name':'--color-blue-500','type':'color','value':'#0000FF'},
  {'name':'--legacy-bg','type':'color','value':'#EEEEEE'},
]
# Prefixed sync: only the stale OWNED token is deleted.
diff = sync_tokens.diff_tokens(desired, live, owned_prefix='--brand-', unreadable=set())
dels = sorted(d['name'] for d in diff['deletes'])
assert dels == ['--brand-stale'], dels
# No-prefix sync owns everything: both foreign tokens ARE deleted.
diff_all = sync_tokens.diff_tokens(desired, live, unreadable=set())
dels_all = sorted(d['name'] for d in diff_all['deletes'])
assert dels_all == ['--brand-stale', '--color-blue-500', '--legacy-bg'], dels_all
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "reconcile: diff CLI honors --owned-prefix for delete scoping" {
    echo '[{"name":"--brand-x","type":"color","value":"#111111"}]' > "$BATS_TMPDIR/od_desired.json"
    echo '[{"name":"--brand-x","type":"color","value":"#111111"},{"name":"--brand-old","type":"color","value":"#222222"},{"name":"--color-native","type":"color","value":"#333333"}]' > "$BATS_TMPDIR/od_live.json"
    run python3 "$LIB" diff --desired "$BATS_TMPDIR/od_desired.json" --live "$BATS_TMPDIR/od_live.json" --owned-prefix=--brand-
    [ "$status" -eq 0 ]
    dels=$(echo "$output" | jq -r '.deletes[].name' | sort | tr '\n' ' ')
    [ "$dels" = "--brand-old " ]
}

# ============================================================================
# R7 empty-parse backstop — a source that parses to zero tokens must NOT be
# read as "the codebase deleted everything". Without the guard, a shape the
# parser can't read (a :root wrapped in @layer, standard in Tailwind v4 and
# Open Props) produces an empty desired set, and the diff turns that into a
# delete of every live token — a silent wipe of the Paper file.
# ============================================================================

# helper: write a config + CSS source into a throwaway repo, echo the repo path.
# The daemon URL points at a dead port on purpose — the guard must fire BEFORE
# any daemon call, so reaching the daemon is itself a failure signal.
make_repo() { # <name> <css-source-text>
    local repo="$BATS_TMPDIR/$1"
    mkdir -p "$repo"
    printf '%s' "$2" > "$repo/tokens.css"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "file-abc", "paperDaemonUrl": "http://127.0.0.1:1/mcp",
  "source": { "path": "tokens.css", "prefix": "--brand-" },
  "themeConventions": [ { "type": "data-attribute", "attr": "data-theme", "value": "dark" } ] }
JSON
    echo "$repo"
}

@test "reconcile: an empty desired set against a populated live file produces deletes (the hazard)" {
    # This is what the backstop exists to intercept — asserted directly so the
    # guard's value is visible, and so a future change that quietly stops
    # producing these deletes doesn't leave the guard looking redundant.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
live = [
  {'name':'--brand-accent','type':'color','value':'#37D895'},
  {'name':'--brand-bg','type':'color','value':'#FFFFFF'},
]
diff = sync_tokens.diff_tokens([], live, owned_prefix='--brand-', unreadable=set())
dels = sorted(d['name'] for d in diff['deletes'])
assert dels == ['--brand-accent', '--brand-bg'], dels
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "reconcile: R7 refuses end-to-end when a source with content parses to zero tokens" {
    # Vehicle: a real stylesheet with no custom properties at all — a config
    # pointed at the wrong file. Deliberately NOT @layer: U2 taught the parser
    # to read @layer, so it is no longer a zero-token shape (see the @layer test
    # below). This shape stays unparseable by construction, so the guard's
    # end-to-end path keeps being exercised as the parser grows.
    repo=$(make_repo repo_zero '.button { color: red; }
.card { padding: 8px; }')
    run bash -c "python3 '$LIB' run --repo '$repo' 2>/dev/null"
    [ "$status" -ne 0 ]
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
    [ "$(echo "$output" | jq -r '.refused')" = "true" ]
    [ "$(echo "$output" | jq -r '.error')" = "empty_parse" ]

    # The message names the source path and the likely cause.
    note=$(echo "$output" | jq -r '.note')
    [[ "$note" == *"$repo/tokens.css"* ]]
    [[ "$note" == *"zero tokens"* ]]

    # Applied nothing, and never reached the daemon (a dead port would have
    # reported a get_tokens failure instead of this refusal).
    [ "$(echo "$output" | jq -r '.applied')" = "null" ]
    [[ "$note" != *"get_tokens"* ]]
}

@test "reconcile: the reproduced @layer wipe deletes nothing — it parses, so the guard never has to fire" {
    # The Problem Frame's headline failure: @layer tokens { :root {…} } used to
    # yield [] and turn into a full delete set. Two independent things now stop
    # that, and this asserts the outcome rather than which one did it: the
    # source parses (U2), so the desired set is populated and no delete is
    # produced. Were the parse to regress to zero, R7's guard catches it before
    # the daemon — that path is covered by the end-to-end refusal test above.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
src = '@layer tokens {\n  :root { --brand-accent: #37D895; --brand-bg: #FFFFFF; }\n}'
conv = [{'type':'data-attribute','attr':'data-theme','value':'dark'}]
desired, declined = sync_tokens.desired_from_source(src, conv, '--brand-')
assert len(desired) == 2, desired
live = [
  {'name':'--brand-accent','type':'color','value':'#37D895'},
  {'name':'--brand-bg','type':'color','value':'#FFFFFF'},
]
diff = sync_tokens.diff_tokens(desired, live, owned_prefix='--brand-', unreadable=set())
assert diff['deletes'] == [], diff['deletes']
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "reconcile: R7 refuses when the configured prefix matches nothing in the source" {
    # A misconfigured prefix parses tokens but keeps none of them — the desired
    # set is empty and every OWNED live token would be deleted. Same hazard,
    # same refusal.
    repo=$(make_repo repo_prefix ':root { --other-accent: #37D895; }')
    run bash -c "python3 '$LIB' run --repo '$repo' 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.error')" = "empty_parse" ]
}

@test "reconcile: R7 second arm — a BLANK source against a populated live set refuses, deletes nothing" {
    # The pre-daemon arm cannot fire here: a truncated/emptied file is
    # legitimately "no content", so it falls through. The consequence is the
    # same wipe, and worse under connect's `prefix: null` default (whole-file
    # ownership). Asserted END-TO-END through run() — the earlier tests only
    # checked the pure guard's return value, which is exactly why this slipped.
    run python3 -c "
import sys, json, tempfile, os; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens

repo = tempfile.mkdtemp()
src = os.path.join(repo, 'tokens.css')
open(src, 'w').write('   \n\t\n  ')            # blank — the truncated-file case
json.dump({
  'fileId': 'F1', 'paperDaemonUrl': 'http://x',
  'source': {'path': 'tokens.css', 'ref': None, 'prefix': None},   # null = whole-file ownership
  'emitTarget': 'out.css', 'primitivePattern': None,
  'themeConventions': [{'type':'data-attribute','attr':'data-theme','value':'dark','primary':True}],
  'harvest': {'themeSignal': {'type':'data-attribute','attr':'data-theme','value':'dark'}, 'batch': []},
}, open(os.path.join(repo, 'token-bridge.config.json'), 'w'))

applied = []
class FakeClient:
    def __init__(self, *a, **k): pass
    def get_tokens(self, fid):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-accent','type':'color','value':'#37D895'},
            {'name':'--brand-bg','type':'color','value':'#FFFFFF'},
        ]}}
    def __getattr__(self, n):
        def _rec(*a, **k): applied.append(n); return {'ok': True}
        return _rec
sync_tokens.PaperClient = FakeClient

report, code = sync_tokens.run(repo=repo, apply=True)
assert report.get('refused') is True, report
assert report.get('ok') is False, report
assert code != 0, code
assert report.get('deleted') is None, report          # never even built a delete list
assert applied == [], applied                          # NOTHING was written
print('OK')
"
    [ "$status" -eq 0 ]
    # `run` folds stderr into $output and the guard logs its refusal there, so
    # match anywhere rather than at the start.
    [[ "$output" == *OK* ]]
    # The refusal must actually be reported, not just silently skipped.
    [[ "$output" == *"parsed to zero tokens while 2 owned token(s) are live"* ]]
}

@test "reconcile: R7 second arm does NOT fire when live is also empty (a true no-op)" {
    run python3 -c "
import sys, json, tempfile, os; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
repo = tempfile.mkdtemp()
open(os.path.join(repo, 'tokens.css'), 'w').write('')
json.dump({
  'fileId': 'F1', 'paperDaemonUrl': 'http://x',
  'source': {'path': 'tokens.css', 'ref': None, 'prefix': None},
  'emitTarget': 'out.css', 'primitivePattern': None,
  'themeConventions': [{'type':'data-attribute','attr':'data-theme','value':'dark','primary':True}],
  'harvest': {'themeSignal': {'type':'data-attribute','attr':'data-theme','value':'dark'}, 'batch': []},
}, open(os.path.join(repo, 'token-bridge.config.json'), 'w'))
class FakeClient:
    def __init__(self, *a, **k): pass
    def get_tokens(self, fid): return {'ok': True, 'result': {'tokens': []}}
sync_tokens.PaperClient = FakeClient
report, code = sync_tokens.run(repo=repo, apply=True)
assert report.get('ok') is True, report
assert code == 0, code
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "reconcile: R7 does not fire on a genuinely empty source (no-op, not an error)" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
assert sync_tokens.empty_parse_refusal('', 0, '/x/tokens.css') is None
assert sync_tokens.empty_parse_refusal('   \n\t\n  ', 0, '/x/tokens.css') is None
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "reconcile: R7 treats a comments-only source as empty (no-op, not an error)" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
src = '/* just a header comment */\n// and a line comment\n'
assert sync_tokens.empty_parse_refusal(src, 0, '/x/tokens.css') is None
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "reconcile: R7 does not block a legitimate deletion (source parses to a subset)" {
    # A real deletion — the source still parses, it just has fewer tokens than
    # live. The guard keys on a ZERO-token parse, so this must sail through and
    # still produce its delete.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
src = ':root { --brand-accent: #37D895; }'
# One token parsed => the guard stays quiet.
assert sync_tokens.empty_parse_refusal(src, 1, '/x/tokens.css') is None
# ...and the legitimate delete is still produced.
desired, declined = sync_tokens.desired_from_source(
    src, [{'type':'data-attribute','attr':'data-theme','value':'dark'}], '--brand-')
live = [
  {'name':'--brand-accent','type':'color','value':'#37D895'},
  {'name':'--brand-bg','type':'color','value':'#FFFFFF'},
]
dels = sorted(d['name'] for d in sync_tokens.diff_tokens(desired, live, owned_prefix='--brand-', unreadable=set())['deletes'])
assert dels == ['--brand-bg'], dels
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "reconcile: R7 counts declined tokens as parsed (a declined-only source is not an empty parse)" {
    # Tokens that parsed but were declined downstream are evidence the parse
    # worked. Only a total blank is the unparseable-scope signature.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
assert sync_tokens.empty_parse_refusal(':root { --brand-a: #fff; }', 1, '/x/t.css') is None
r = sync_tokens.empty_parse_refusal(':root { --brand-a: #fff; }', 0, '/x/t.css')
assert r is not None and r['error'] == 'empty_parse', r
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "reconcile: a dark-only token round-trips as an orphan -dark twin, idempotently" {
    # A property declared ONLY in the dark scope is legal and common (Tailwind's
    # typography plugin does it for --prose-*). Found against real minified
    # tailwindcss.com CSS. It lands in Paper as a `-dark` twin with no base
    # beside it — correct, but odd enough to pin.
    run python3 -c "
import sys, json; sys.path.insert(0, '$SCRIPT_DIR/lib')
import classify_tokens as ct, sync_tokens as st, emit_tokens as et, parse_tokens as pt

conv = [{'type': 'class', 'class': 'dark', 'primary': True}]
src = ':root { --brand-normal: #ffffff; }\n.dark, .dark * { --brand-onlydark: #d1d5dc; }'

recs = pt.parse_tokens(src, conv)
od = [t for t in recs if t['name'] == '--brand-onlydark'][0]
assert od['light'] is None and od['dark'] == '#D1D5DC', od

desired, _ = st.build_desired(ct.classify_tokens(recs))
names = sorted(t['name'] for t in desired)
assert names == ['--brand-normal', '--brand-onlydark-dark'], names   # orphan twin, no base

# idempotent: syncing the same source again is a no-op
again, _ = st.build_desired(ct.classify_tokens(pt.parse_tokens(src, conv)))
assert st.is_empty_diff(st.diff_tokens(again, desired, owned_prefix='--brand-', unreadable=set()))

# emit -> parse -> diff is a fixed point
back, _ = st.build_desired(ct.classify_tokens(pt.parse_tokens(et.emit_css(desired, conv), conv)))
assert st.is_empty_diff(st.diff_tokens(back, desired, owned_prefix='--brand-', unreadable=set()))

# and a later base declaration just creates the base token
src2 = src.replace('--brand-normal: #ffffff;', '--brand-normal: #ffffff; --brand-onlydark: #333333;')
grown, _ = st.build_desired(ct.classify_tokens(pt.parse_tokens(src2, conv)))
d = st.diff_tokens(grown, desired, owned_prefix='--brand-', unreadable=set())
assert [t['name'] for t in d['creates']] == ['--brand-onlydark'], d['creates']
assert not d['deletes'], d['deletes']
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "reconcile: END-TO-END run() works with a 'file' themeConvention" {
    # The gap this guards: resolve_dark_texts existed but nothing in production
    # called it, so every file-convention config crashed with an uncaught
    # ValueError through the real CLI. Every other file-convention test called
    # parse_tokens(..., dark_texts=...) directly and sailed past the wiring.
    repo="$BATS_TMPDIR/fileconv_e2e"; mkdir -p "$repo/themes"
    printf ':root{--brand-a:#ffffff;--brand-b:#eeeeee;}' > "$repo/themes/light.scss"
    printf ':root{--brand-a:#000000;}' > "$repo/themes/dark.scss"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "F1", "paperDaemonUrl": "http://x",
  "source": { "path": "themes/light.scss", "ref": null, "prefix": "--brand-" },
  "emitTarget": "out.css", "primitivePattern": null,
  "themeConventions": [ { "type": "file", "path": "themes/dark.scss", "primary": true } ],
  "harvest": { "themeSignal": {"type":"data-attribute","attr":"data-theme","value":"dark"}, "batch": [] } }
JSON
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f): return {'ok': True, 'result': {'tokens': []}}
st.PaperClient = Fake
report, code = st.run(repo='$repo', apply=False)
assert code == 0, (code, report)
created = sorted(report['created'])
assert created == ['--brand-a', '--brand-a-dark', '--brand-b'], created
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "reconcile: an unreadable theme file REFUSES through run(), not a traceback" {
    repo="$BATS_TMPDIR/fileconv_missing"; mkdir -p "$repo/themes"
    printf ':root{--brand-a:#ffffff;}' > "$repo/themes/light.scss"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "F1", "paperDaemonUrl": "http://x",
  "source": { "path": "themes/light.scss", "ref": null, "prefix": "--brand-" },
  "emitTarget": "out.css", "primitivePattern": null,
  "themeConventions": [ { "type": "file", "path": "themes/NOPE.scss", "primary": true } ],
  "harvest": { "themeSignal": {"type":"data-attribute","attr":"data-theme","value":"dark"}, "batch": [] } }
JSON
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f): return {'ok': True, 'result': {'tokens': []}}
st.PaperClient = Fake
report, code = st.run(repo='$repo', apply=True)
assert report.get('refused') is True and code != 0, (code, report)
assert report.get('error') == 'theme_file_unreadable', report
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "classify: a unitless-zero radius dark value still syncs (no over-decline)" {
    # The both-halves check met a pre-existing asymmetry: spacing accepted a bare
    # '0' but radius required px. '--card-radius: 8px' light / '0' dark declined
    # the whole token, which DELETES the live pair on the next sync.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import classify_tokens as ct, sync_tokens as st
recs = [{'name':'--card-radius','light':'8px','dark':'0','light_alias':None,'dark_alias':None}]
desired, declined = st.build_desired(ct.classify_tokens(recs))
names = sorted(d['name'] for d in desired)
assert names == ['--card-radius', '--card-radius-dark'], (names, declined)
assert not declined, declined
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "classify: the decline reason names the real type, not 'usable'" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import classify_tokens as ct, sync_tokens as st
recs = [{'name':'--c','light':'#ffffff','dark':'#{\$x}','light_alias':None,'dark_alias':None}]
_, declined = st.build_desired(ct.classify_tokens(recs))
assert 'is not a color value' in declined[0]['reason'], declined[0]['reason']
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "classify: an unrecognised dark half drops ONLY the twin, never the base" {
    # The over-decline fix caused a worse bug than it fixed: declining the pair
    # deleted a LIVE base token over a dark value classify merely failed to
    # recognise. Degrade instead — the base is never collateral.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt, classify_tokens as ct, sync_tokens as st
src = ':root{--brand-a:#ffffff;}[data-theme=\"dark\"]{--brand-a:#{\$sass};}'
conv = [{'type':'data-attribute','attr':'data-theme','value':'dark','primary':True}]
desired, declined = st.build_desired(ct.classify_tokens(pt.parse_tokens(src, conv, '--brand-')))
assert [d['name'] for d in desired] == ['--brand-a'], desired      # base SURVIVES
assert [d['name'] for d in declined] == ['--brand-a-dark'], declined
live = [{'name':'--brand-a','type':'color','value':'#FFFFFF'},
        {'name':'--brand-a-dark','type':'color','value':'#101010'}]
dels = [d['name'] for d in st.diff_tokens(desired, live, owned_prefix='--brand-', unreadable=set())['deletes']]
assert dels == ['--brand-a-dark'], dels                            # only the twin
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "classify: modern colour functions and rem lengths are recognised" {
    # hsl() is what Tailwind, shadcn and Bootstrap ship by default; treating it
    # as untypable made the degrade fire on ordinary CSS.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import classify_tokens as ct
for v in ['hsl(210 40% 12%)', 'oklch(0.2 0.03 250)', 'color-mix(in srgb, #000 80%, #fff)']:
    assert ct.classify_value('--brand-bg', v)[0] == 'color', (v, ct.classify_value('--brand-bg', v))
assert ct.classify_value('--brand-radius', '0.5rem')[0] == 'radius'
assert ct.classify_value('--brand-gap', '1.5rem')[0] == 'spacing'
# still NOT colours — a layered/partial value must never be mis-typed
for v in ['linear-gradient(hsl(1 2% 3%), #fff)', '0 0 4px hsl(1 2% 3%)']:
    assert ct.classify_value('--brand-bg', v)[0] is None, v
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "every single-file CLI refuses a file convention cleanly, never a traceback" {
    # One shared predicate, because fixing these one at a time kept missing
    # siblings: sync build-desired, status drift, emit-from-file, emit
    # roundtrip, and parse_tokens' own CLI.
    src="$BATS_TMPDIR/cli_guard.css"; printf ':root{--brand-a:#fff;}' > "$src"
    echo '[]' > "$BATS_TMPDIR/cli_guard.json"
    conv='[{"type":"file","path":"dark.scss","primary":true}]'
    L="$SCRIPT_DIR/lib"
    J="$BATS_TMPDIR/cli_guard.json"
    # Build the command as ONE string and let bash -c word-split it. An earlier
    # version quoted "$L/"$inv, making the whole invocation a single filename —
    # python then exited 2 ("can't open file"), silently satisfying the exit
    # assertion for entirely the wrong reason.
    for inv in \
        "$L/sync_tokens.py build-desired --source-file $src --conventions '$conv'" \
        "$L/status.py drift --source-file $src --live-file $J --conventions '$conv'" \
        "$L/emit_tokens.py emit-from-file --tokens $J --conventions '$conv'" \
        "$L/emit_tokens.py roundtrip --tokens $J --conventions '$conv'" ; do
        run bash -c "printf ':root{--brand-a:#fff;}' | python3 $inv 2>&1"
        [ "$status" -eq 2 ]
        [[ "$output" != *Traceback* ]]
        [[ "$output" != *"can't open file"* ]]
        [[ "$output" == *"run --repo"* ]]
    done
}

@test "INVARIANT: a value we cannot type is never written AND never deleted" {
    # The class fix. "I cannot type this" must mean "do not write it" and must
    # NEVER also mean "delete it" — conflating those turned every gap in the
    # recognisers into data loss across three review rounds.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import classify_tokens as ct, sync_tokens as st
live = [{'name':'--b-font-size','type':'fontSize','value':'16px'},
        {'name':'--b-radius','type':'radius','value':'8px'},
        {'name':'--b-radius-dark','type':'radius','value':'4px'}]

# untypable LIGHT half -> base protected
recs = [{'name':'--b-font-size','light':'clamp(1rem,2vw,2rem)','dark':None,'light_alias':None,'dark_alias':None},
        {'name':'--b-radius','light':'8px','dark':'4px','light_alias':None,'dark_alias':None}]
d, dec = st.build_desired(ct.classify_tokens(recs))
dels = [x['name'] for x in st.diff_tokens(d, live, owned_prefix='--b-', unreadable=[x['name'] for x in dec])['deletes']]
assert dels == [], dels

# untypable DARK half -> twin protected, base still written
recs = [{'name':'--b-font-size','light':'16px','dark':None,'light_alias':None,'dark_alias':None},
        {'name':'--b-radius','light':'8px','dark':'clamp(4px,1vw,12px)','light_alias':None,'dark_alias':None}]
d, dec = st.build_desired(ct.classify_tokens(recs))
dels = [x['name'] for x in st.diff_tokens(d, live, owned_prefix='--b-', unreadable=[x['name'] for x in dec])['deletes']]
assert dels == [], dels
assert '--b-radius' in [x['name'] for x in d], d

# a token the SOURCE genuinely removed must STILL delete — the guard must not
# turn into a blanket no-delete
d, dec = st.build_desired(ct.classify_tokens(
    [{'name':'--b-radius','light':'8px','dark':'4px','light_alias':None,'dark_alias':None}]))
dels = [x['name'] for x in st.diff_tokens(d, live, owned_prefix='--b-', unreadable=[x['name'] for x in dec])['deletes']]
assert dels == ['--b-font-size'], dels
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "a declined twin makes a flip-through alias reference the PLAIN name" {
    # Replaces a test that could NOT fail: its fixture declined both twins, so
    # the alias-closure loop iterated an empty set and passed vacuously — the
    # guard could be reverted with the suite still green.
    #
    # The reachable case is a FLIP-THROUGH alias: --b-user aliases --b-ref in
    # light with no independent dark declaration, so its dark value is the
    # referent's flipped literal. Without the guard that emits var(--b-ref-dark),
    # pointing at a twin that is never created — which Paper fails silently.
    # Verified mutation-sensitive: dropping `and not r.get("dark_excluded_reason")`
    # from theme_varying flips this assertion to var(--b-ref-dark).
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
classified = [
  {'name':'--b-ref','light':'#ffffff','dark':'clamp(1px,1vw,2px)','light_alias':None,
   'dark_alias':None,'paper_type':'color','writable':True,
   'dark_excluded_reason':'dark value not typable'},
  {'name':'--b-user','light':'#ffffff','dark':'clamp(1px,1vw,2px)','light_alias':'--b-ref',
   'dark_alias':None,'paper_type':'color','writable':True,'dark_excluded_reason':None},
]
desired, _ = st.build_desired(classified)
by = {d['name']: d['value'] for d in desired}
assert '--b-ref-dark' not in by, by
assert by['--b-user-dark'] == 'var(--b-ref)', by['--b-user-dark']
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "INVARIANT: protection is derived from the SOURCE TEXT, not surviving records" {
    # `unreadable` used to come from `declined`, which only ever holds names that
    # PARSED — so a name the parser never saw (a declined base's twin, a scope
    # predicate miss) was protected by nothing. Deriving it from a flat name
    # sweep of the source covers parse-level gaps of shapes nobody anticipated.
    run python3 -c "
import sys, os, json; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-fs','type':'fontSize','value':'16px'},
            {'name':'--brand-fs-dark','type':'fontSize','value':'14px'}]}}
st.PaperClient = Fake
repo = os.path.join('$BATS_TMPDIR', 'twinprot'); os.makedirs(repo, exist_ok=True)
open(repo+'/t.css','w').write(
  ':root{--brand-fs:clamp(1rem,2vw,2rem);}[data-theme=\"dark\"]{--brand-fs:clamp(.9rem,2vw,1.8rem);}')
json.dump({'fileId':'F1','paperDaemonUrl':'http://x',
  'source':{'path':'t.css','ref':None,'prefix':'--brand-'},
  'emitTarget':'o.css','primitivePattern':None,
  'themeConventions':[{'type':'data-attribute','attr':'data-theme','value':'dark','primary':True}],
  'harvest':{'themeSignal':{'type':'data-attribute','attr':'data-theme','value':'dark'},'batch':[]}},
  open(repo+'/token-bridge.config.json','w'))
report, code = st.run(repo=repo, apply=False)
# the base is untypable AND its live twin must survive
assert report['deleted'] == [], report['deleted']
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "an unresolved import REFUSES rather than deleting the partial's tokens" {
    # `missing` was logged and never acted on — the log line even predicted the
    # deletion. A partial's names are in no text we read, so declared_names
    # cannot protect them by construction; refusing is the only safe answer.
    repo="$BATS_TMPDIR/missimport"; mkdir -p "$repo/css"
    printf '@use "theme/palette";\n:root{--brand-accent:#37D895;}' > "$repo/css/tokens.scss"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "F1", "paperDaemonUrl": "http://x",
  "source": { "path": "css/tokens.scss", "ref": null, "prefix": "--brand-", "followImports": true },
  "emitTarget": "o.css", "primitivePattern": null,
  "themeConventions": [ { "type": "data-attribute", "attr": "data-theme", "value": "dark", "primary": true } ],
  "harvest": { "themeSignal": {"type":"data-attribute","attr":"data-theme","value":"dark"}, "batch": [] } }
JSON
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-accent','type':'color','value':'#37D895'},
            {'name':'--brand-green-500','type':'color','value':'#0F0'}]}}
st.PaperClient = Fake
report, code = st.run(repo='$repo', apply=True)
assert report.get('error') == 'unresolved_imports', report
assert code != 0, code
assert 'deleted' not in report, report
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "delete scoping is prefix-bound — a foreign live token is never removed" {
    # This guard survived mutation in round 5: removing owned_prefix from run()
    # deletes a live Paper-native token. Load-bearing but untested until now.
    repo="$BATS_TMPDIR/ownedscope"; mkdir -p "$repo"
    printf ':root{--brand-a:#ffffff;}' > "$repo/t.css"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "F1", "paperDaemonUrl": "http://x",
  "source": { "path": "t.css", "ref": null, "prefix": "--brand-" },
  "emitTarget": "o.css", "primitivePattern": null,
  "themeConventions": [ { "type": "data-attribute", "attr": "data-theme", "value": "dark", "primary": true } ],
  "harvest": { "themeSignal": {"type":"data-attribute","attr":"data-theme","value":"dark"}, "batch": [] } }
JSON
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-a','type':'color','value':'#FFFFFF'},
            {'name':'--paper-native','type':'color','value':'#123456'}]}}
st.PaperClient = Fake
report, code = st.run(repo='$repo', apply=False)
assert report['deleted'] == [], report['deleted']
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "a THEME file's unresolved import refuses too, not just the base graph" {
    # Round 5 made this a refusal for the base source graph only; the theme
    # graph kept log-and-drop, so a renamed partial under the dark theme still
    # deleted its twins.
    repo="$BATS_TMPDIR/darkmissimport"; mkdir -p "$repo"
    printf ':root{--brand-a:#37D895;}' > "$repo/l.css"
    printf '@import "gone-partial.css";\n:root{--brand-a:#00B72B;}' > "$repo/d.css"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "F1", "paperDaemonUrl": "http://x",
  "source": { "path": "l.css", "ref": null, "prefix": "--brand-", "followImports": true },
  "emitTarget": "o.css", "primitivePattern": null,
  "themeConventions": [ { "type": "file", "path": "d.css", "primary": true } ],
  "harvest": { "themeSignal": {"type":"data-attribute","attr":"data-theme","value":"dark"}, "batch": [] } }
JSON
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-a','type':'color','value':'#37D895'},
            {'name':'--brand-a-dark','type':'color','value':'#00B72B'}]}}
st.PaperClient = Fake
report, code = st.run(repo='$repo', apply=True)
assert report.get('error') == 'unresolved_imports', report
assert code != 0, code
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "a commented-out declaration pins a live token, and SAYS so" {
    # Over-protection is right, but it must not be silent: commenting a
    # declaration out is a normal way to retire a token, and the raw sweep pins
    # it in the target file forever with no signal.
    repo="$BATS_TMPDIR/commentpin"; mkdir -p "$repo"
    printf ':root{--brand-a:#ffffff;}\n/* --brand-legacy: #CCCCCC;  retired */' > "$repo/t.css"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "F1", "paperDaemonUrl": "http://x",
  "source": { "path": "t.css", "ref": null, "prefix": "--brand-" },
  "emitTarget": "o.css", "primitivePattern": null,
  "themeConventions": [ { "type": "data-attribute", "attr": "data-theme", "value": "dark", "primary": true } ],
  "harvest": { "themeSignal": {"type":"data-attribute","attr":"data-theme","value":"dark"}, "batch": [] } }
JSON
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-a','type':'color','value':'#FFFFFF'},
            {'name':'--brand-legacy','type':'color','value':'#CCCCCC'}]}}
st.PaperClient = Fake
report, code = st.run(repo='$repo', apply=False)
assert report['deleted'] == [], report['deleted']          # protected
assert report['pinnedByComment'] == ['--brand-legacy'], report  # and SAID
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "deletion is EXPLICIT: default reports prunable, --prune removes" {
    # Seven review rounds produced twelve data-loss defects and every one was
    # the same sentence: sync inferred "the user removed this" from "absent from
    # my parse". That inference is only sound if the parse is COMPLETE, and it
    # never is. Removing the inference kills the class; guards only narrowed it.
    repo=$(make_repo pruneexplicit ':root{--brand-keep:#ffffff;}')
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
calls = []
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-keep','type':'color','value':'#FFFFFF'},
            {'name':'--brand-gone','type':'color','value':'#000000'}]}}
    def __getattr__(s, n):
        def rec(*a, **k): calls.append(n); return {'ok': True}
        return rec
st.PaperClient = Fake
r, _ = st.run(repo='$repo', apply=True)
assert r['deleted'] == [], r['deleted']
assert r['prunable'] == ['--brand-gone'], r['prunable']
assert calls == [], calls
calls.clear()
r, _ = st.run(repo='$repo', apply=True, prune=True)
assert r['deleted'] == ['--brand-gone'], r['deleted']
assert r['prunable'] == [], r['prunable']
assert calls, 'prune should have written'
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "guard: even an explicit --prune spares a token we could not read" {
    # Mutation-verified load-bearing but untested: dropping the declined union
    # from the unreadable derivation deletes a live -dark twin in the degrade
    # case. The text sweep cannot cover it — the base IS in desired.
    repo=$(make_repo declunion ':root{--brand-a:#ffffff;}[data-theme="dark"]{--brand-a:#{$sass};}')
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-a','type':'color','value':'#FFFFFF'},
            {'name':'--brand-a-dark','type':'color','value':'#111111'}]}}
st.PaperClient = Fake
r, _ = st.run(repo='$repo', apply=False, prune=True)
assert r['deleted'] == [], r['deleted']
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "config: a file convention pointed at source.path is rejected" {
    # emit already refused this exact pair; sync did not. One typo wiped every
    # dark twin, so the guard belongs at config level where it covers sync,
    # status, emit and harvest at once.
    repo="$BATS_TMPDIR/samepathcfg"; mkdir -p "$repo"
    printf ':root{--brand-a:#fff;}' > "$repo/t.css"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "source": { "path": "t.css", "prefix": "--brand-" },
  "themeConventions": [ { "type": "file", "path": "./t.css", "primary": true } ] }
JSON
    run python3 "$SCRIPT_DIR/lib/paper_client.py" read-config --repo "$repo"
    [ "$status" -eq 4 ]
    [[ "$output" == *"same file as 'source.path'"* ]]
}

@test "prune REFUSES when the parse was not complete (malformed source)" {
    # The parser printed "any declaration after it was not read" and the pipeline
    # deleted exactly that token. Pruning is the only destructive operation left,
    # so it requires a parse we can trust — and which declarations were swallowed
    # is precisely what the parser cannot determine.
    repo=$(make_repo parseloss ':root{--brand-a:#ffffff;--brand-b:#eeeeee;}
[data-theme="dark"]{--brand-a:"unterminated ;
--brand-b:#222222;}')
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-a','type':'color','value':'#FFFFFF'},
            {'name':'--brand-a-dark','type':'color','value':'#111111'},
            {'name':'--brand-b','type':'color','value':'#EEEEEE'},
            {'name':'--brand-b-dark','type':'color','value':'#222222'}]}}
st.PaperClient = Fake
r, code = st.run(repo='$repo', apply=True, prune=True)
assert r.get('error') == 'incomplete_parse', r
assert code != 0, code
assert 'deleted' not in r, r
# without --prune it still reports, just does not act
r2, code2 = st.run(repo='$repo', apply=True)
assert r2['ok'] is True and code2 == 0, (code2, r2)
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "prune still works on a source the parser read cleanly" {
    # The guard must not become a blanket no-prune.
    repo=$(make_repo cleanprune ':root{--brand-keep:#ffffff;}')
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-keep','type':'color','value':'#FFFFFF'},
            {'name':'--brand-gone','type':'color','value':'#000000'}]}}
    def __getattr__(s, n):
        def rec(*a, **k): return {'ok': True}
        return rec
st.PaperClient = Fake
r, code = st.run(repo='$repo', apply=True, prune=True)
assert r['deleted'] == ['--brand-gone'], r['deleted']
assert code == 0, code
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "guard: the theme-file text sweep protects its tokens (survived mutation)" {
    repo="$BATS_TMPDIR/themesweepguard"; mkdir -p "$repo"
    printf ':root{--brand-a:#ffffff;}' > "$repo/l.css"
    printf ':root{--brand-a:#111111;--brand-onlydark:#222222;}' > "$repo/d.css"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "F1", "paperDaemonUrl": "http://x",
  "source": { "path": "l.css", "ref": null, "prefix": "--brand-" },
  "emitTarget": "o.css", "primitivePattern": null,
  "themeConventions": [ { "type": "file", "path": "d.css", "primary": true } ],
  "harvest": { "themeSignal": {"type":"data-attribute","attr":"data-theme","value":"dark"}, "batch": [] } }
JSON
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-a','type':'color','value':'#FFFFFF'},
            {'name':'--brand-onlydark-dark','type':'color','value':'#222222'}]}}
st.PaperClient = Fake
r, _ = st.run(repo='$repo', apply=False, prune=True)
assert '--brand-onlydark-dark' not in r['deleted'], r['deleted']
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "completeness fails CLOSED: an unaffirmed parse is not complete" {
    # The property that makes a future unregistered channel safe. No read has
    # happened, so nothing has affirmed anything, so pruning must not proceed.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
complete, reasons = pt.source_completeness()
assert complete is False, complete
assert reasons[0][0] == 'unaffirmed', reasons
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "prune REFUSES on a not-followed package import (the round-8 P0)" {
    # The tool logged 'tokens they declare are not in this parse' and then
    # deleted exactly those tokens: the channel was a local variable that got
    # printed and thrown away.
    repo=$(make_repo notfollowed '@use "@acme/palette";

:root{--brand-radius:4px;}')
    python3 - "$repo" <<'PY'
import json, sys
c = sys.argv[1] + "/token-bridge.config.json"
cfg = json.load(open(c)); cfg["source"]["followImports"] = True
json.dump(cfg, open(c, "w"))
PY
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
CALLS=[]
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-bg','type':'color','value':'#FFFFFF'},
            {'name':'--brand-fg','type':'color','value':'#000000'},
            {'name':'--brand-radius','type':'radius','value':'4px'}]}}
    def set_tokens(s,f,t): CALLS.append(t); return {'ok': True, 'result': {}}
    def create_tokens(s,f,t): return {'ok': True, 'result': {}}
st.PaperClient = Fake
r, code = st.run(repo='$repo', apply=True, prune=True)
assert r.get('error') == 'incomplete_parse', r
assert code != 0, code
assert CALLS == [], CALLS   # nothing was sent to the daemon
kinds = {x['kind'] for x in r['reasons']}
assert 'not_followed' in kinds, r['reasons']
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "allowIncompleteParse is the escape hatch for source you do not own" {
    repo=$(make_repo allowinc '@use "@acme/palette";

:root{--brand-radius:4px;}')
    python3 - "$repo" <<'PY'
import json, sys
c = sys.argv[1] + "/token-bridge.config.json"
cfg = json.load(open(c))
cfg["source"]["followImports"] = True
cfg["source"]["allowIncompleteParse"] = True
json.dump(cfg, open(c, "w"))
PY
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-gone','type':'color','value':'#FFFFFF'},
            {'name':'--brand-radius','type':'radius','value':'4px'}]}}
    def set_tokens(s,f,t): return {'ok': True, 'result': {}}
    def create_tokens(s,f,t): return {'ok': True, 'result': {}}
st.PaperClient = Fake
r, code = st.run(repo='$repo', apply=True, prune=True)
assert r['ok'] is True and code == 0, (code, r)
assert r['deleted'] == ['--brand-gone'], r
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "prune is no longer silently suppressed by a name declared out of scope" {
    # The P1 the redesign removed: moving a token into a component rule made it
    # permanently unprunable, reported ok/pruned with an empty deleted and NO log.
    repo=$(make_repo outofscope ':root{--brand-primary:#0055ff;}
.legacy-card{--brand-retired:#123456;}')
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-primary','type':'color','value':'#0055FF'},
            {'name':'--brand-retired','type':'color','value':'#123456'}]}}
    def set_tokens(s,f,t): return {'ok': True, 'result': {}}
    def create_tokens(s,f,t): return {'ok': True, 'result': {}}
st.PaperClient = Fake
r, code = st.run(repo='$repo', apply=True, prune=True)
assert r['deleted'] == ['--brand-retired'], r
# and it is DISCLOSED as moved-not-retired, never silent
assert r['stillDeclared'] == ['--brand-retired'], r
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "declined tokens are still protected from prune (they parsed fine)" {
    repo=$(make_repo declprot ':root{--brand-a:#ffffff;--brand-shadow:0 1px 2px rgba(0,0,0,.2);}')
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens as st
class Fake:
    def __init__(s,*a,**k): pass
    def get_tokens(s,f):
        return {'ok': True, 'result': {'tokens': [
            {'name':'--brand-a','type':'color','value':'#FFFFFF'},
            {'name':'--brand-shadow','type':'color','value':'#000000'}]}}
    def set_tokens(s,f,t): return {'ok': True, 'result': {}}
    def create_tokens(s,f,t): return {'ok': True, 'result': {}}
st.PaperClient = Fake
r, code = st.run(repo='$repo', apply=True, prune=True)
assert '--brand-shadow' not in r['deleted'], r
assert any(d['name'] == '--brand-shadow' for d in r['declined']), r
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}
