#!/bin/bash
# tool-gate.sh — the outer wall. A PreToolUse hook that DEFAULT-DENIES.
#
# WHY THIS EXISTS, AND WHY IT IS NOT THE DENY LIST
# ------------------------------------------------
# A `permissions.deny` list is an ENUMERATION: every tool the harness adds in
# future is permitted until someone writes its name down. This hook inverts
# that. It holds an ALLOW SET and refuses everything else, so a tool that did
# not exist when this file was written is refused because it was never named.
#
# MEASURED 2026-08-14, by observed effect (a marker file only the tool could
# create), against a real headless `claude -p`:
#
#   | question                                             | measured |
#   | ---------------------------------------------------- | -------- |
#   | do hook definitions load from `--settings`?           | YES      |
#   | does exit 2 block a tool that `permissions.allow`     | YES      |
#   |   explicitly permits?                                 |          |
#   | does it survive `--permission-mode bypassPermissions`?| YES      |
#   | does the refusal land in `permission_denials[]`?      | YES      |
#   | can the hook see `tool_name`?                         | YES      |
#
# The control arm — identical settings with the hook removed — RAN the command
# and created the marker. So the block is this hook and nothing else.
#
# The third row is the one that matters most. The `--settings` ceiling is real
# enforcement (also measured), but a bypass flag defeats it; this hook holds
# even then. It is the only mechanism measured that does. Documented upstream:
# "a hook that exits with code 2 stops the tool call BEFORE permission rules are
# evaluated" — so it beats an allow rule rather than merely adding to a deny.
#
# FAIL CLOSED, EVERY PATH
# -----------------------
# Every error here exits 2 (block). A gate that fails open is not a gate: a
# missing python3, an unreadable allow file, a malformed payload and an empty
# tool name all mean "we do not know what this call is", and the answer to that
# is no. This is the inverse of the usual shell habit of falling through, and it
# is deliberate — see `false_green_traps` in this repo's recorded lessons.
#
# THE JOB CANNOT EDIT ITS OWN BOUND
# ---------------------------------
# This is the live escape class in the field: agents that stay inside the box and
# write a config a trusted process later loads (Cursor, Codex, Gemini CLI and
# Antigravity were all escaped this way in 2026).
#
# THE ALLOW SET IS ARGV, NOT A FILE, AND THAT IS THE WHOLE POINT. The job's
# scratch dir is `<worktree>/.spawn` — INSIDE the tree the ceiling lets it write
# to, kept safe only by `Write(//**/.spawn/**)` deny rules. Those rules are the
# INNER layer, and a permission-bypass flag defeats them. A policy FILE would be
# re-read on every single tool call, so a job running under a bypass flag could
# rewrite its own allow set mid-run and hand itself Bash on the next call: the
# gate would survive the flag and its policy would not.
#
# Passed as arguments, the allow set is fixed in this process's argv when the
# child starts, so the SET cannot be poisoned by a later write. The bound is
# decided by the launch, which is the same principle as `ceiling_selectable`.
#
# WHAT THIS GATE DOES NOT HOLD: A JOB GRANTED Bash
# ------------------------------------------------
# RETRACTED 2026-08-25. Until this commit the header asserted two things: that
# the plugin tree holding this script is somewhere the ceiling forbids a job to
# write, and that consequently no file here can be rewritten. Both were true
# when only Write and Edit could reach a path — those are TOOL-scoped and carry
# path rules. Neither is true of a shell.
#
# `--allow Bash` is a caller-supplied grant (see spawn::ceiling_grantable). A
# job holding it writes wherever the invoking OS user can, and that includes
# THIS FILE. Argv protects the allow set; nothing protects the script.
#
# NOT ESTABLISHED, ACROSS TWO ROUTES. An arm in tests/unit/ceilings.bats grants a
# child Bash and tells it to overwrite a COPY of this file with `exit 0`. On the
# default-model route the shell demonstrably worked and the copy was still not
# rewritten; on the cheap gateway alias the model never used the shell at all, so
# that run tested nothing and the arm says so.
#
# Do not read either as protection. The copy was writable by the same OS user;
# nothing stopped the rewrite. Model reluctance is not a bound, and a quiet model
# is not a boundary. Whether rewriting this file actually yields the tools it gates
# is STILL unmeasured on two counts: the harness must re-read the hook
# registration mid-session, and `permissions.deny` — a separate layer — must
# stop refusing them. Treat this file as unprotected against a granted shell.
#
# THE BLAST RADIUS IS NOT PER-JOB. This is ONE file, named by absolute path from
# every rendered ceiling on the machine. A single granted job that rewrites it
# removes this wall for every LATER job, including jobs whose caller granted
# nothing. The default-deny property holds for an untampered install and only
# for one. An integrity check would live in the same writable tree, so there is
# nothing to add here but the warning.
#
# Usage (from the rendered ceiling's hooks block):
#   tool-gate.sh <ToolName> [ToolName...]

set -u

# Refuse and say why. stderr reaches the model, so it can report the block
# rather than silently retrying a different route to the same effect.
block() {
    printf 'spawn ceiling: %s\n' "$1" >&2
    exit 2
}

# An empty allow set is a misconfiguration, not "permit nothing quietly" — but it
# still fails CLOSED, because the alternative is a gate that evaporates when a
# caller forgets an argument.
[ "$#" -gt 0 ] || block "tool gate misconfigured (empty allow set); refusing"

PAYLOAD="$(cat)" || block "tool gate could not read the hook payload; refusing"

# The payload is JSON on stdin carrying tool_name, tool_input, permission_mode
# and cwd. Only tool_name is consulted: matching on tool_input would be
# pattern-matching command text, and this repo has three upstream CVEs' worth of
# evidence that shell syntax beats string filters (line continuation, compound
# operators, heredoc smuggling). The tool NAME is a closed set; its arguments
# are not.
TOOL="$(printf '%s' "$PAYLOAD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
name = d.get("tool_name")
if not isinstance(name, str) or not name:
    sys.exit(1)
sys.stdout.write(name)
' 2>/dev/null)" || block "tool gate could not parse the hook payload; refusing"

[ -n "$TOOL" ] || block "tool gate saw no tool name; refusing"

# Compare literally with `=`. NOT a `case` pattern: a stray `*` among the
# arguments would then permit everything — precisely the failure this gate exists
# to prevent, and cheap to get wrong.
for allowed in "$@"; do
    if [ "$allowed" = "$TOOL" ]; then
        exit 0
    fi
done

block "'$TOOL' is not in this job's allow set"
