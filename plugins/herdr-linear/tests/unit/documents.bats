#!/usr/bin/env bats
# U15 — Linear documents in place of a gitignored /docs.
#
# No document is created or modified anywhere real. The curl stand-in records
# what would have been sent and refuses any mutation a test did not permit.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"
    export HERDR_LINEAR_SLATE_ROOT="$WORK/Slate"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_WRITE_ALLOWLIST="$WORK/write-enabled"
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    mkdir -p "$WORK/Slate" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_DOCSDOCSDOCSDOCSDOC" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh documents.sh; do . "$ROOT/lib/$f"; done

    WT="$WORK/Slate/wt"; mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-2870-detach
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    DOC="$WORK/note.md"
    printf '# Texture leak on image swap\n\nThe pool is never drained.\n\n```ts\nconst x = 1;\n```\n' > "$DOC"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bind_wt() { local n; n="$(herdr_linear::binding_propose "$WT" WEB-2870)"; herdr_linear::binding_confirm "$WT" WEB-2870 "$n"; }
enable_writes() { (cd "$WT" && pwd -P) > "$HERDR_LINEAR_WRITE_ALLOWLIST"; }
sent() { local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------------------------- titles

# Derived from 40 real documents, not invented. An unlisted kind is refused
# rather than passed through: a new kind is a decision, and a shared vocabulary
# only works if a title tells you what you are about to read.
@test "an issue-scoped title leads with the identifier and a known kind" {
    run herdr_linear::doc_title WEB-3127 diagnosis "texture leak on image swap"
    [ "$output" = "WEB-3127 diagnosis: texture leak on image swap" ]
}

@test "a project-scoped title carries no identifier" {
    run herdr_linear::doc_title "" RFC "Brand Vocab"
    [ "$output" = "RFC: Brand Vocab" ]
}

@test "an unknown kind is refused rather than corrected" {
    for k in postmortem notes writeup ""; do
        run herdr_linear::doc_title WEB-1 "$k" "something"
        [ "$status" -ne 0 ]
    done
}

@test "an empty subject is refused" {
    run herdr_linear::doc_title WEB-1 diagnosis ""
    [ "$status" -ne 0 ]
}

# 22 of 40 documents carry no icon. The one consistent use is :mag: on findings
# and diagnosis; everything else gets none.
@test "the icon is applied only to findings and diagnosis" {
    [ "$(herdr_linear::_doc_icon diagnosis)" = ":mag:" ]
    [ "$(herdr_linear::_doc_icon findings)" = ":mag:" ]
    [ -z "$(herdr_linear::_doc_icon reference)" ]
    [ -z "$(herdr_linear::_doc_icon RFC)" ]
    [ -z "$(herdr_linear::_doc_icon test-plan)" ]
}

# ---------------------------------------------------------------- publishing

@test "a document is created against the bound issue and its id recorded" {
    bind_wt; enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::doc_publish "$WT" diagnosis "texture leak" "$DOC"
    [ "$status" -eq 0 ]
    [ "$(sent documentCreate)" = "1" ]
    run grep -c 'WEB-2870' "$FAKE_LINEAR_RECORD_DIR/bodies"
    [ "$output" -ge 1 ]
    run herdr_linear::binding_read "$WT"
    ids="$(printf '%s' "$output" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["created_documents"]))')"
    [ "$ids" = "1" ]
}

# Re-publishing as work progresses must not litter the issue with near-duplicates.
@test "a second publish of the same document updates in place" {
    bind_wt; enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    herdr_linear::doc_publish "$WT" diagnosis "texture leak" "$DOC"
    [ "$(sent documentCreate)" = "1" ]
    run herdr_linear::doc_publish "$WT" diagnosis "texture leak" "$DOC"
    [ "$status" -eq 0 ]
    [ "$(sent documentCreate)" = "1" ]
    [ "$(sent documentUpdate)" = "1" ]
    run herdr_linear::binding_read "$WT"
    ids="$(printf '%s' "$output" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["created_documents"]))')"
    [ "$ids" = "1" ]
}

@test "the file content is sent intact, including code fences" {
    bind_wt; enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    herdr_linear::doc_publish "$WT" diagnosis "texture leak" "$DOC"
    body="$(cat "$FAKE_LINEAR_RECORD_DIR/bodies")"
    [[ "$body" == *"The pool is never drained"* ]]
    [[ "$body" == *'const x = 1;'* ]]
}

# The /docs case: publish a markdown file, taking the subject from its heading.
@test "a local markdown file is published with its heading as the subject" {
    bind_wt; enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::doc_publish_file "$WT" diagnosis "$DOC"
    [ "$status" -eq 0 ]
    body="$(cat "$FAKE_LINEAR_RECORD_DIR/bodies")"
    [[ "$body" == *"WEB-2870 diagnosis: Texture leak on image swap"* ]]
}

@test "a file with no heading falls back to its filename" {
    bind_wt; enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    printf 'no heading here\n' > "$WORK/some-findings.md"
    run herdr_linear::doc_publish_file "$WT" findings "$WORK/some-findings.md"
    [ "$status" -eq 0 ]
    body="$(cat "$FAKE_LINEAR_RECORD_DIR/bodies")"
    [[ "$body" == *"some findings"* ]]
}

# ------------------------------------------------------------- the boundaries

@test "an unbound worktree publishes nothing" {
    enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::doc_publish "$WT" diagnosis "x" "$DOC"
    [ "$status" -eq 1 ]
    [ "$(sent documentCreate)" = "0" ]
}

@test "a worktree outside the Slate root publishes nothing" {
    OUT="$WORK/NotSlate/wt"; mkdir -p "$OUT"
    git -C "$OUT" init -q -b main
    git -C "$OUT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
    n="$(herdr_linear::binding_propose "$OUT" WEB-2870)"; herdr_linear::binding_confirm "$OUT" WEB-2870 "$n"
    printf '%s\n' "$(cd "$OUT" && pwd -P)" > "$HERDR_LINEAR_WRITE_ALLOWLIST"
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::doc_publish "$OUT" diagnosis "x" "$DOC"
    [ "$status" -eq 1 ]
    [ "$(sent documentCreate)" = "0" ]
}

# R32. The list is never derived from Linear -- a tracker-derived "documents on
# this issue" would let anyone attach a document into the writable set.
@test "a document the record does not list is never updated" {
    bind_wt; enable_writes
    run herdr_linear::binding_owns_document "$WT" "somebody-elses-doc-id"
    [ "$status" -ne 0 ]
}

@test "a missing content file is refused before anything is sent" {
    bind_wt; enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::doc_publish "$WT" diagnosis "x" "$WORK/does-not-exist.md"
    [ "$status" -eq 1 ]
    [ "$(sent documentCreate)" = "0" ]
}

# success:true carrying a null document. Trusting `success` alone would record a
# document with no id, which can never be updated -- so the NEXT publish creates
# a duplicate instead of updating. Reachable, and was untested.
@test "a reported success carrying no document is treated as a failure" {
    bind_wt; enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MUTATION_RESULT=no_document
    run herdr_linear::doc_publish "$WT" diagnosis "texture leak" "$DOC"
    [ "$status" -eq 3 ]
    run herdr_linear::binding_read "$WT"
    ids="$(printf '%s' "$output" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["created_documents"]))')"
    [ "$ids" = "0" ]
}

# ------------------------------------------------------------- shadow mode

@test "shadow mode logs the document and sends nothing" {
    bind_wt
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::doc_publish "$WT" diagnosis "texture leak" "$DOC"
    [ "$status" -eq 2 ]
    [ "$(sent documentCreate)" = "0" ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would create document"* ]]
    [[ "$output" == *"WEB-2870 diagnosis: texture leak"* ]]
}

# A 200 carrying success:false is a failed write that a "did we finish" check
# reads as success -- and it must not be recorded as a document we own.
@test "a document the API reports as unsuccessful is not recorded" {
    bind_wt; enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MUTATION_RESULT=fail
    run herdr_linear::doc_publish "$WT" diagnosis "texture leak" "$DOC"
    [ "$status" -eq 3 ]
    run herdr_linear::binding_read "$WT"
    ids="$(printf '%s' "$output" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["created_documents"]))')"
    [ "$ids" = "0" ]
}
