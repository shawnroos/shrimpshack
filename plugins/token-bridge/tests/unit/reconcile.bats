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
diff = sync_tokens.diff_tokens(desired, live)
assert sync_tokens.is_empty_diff(diff), diff
# but a genuine change is still caught
live2 = [dict(live[1], value='rgb(1 2 3 / 50%)')] + live[:1] + live[2:]
diff2 = sync_tokens.diff_tokens(desired, live2)
assert any(u['name']=='--brand-lasso-fill' for u in diff2['updates']), diff2
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}
