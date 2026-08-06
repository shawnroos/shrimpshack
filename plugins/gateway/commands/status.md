---
description: Is the local Superagent Gateway up, which aliases is it serving, and has the plugin's context-window table drifted from the gateway's config?
argument-hint: "(no arguments; add \"start\", \"stop\" or \"restart\" to act on the gateway instead of just reporting)"
---

Report the gateway's state: running or not, the aliases it is actually serving right now, where it was resolved from, and any drift between the plugin's alias table and the gateway's own config.

Use the Skill tool to invoke: `gateway:status`

The skill owns the details: it runs `${CLAUDE_PLUGIN_ROOT}/lib/gatewayctl.sh status` and interprets the one JSON object the script prints. A down gateway is a normal answer, not an error to retry — the script says so in the same JSON.

The same script also does `start`, `stop` and `restart`. If the user asked for one of those instead of a report, the skill covers them under the same contract.

$ARGUMENTS
