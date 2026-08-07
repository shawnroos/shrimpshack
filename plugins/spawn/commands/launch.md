---
description: Materialize a Claude Code session on a gateway alias, seeded with an opening prompt, and print a resume handle you can attach with whenever you like.
argument-hint: "<alias> [the opening prompt] [--cwd <dir>] — alias must be one the gateway serves (see /spawn:status)"
---

Start a session on a different model and hand back the handle. Nothing opens a terminal; the first turn runs headlessly, the session lands on disk, and you get a paste-ready attach command.

Use the Skill tool to invoke: `spawn:launch`

The skill owns the details: it runs `${CLAUDE_PLUGIN_ROOT}/lib/launch.sh`, feeds the seed prompt in on stdin, and reads the one JSON handle the script prints.

Present the handle plainly — the attach command, the session id, the transcript path — and say what a gateway-pointed session does not have, so the attached session reads as expected rather than broken. The skill lists those.

$ARGUMENTS
