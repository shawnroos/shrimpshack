#!/usr/bin/env bash
# Linear documents, in place of a gitignored /docs. Sourced, never executed.
#
# WHY THIS EXISTS
# Slate's web-app ignores /docs, so a durable document written on a branch dies
# with the worktree -- the same failure this whole plugin exists to stop, in a
# different shape. A Linear document outlives the branch, is attached to the
# work, and is readable by people who do not have the repository.
#
# THE WRITE BOUND EXTENDS HERE UNCHANGED.
# A document id joins `created_documents` on the binding when the plugin creates
# it, and only ids on that list may be updated later. The list is NEVER derived
# from Linear: asking the tracker "which documents are on this issue" would let
# anyone who can attach a document move it into the writable set. Exactly the
# reasoning behind created_children, and the same failure it prevents.
#
# TITLES FOLLOW docs/linear-conventions.md, WHICH WAS DERIVED, NOT INVENTED.
# Its Documents section came from 40 real documents in the workspace. An
# issue-scoped title leads with the identifier and a kind word from the observed
# set; icons are sparse, with `:mag:` reserved for findings and diagnosis.

# The kinds actually in use. A new kind is a decision, and the point of a shared
# vocabulary is that a title tells you what you are about to read -- so an
# unlisted kind is REFUSED rather than passed through.
HERDR_LINEAR_DOC_KINDS_ISSUE="diagnosis findings regression-report implementation-log reference test-plan"
HERDR_LINEAR_DOC_KINDS_PROJECT="RFC PRD plan development-plan architecture-overview codebase-exploration design-references"

HERDR_LINEAR_DOC_OK=0
HERDR_LINEAR_DOC_REFUSED=1
HERDR_LINEAR_DOC_SHADOW=2
HERDR_LINEAR_DOC_FAILED=3

# The one icon convention that holds: :mag: on a findings or diagnosis document,
# nothing otherwise. 22 of 40 documents carry no icon at all.
herdr_linear::_doc_icon() {
    case "$1" in
        diagnosis|findings) printf ':mag:' ;;
        *) printf '' ;;
    esac
}

herdr_linear::_kind_known() {
    local k="$1" candidate
    for candidate in $HERDR_LINEAR_DOC_KINDS_ISSUE $HERDR_LINEAR_DOC_KINDS_PROJECT; do
        [ "$k" = "$candidate" ] && return 0
    done
    return 1
}

# True for a kind in the project-scoped list. `doc_publish` has no projectId
# path -- it always resolves an issue and always sets issueId -- so accepting
# one of these here would silently mis-scope the document rather than error.
herdr_linear::_kind_is_project() {
    local k="$1" candidate
    for candidate in $HERDR_LINEAR_DOC_KINDS_PROJECT; do
        [ "$k" = "$candidate" ] && return 0
    done
    return 1
}

# herdr_linear::doc_title <identifier> <kind> <what>
# `WEB-3127 diagnosis: texture leak on image swap`
herdr_linear::doc_title() {
    local ident="${1:-}" kind="${2:-}" what="${3:-}" pretty
    herdr_linear::_kind_known "$kind" || return 1
    [ -n "$what" ] || return 1
    # The hyphenated forms above are how a caller passes them; the title carries
    # the human spelling seen in the workspace.
    pretty="$(printf '%s' "$kind" | tr '-' ' ')"
    if [ -n "$ident" ]; then
        printf '%s %s: %s' "$ident" "$pretty" "$what"
    else
        printf '%s: %s' "$pretty" "$what"
    fi
}

herdr_linear::_doc_mutation() {
    local op="$1" ident="$2" title="$3" icon="$4" content_file="$5" doc_id="$6"
    python3 -c '
import sys, json
op, ident, title, icon, path, doc_id = sys.argv[1:7]
content = open(path).read() if path else ""
if op == "create":
    q = ("mutation($t:String!,$c:String,$i:String,$icon:String){"
         "documentCreate(input:{title:$t,content:$c,issueId:$i,icon:$icon})"
         "{success document{id title url}}}")
    v = {"t": title, "c": content, "i": ident, "icon": icon or None}
else:
    q = ("mutation($id:String!,$t:String!,$c:String){"
         "documentUpdate(id:$id,input:{title:$t,content:$c})"
         "{success document{id title url}}}")
    v = {"id": doc_id, "t": title, "c": content}
print(json.dumps({"query": q, "variables": v}))
' "$op" "$ident" "$title" "$icon" "$content_file" "$doc_id"
}

# herdr_linear::doc_publish <worktree> <kind> <what> <content-file>
#
# Creates on the first call and updates in place thereafter, so re-publishing a
# document as work progresses does not litter the issue with near-duplicates.
herdr_linear::doc_publish() {
    local wt="${1:-}" kind="${2:-}" what="${3:-}" file="${4:-}"
    local ident title icon doc_id body resp new_id

    # Project-scoped kinds have no mutation path: this function always resolves
    # an issue from the worktree's binding and always sets issueId. Whether an
    # agent may create a project-scoped document at all is listed under "Not
    # yet settled" in docs/linear-conventions.md -- a question for Shawn, not
    # one this function gets to answer by building a projectId path.
    herdr_linear::_kind_is_project "$kind" && {
        printf 'doc: "%s" is a project-scoped kind; publishing a project document is not implemented (see "Not yet settled" in docs/linear-conventions.md) -- ask before deciding this\n' "$kind" >&2
        return "$HERDR_LINEAR_DOC_REFUSED"
    }

    herdr_linear::contains "$wt" || return "$HERDR_LINEAR_DOC_REFUSED"
    [ "$(herdr_linear::binding_state "$wt" 2>/dev/null)" = "bound" ] \
        || return "$HERDR_LINEAR_DOC_REFUSED"
    [ -r "$file" ] || return "$HERDR_LINEAR_DOC_REFUSED"

    ident="$(herdr_linear::binding_identifier "$wt")" || return "$HERDR_LINEAR_DOC_REFUSED"
    title="$(herdr_linear::doc_title "$ident" "$kind" "$what")" || return "$HERDR_LINEAR_DOC_REFUSED"
    icon="$(herdr_linear::_doc_icon "$kind")"

    # Already published under this exact title: update that one.
    doc_id="$(herdr_linear::binding_document_for "$wt" "$title" 2>/dev/null)" || doc_id=""

    if [ -n "$doc_id" ]; then
        # A backstop, and unreachable today: document_for only ever returns an
        # id that is already in created_documents, so this cannot fail and
        # mutating it away turns no test red. It stays so that a future change
        # to how doc_id is resolved -- from a cache, a flag, a caller argument
        # -- cannot reach the update path without an ownership check.
        herdr_linear::binding_owns_document "$wt" "$doc_id" || return "$HERDR_LINEAR_DOC_REFUSED"
        body="$(herdr_linear::_doc_mutation update "$ident" "$title" "$icon" "$file" "$doc_id")" \
            || return "$HERDR_LINEAR_DOC_FAILED"
    else
        body="$(herdr_linear::_doc_mutation create "$ident" "$title" "$icon" "$file" "")" \
            || return "$HERDR_LINEAR_DOC_FAILED"
    fi

    if ! herdr_linear::writes_enabled "$wt"; then
        herdr_linear::_shadow_log "SHADOW would $( [ -n "$doc_id" ] && printf update || printf create ) document \"$title\" on $ident ($(wc -c < "$file" | tr -d ' ') bytes)"
        printf '%s' "$title"
        return "$HERDR_LINEAR_DOC_SHADOW"
    fi

    resp="$(herdr_linear::query "$body")" || return "$HERDR_LINEAR_DOC_FAILED"

    # Recorded from the API's own answer, never from reaching the end.
    new_id="$(printf '%s' "$resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)["data"]
    p = d.get("documentCreate") or d.get("documentUpdate")
    if not p or p.get("success") is not True: sys.exit(1)
    sys.stdout.write((p.get("document") or {}).get("id", ""))
except Exception:
    sys.exit(1)
')" || return "$HERDR_LINEAR_DOC_FAILED"
    [ -n "$new_id" ] || return "$HERDR_LINEAR_DOC_FAILED"

    herdr_linear::binding_add_document "$wt" "$new_id" "$title"
    herdr_linear::_shadow_log "PUBLISHED document \"$title\" ($new_id) on $ident"
    printf '%s' "$new_id"
    return "$HERDR_LINEAR_DOC_OK"
}

# herdr_linear::doc_publish_file <worktree> <kind> <path>
#
# The /docs case: take a markdown file written during the work and publish it,
# deriving `what` from its first heading so the title matches the document.
herdr_linear::doc_publish_file() {
    local wt="${1:-}" kind="${2:-}" path="${3:-}" what
    [ -r "$path" ] || return "$HERDR_LINEAR_DOC_REFUSED"
    what="$(sed -n 's/^#[[:space:]]\{1,\}//p' "$path" | head -1)"
    # `tr '-_' ...` is a portability trap: BSD tr reads the leading hyphen as an
    # option flag and errors out, so the fallback produced an empty subject and
    # the publish was refused. The hyphen goes last in the set.
    [ -n "$what" ] || what="$(basename "$path" .md | tr '_-' '  ')"
    # An untrusted-looking title from a file is still bound for a Linear field,
    # not a path, so it is length-capped rather than slugged.
    what="$(printf '%s' "$what" | cut -c1-120)"
    herdr_linear::doc_publish "$wt" "$kind" "$what" "$path"
}
