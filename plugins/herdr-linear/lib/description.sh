#!/usr/bin/env bash
# The issue description, maintained from the worktree. Sourced, never executed.
#
# THE PLUGIN OWNS THE WHOLE DESCRIPTION. That was Shawn's decision, taken over a
# fenced managed region that I proposed instead. It is written down here so that
# nobody later reads this file and takes full ownership for an oversight.
#
# WHAT THAT CAN AND CANNOT MEAN
# The repository supplies `## What` -- branch, commits, pull request, files
# touched -- and `## Verification` -- tests and CI. It cannot supply `## Why`.
# Why is intent, and nothing in git holds it. A generator that authored all four
# sections of docs/linear-conventions.md would replace real reasoning with a
# restatement of the diff, which is worse than leaving the field alone.
#
# So the whole description is emitted on every write: sections the plugin can
# derive are rebuilt, and sections it cannot are carried through verbatim, in
# their original order, including headings a person invented that this file has
# never heard of. Full ownership of the DOCUMENT, not of the words in it.
#
# AND EVERY OVERWRITE IS RECOVERABLE.
# The prior description is saved before the mutation. A full-ownership write
# with no undo is the wrong trade at any level of confidence.

HERDR_LINEAR_DESC_BACKUP_DIR="${HERDR_LINEAR_DESC_BACKUP_DIR:-$HOME/.claude/herdr-linear/descriptions}"

# Sections this file knows how to build. Everything else is carried forward.
HERDR_LINEAR_DERIVED_SECTIONS="What Verification"

HERDR_LINEAR_DESC_OK=0
HERDR_LINEAR_DESC_UNCHANGED=1
HERDR_LINEAR_DESC_REFUSED=2
HERDR_LINEAR_DESC_SHADOW=3
HERDR_LINEAR_DESC_FAILED=4

# Split a markdown description into its `## ` sections, preserving order and any
# preamble before the first heading.
herdr_linear::_split_sections() {
    python3 -c '
import sys, json, re
text = sys.stdin.read()
parts, order = {}, []
cur, buf = None, []
for line in text.splitlines():
    m = re.match(r"^##\s+(.+?)\s*$", line)
    if m:
        if cur is not None:
            parts[cur] = "\n".join(buf).strip("\n")
        elif buf and "".join(buf).strip():
            parts["__preamble__"] = "\n".join(buf).strip("\n")
            order.append("__preamble__")
        cur = m.group(1)
        order.append(cur)
        buf = []
    else:
        buf.append(line)
if cur is not None:
    parts[cur] = "\n".join(buf).strip("\n")
elif buf and "".join(buf).strip():
    parts["__preamble__"] = "\n".join(buf).strip("\n")
    order.append("__preamble__")
print(json.dumps({"order": order, "parts": parts}))
'
}

# What the repository can actually say about itself.
herdr_linear::_derive_what() {
    local wt="$1" branch default ahead files pr
    branch="$(herdr_linear::_current_branch "$wt")"
    default="$(herdr_linear::_default_branch "$wt")" || default=""
    ahead=0
    [ -n "$default" ] && ahead="$(herdr_linear::_git "$wt" rev-list --count "origin/$default..HEAD" || echo 0)"
    files=0
    [ -n "$default" ] && files="$(herdr_linear::_git "$wt" diff --name-only "origin/$default...HEAD" | grep -c . || echo 0)"
    pr=""
    if command -v "${HERDR_LINEAR_GH_BIN:-gh}" >/dev/null 2>&1; then
        pr="$("${HERDR_LINEAR_GH_BIN:-gh}" pr view "$branch" --json number,url -q '"#" + (.number|tostring) + " " + .url' 2>/dev/null || true)"
    fi

    printf 'Branch `%s`' "$branch"
    [ "${ahead:-0}" -gt 0 ] 2>/dev/null && printf ', %s commit%s' "$ahead" "$([ "$ahead" = 1 ] || printf s)"
    [ "${files:-0}" -gt 0 ] 2>/dev/null && printf ', %s file%s changed' "$files" "$([ "$files" = 1 ] || printf s)"
    printf '.\n'
    [ -n "$pr" ] && printf '\nPull request %s\n' "$pr"
    return 0
}

herdr_linear::_derive_verification() {
    local wt="$1" out
    # Only what can be READ. A verification section that claims a test run
    # nobody performed is worse than an empty one.
    out="$("${HERDR_LINEAR_GH_BIN:-gh}" pr checks "$(herdr_linear::_current_branch "$wt")" 2>/dev/null \
        | awk '{print $2}' | sort | uniq -c | awk '{printf "%s %s, ", $1, $2}' || true)"
    if [ -n "$out" ]; then
        printf 'CI: %s\n' "${out%, }"
    else
        printf 'No CI result readable from this worktree.\n'
    fi
}

# herdr_linear::render_description <worktree> <current-description>
#
# Emits the complete new description on stdout.
herdr_linear::render_description() {
    local wt="$1" current="$2" what verification
    what="$(herdr_linear::_derive_what "$wt")"
    verification="$(herdr_linear::_derive_verification "$wt")"

    printf '%s' "$current" | herdr_linear::_split_sections \
        | HERDR_LINEAR_WHAT="$what" HERDR_LINEAR_VERIF="$verification" python3 -c '
import sys, json, os

doc = json.load(sys.stdin)
order, parts = doc["order"], doc["parts"]
derived = {"What": os.environ["HERDR_LINEAR_WHAT"], "Verification": os.environ["HERDR_LINEAR_VERIF"]}

# Sections the plugin can derive are rebuilt. EVERY other section -- including
# ones this code has never heard of -- is carried through byte for byte, in the
# position it already occupied. Reordering a description is a rewrite too.
for name in derived:
    parts[name] = derived[name]
    if name not in order:
        order.append(name)

out = []
for name in order:
    body = parts.get(name, "")
    if name == "__preamble__":
        if body.strip():
            out.append(body)
        continue
    out.append("## %s\n\n%s" % (name, body) if body.strip() else "## %s" % name)
sys.stdout.write("\n\n".join(out).rstrip() + "\n")
'
}

herdr_linear::_backup_description() {
    local ident="$1" body="$2" dir f
    dir="$HERDR_LINEAR_DESC_BACKUP_DIR/$ident"
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$HERDR_LINEAR_DESC_BACKUP_DIR" "$dir" 2>/dev/null
    f="$dir/$(date -u +%Y%m%dT%H%M%SZ).md"
    printf '%s' "$body" > "$f" || return 1
    chmod 600 "$f" 2>/dev/null
    printf '%s' "$f"
}

# herdr_linear::describe <worktree>
herdr_linear::describe() {
    local wt="${1:-}" ident resp current rendered opening body backup

    herdr_linear::contains "$wt" || return "$HERDR_LINEAR_DESC_REFUSED"
    # A backstop: write_allowed below already requires state == bound, so
    # mutating this line away turns no test red. It stays because it refuses
    # before any network call and states the precondition where a reader looks
    # for it. Do not read a green suite as evidence it fires.
    [ "$(herdr_linear::binding_state "$wt" 2>/dev/null)" = "bound" ] \
        || return "$HERDR_LINEAR_DESC_REFUSED"
    ident="$(herdr_linear::binding_identifier "$wt")" || return "$HERDR_LINEAR_DESC_REFUSED"
    herdr_linear::write_allowed "$wt" "$ident" || return "$HERDR_LINEAR_DESC_REFUSED"

    resp="$(herdr_linear::_fetch_description "$ident")" || return "$HERDR_LINEAR_DESC_FAILED"
    current="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"].get("description") or "")')"
    opening="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"]["updatedAt"])')"

    rendered="$(herdr_linear::render_description "$wt" "$current")" || return "$HERDR_LINEAR_DESC_FAILED"

    # Nothing to say is a complete answer. Rewriting a description to the same
    # bytes still stamps updatedAt and shows on the activity feed.
    [ "$rendered" != "$current" ] || return "$HERDR_LINEAR_DESC_UNCHANGED"

    if ! herdr_linear::writes_enabled "$wt"; then
        herdr_linear::_shadow_log "SHADOW would rewrite the description of $ident ($(printf '%s' "$rendered" | wc -c | tr -d ' ') bytes)"
        printf '%s' "$rendered"
        return "$HERDR_LINEAR_DESC_SHADOW"
    fi

    # Saved BEFORE the mutation, so a bad render is one command to undo.
    backup="$(herdr_linear::_backup_description "$ident" "$current")" || return "$HERDR_LINEAR_DESC_FAILED"

    herdr_linear::guard_unchanged "$ident" "$opening" || return "$HERDR_LINEAR_DESC_REFUSED"

    body="$(python3 -c '
import sys, json
q = "mutation($id:String!,$d:String!){issueUpdate(id:$id,input:{description:$d}){success}}"
print(json.dumps({"query": q, "variables": {"id": sys.argv[1], "d": sys.argv[2]}}))
' "$ident" "$rendered")" || return "$HERDR_LINEAR_DESC_FAILED"

    resp="$(herdr_linear::query "$body")" || return "$HERDR_LINEAR_DESC_FAILED"
    printf '%s' "$resp" | python3 -c '
import sys, json
try: ok = json.load(sys.stdin)["data"]["issueUpdate"]["success"]
except Exception: sys.exit(1)
sys.exit(0 if ok is True else 1)
' || return "$HERDR_LINEAR_DESC_FAILED"

    herdr_linear::_shadow_log "WROTE description of $ident (prior saved at $backup)"
    return "$HERDR_LINEAR_DESC_OK"
}

herdr_linear::_fetch_description() {
    local body
    body="$(python3 -c '
import sys, json
print(json.dumps({"query":"query($id:String!){issue(id:$id){identifier description updatedAt}}",
                  "variables":{"id":sys.argv[1]}}))
' "$1")" || return 1
    herdr_linear::query "$body"
}

# herdr_linear::describe_restore <identifier> [backup-file]
# Puts a saved description back. Newest by default.
herdr_linear::describe_restore() {
    local ident="${1:-}" f dir
    dir="$HERDR_LINEAR_DESC_BACKUP_DIR/$ident"
    f="${2:-}"
    [ -n "$f" ] || f="$(ls -1 "$dir"/*.md 2>/dev/null | tail -1)"
    [ -n "$f" ] && [ -r "$f" ] || return "$HERDR_LINEAR_DESC_REFUSED"
    cat "$f"
}

herdr_linear::describe_backups() {
    ls -1 "$HERDR_LINEAR_DESC_BACKUP_DIR/${1:-}"/*.md 2>/dev/null
}
