#!/usr/bin/env bash
# The issue description. Sourced, never executed.
#
# THE PLUGIN OWNS THE DESCRIPTION, AND OWNS EXACTLY ONE THING ABOUT IT.
# Shawn chose full ownership over the fenced managed region I proposed. But
# ownership here means owning the TEMPLATE, the VALIDATION and the WRITE -- not
# authoring the prose. Nothing in git can write Problem, Solution or Proposal:
# those are about the actor and the intent, and a repository holds neither.
#
# An earlier version of this file derived `## What` from the branch and commit
# count and `## Verification` from CI. That was wrong twice over: those headings
# are not in the template at all, and "branch X, 4 commits" is precisely the
# diary content the template forbids. Both are gone.
#
# THE SPINE, from docs/linear-conventions.md:
#   ## Problem     the actor's problem, first and second order effects
#   ## Solution    the same actor's world without it, IMPLEMENTATION NEUTRAL
#   ## Proposal    what is being built, for a non-technical reader
# Sections after Proposal are decided per ticket.
#
# NEVER A DIARY. The description is always the latest source of truth, never a
# log. This is the rule an automated writer breaks first, because appending is
# easier than rewriting -- so it is enforced structurally here rather than left
# to good intentions, and a write that looks like accumulation is REFUSED.
#
# AND EVERY OVERWRITE IS RECOVERABLE. The prior description is saved before the
# mutation. Full ownership with no undo is the wrong trade at any confidence.

HERDR_LINEAR_DESC_BACKUP_DIR="${HERDR_LINEAR_DESC_BACKUP_DIR:-$HOME/.claude/work/descriptions}"

# The spine, in order. Anything after Proposal is the ticket's own business.
HERDR_LINEAR_DESC_SPINE="Problem Solution Proposal"

HERDR_LINEAR_DESC_OK=0
HERDR_LINEAR_DESC_UNCHANGED=1
HERDR_LINEAR_DESC_REFUSED=2
HERDR_LINEAR_DESC_SHADOW=3
HERDR_LINEAR_DESC_FAILED=4
HERDR_LINEAR_DESC_MALFORMED=5   # does not follow the template
HERDR_LINEAR_DESC_DIARY=6       # reads as a log rather than current truth

# The skeleton, for a ticket that has no description at all. Placeholders are
# deliberately obvious: a half-filled template is visibly unfinished, whereas
# plausible filler reads as a real description nobody wrote.
herdr_linear::description_template() {
    cat <<'TEMPLATE'
## Problem

<the problem as it affects the actor — user, customer, internal staff — with its
first and second order effects>

### For example:
- <example showing the implication in the experience>
- <example>

## Solution

<what that same actor's world looks like when the problem does not exist.
implementation neutral: describe the scenario, not the mechanism>

### For example:
- <benefit of the problem not existing>
- <benefit>

## Proposal

<what we are building, for a non-technical reader, without fluff>

### Key Requirements
- <framing, decision or perspective shaping the work>
- <key point>

### Constraints
- <technical, business or UX constraint>
- <constraint>
TEMPLATE
}

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

# herdr_linear::description_validate <file> [strict]
#
# TWO CLASSES OF RULE, AND THE SPLIT IS THE POINT.
#
# HARD (always refused): a diary, unfilled placeholders, an empty section. These
# are defects in any description whatever its shape.
#
# ADVISORY (reported, not refused): the Problem / Solution / Proposal spine. It
# is the default a NEW description starts from, not a gate every description
# must pass.
#
# Why advisory: WEB-3214 "Improve AI tools analytics" is a ticket Shawn holds up
# as good, and it uses none of those three headings. It uses `## Why`, `## The
# shape of this work`, `## Two things everyone reading these dashboards needs to
# know`, `## Worth agreeing before GA, not after`. Those headings are arguments
# -- a reader can act on them -- where `## Constraints` is a heading people skim
# past. An earlier version of this function REJECTED that ticket, which is the
# validator being wrong rather than the ticket.
#
# Pass `strict` when composing a fresh description from the template, where the
# spine is what you asked for and its absence means the template was abandoned
# halfway.
herdr_linear::description_validate() {
    local f="${1:-}" mode="${2:-lenient}"
    [ -r "$f" ] || return "$HERDR_LINEAR_DESC_MALFORMED"
    herdr_linear::_split_sections < "$f" | HERDR_LINEAR_DESC_MODE="$mode" python3 -c '
import sys, json, os, re

doc = json.load(sys.stdin)
order = [o for o in doc["order"] if o != "__preamble__"]
parts = doc["parts"]
spine = ["Problem", "Solution", "Proposal"]
strict = os.environ.get("HERDR_LINEAR_DESC_MODE") == "strict"
hard, advisory = [], []

missing = [x for x in spine if x not in order]
if missing:
    (hard if strict else advisory).append(
        "not using the Problem/Solution/Proposal shape (missing: %s)" % ", ".join(missing))

# Order only matters among the spine sections actually present.
present = [o for o in order if o in spine]
if present and present != [x for x in spine if x in present]:
    (hard if strict else advisory).append(
        "spine out of order: got %s, want Problem then Solution then Proposal" % " then ".join(present))

# HARD from here down. An empty heading and a leftover placeholder are defects
# in any description, whatever headings it chose.
for name in order:
    body = parts.get(name, "")
    if not body.strip():
        hard.append("%s is empty" % name)
    # A placeholder is `<lowercase prose>`. It is NOT a markdown autolink:
    # WEB-3214 ends with `<https://claude.ai/...>`, which is valid markdown and
    # matched the first version of this pattern -- the validator calling a real
    # ticket unfinished because it cited a source properly.
    if re.search(r"<(?![^>]*(?:://|@))[a-z][^>]{4,}>", body or ""):
        hard.append("%s still contains template placeholders" % name)

# NEVER A DIARY. Two independent shapes, because a writer reaches for both.
# A date in PROSE is fine -- WEB-3214 opens with "Measured 25 Aug 2026" and is
# not a diary. It is dated HEADINGS that mark a log.
head_dates = re.findall(
    r"^#{2,4}\s.*(?:\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b)",
    "\n".join("## %s\n%s" % (k, v) for k, v in parts.items()), re.M | re.I)
if len(head_dates) >= 2:
    hard.append("reads as a diary: %d dated headings" % len(head_dates))

log_words = re.findall(r"^\s*(?:[-*]\s*)?(?:update|progress|session \d|today|changelog|worklog)\b[:\-]",
                       "\n".join(parts.values()), re.M | re.I)
if log_words:
    hard.append("reads as a diary: log-style entries (%s)"
                % ", ".join(sorted(set(w.lower() for w in log_words))[:3]))

for a in advisory:
    sys.stderr.write("description: note: %s\n" % a)
for e in hard:
    sys.stderr.write("description: %s\n" % e)
sys.exit(1 if hard else 0)
' || return "$HERDR_LINEAR_DESC_MALFORMED"
    return "$HERDR_LINEAR_DESC_OK"
}

# Does this write LOOK like an append to what is already there? A description
# that is the previous one plus more is a diary however it is worded, and this
# catches the shape without needing to recognise the wording.
herdr_linear::description_is_append() {
    local prev="$1" next="$2"
    [ -n "$prev" ] || return 1
    case "$next" in
        "$prev"*) return 0 ;;
    esac
    return 1
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

# herdr_linear::describe <worktree> <authored-file>
#
# The caller supplies the whole description. This function does not write prose
# and must not start to: Problem, Solution and Proposal are about the actor and
# the intent, and no amount of repository state stands in for either.
herdr_linear::describe() {
    local wt="${1:-}" file="${2:-}" ident resp current opening body backup next

    herdr_linear::contains "$wt" || return "$HERDR_LINEAR_DESC_REFUSED"
    # A backstop: write_allowed below already requires state == bound, so
    # mutating this line away turns no test red. It stays because it refuses
    # before any network call and states the precondition where a reader looks
    # for it. Do not read a green suite as evidence it fires.
    [ "$(herdr_linear::binding_state "$wt" 2>/dev/null)" = "bound" ] \
        || return "$HERDR_LINEAR_DESC_REFUSED"
    ident="$(herdr_linear::binding_identifier "$wt")" || return "$HERDR_LINEAR_DESC_REFUSED"
    herdr_linear::write_allowed "$wt" "$ident" || return "$HERDR_LINEAR_DESC_REFUSED"

    [ -r "$file" ] || return "$HERDR_LINEAR_DESC_MALFORMED"
    herdr_linear::description_validate "$file" || return "$HERDR_LINEAR_DESC_MALFORMED"
    next="$(cat "$file")"

    resp="$(herdr_linear::_fetch_description "$ident")" || return "$HERDR_LINEAR_DESC_FAILED"
    current="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"].get("description") or "")')"
    opening="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"]["updatedAt"])')"

    # Nothing to say is a complete answer. Rewriting to the same bytes still
    # stamps updatedAt and shows on the activity feed.
    #
    # This MUST precede the append check below: an identical description is a
    # prefix of itself, so checking for an append first reported every no-op
    # write as a diary -- a confusing false accusation for the commonest case.
    [ "$next" != "$current" ] || return "$HERDR_LINEAR_DESC_UNCHANGED"

    # The structural anti-diary check, and the reason it sits here rather than in
    # validate: it needs the CURRENT description to compare against. A new
    # description that begins with the whole of the old one is an append, which
    # is a diary whatever the words say.
    if herdr_linear::description_is_append "$current" "$next"; then
        printf 'description: this write only appends to what is already there; the description is the latest truth, not a log\n' >&2
        return "$HERDR_LINEAR_DESC_DIARY"
    fi

    if ! herdr_linear::writes_enabled "$wt"; then
        herdr_linear::_shadow_log "SHADOW would rewrite the description of $ident ($(printf '%s' "$next" | wc -c | tr -d ' ') bytes)"
        printf '%s' "$next"
        return "$HERDR_LINEAR_DESC_SHADOW"
    fi

    # Saved BEFORE the mutation, so a bad description is one command to undo.
    backup="$(herdr_linear::_backup_description "$ident" "$current")" || return "$HERDR_LINEAR_DESC_FAILED"

    herdr_linear::guard_unchanged "$ident" "$opening" || return "$HERDR_LINEAR_DESC_REFUSED"

    body="$(python3 -c '
import sys, json
q = "mutation($id:String!,$d:String!){issueUpdate(id:$id,input:{description:$d}){success}}"
print(json.dumps({"query": q, "variables": {"id": sys.argv[1], "d": sys.argv[2]}}))
' "$ident" "$next")" || return "$HERDR_LINEAR_DESC_FAILED"

    resp="$(herdr_linear::query "$body")" || return "$HERDR_LINEAR_DESC_FAILED"
    printf '%s' "$resp" | python3 -c '
import sys, json
try: ok = json.load(sys.stdin)["data"]["issueUpdate"]["success"]
except Exception: sys.exit(1)
sys.exit(0 if ok is True else 1)
' || return "$HERDR_LINEAR_DESC_FAILED"

    # Remember which commit this description describes, so a later session can
    # tell whether it has fallen behind the work without re-reading Linear.
    herdr_linear::binding_set_desc_head "$wt" "$(herdr_linear::_git "$wt" rev-parse HEAD)"

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
