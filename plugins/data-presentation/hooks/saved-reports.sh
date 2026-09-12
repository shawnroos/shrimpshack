#!/usr/bin/env bash
# SessionStart: name the saved reports so a plain request reaches the report skill.
#
# Fails open: every path exits 0, because a listing that can stop a session from
# starting is worse than no listing. Only file names matching the template name
# pattern are printed, so a stray file in the folder cannot put text into every
# session's context.

TEMPLATES="$HOME/.claude/data-presentation/templates"
[ -d "$TEMPLATES" ] || exit 0

python3 - "$TEMPLATES" <<'PY' 2>/dev/null
import json, os, re, sys

names = sorted(
    f[:-5] for f in os.listdir(sys.argv[1])
    if f.endswith(".json") and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,23}", f[:-5])
)
if names:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "Saved data reports: " + ", ".join(names)
        + ". When the person asks for one of these, use the data-presentation report skill.",
    }}))
PY
exit 0
