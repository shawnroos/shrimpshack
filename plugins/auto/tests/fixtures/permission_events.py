"""Fixture builders for permission events, shaped after tests/fixtures/permission_observed.md.

CLI:
  session <sid> <transcript_path> <cwd>                      SessionStart payload
  denied <sid> <tool_use_id> <command> <reason>              PermissionDenied payload
  ran <event> <sid> <tool_use_id> <command>                  PostToolUse / PostToolUseFailure payload
  transcript <path> <sid> <tool_use_id> <command> <decision> <shape>
  settings <path> <json>
  snapshot <path> <pane=sid=status>...
  untyped-prompt <sid> <transcript_path> <text>              UserPromptSubmit payload, no human source row
"""

import json
import os
import sys
import uuid

# The four observed result rows: (reasonType, toolDenialKind, is_error).
SHAPES = {
    "red": ("subcommandResults", None, True),
    "classifier": ("classifier", None, False),
    "mode": ("mode", "permission-rule", True),
    "deny_rule": ("subcommandResults", "permission-rule", True),
}
REFUSAL = "Permission to use Bash has been denied because Claude Code is running in don't ask mode."


def session_start(sid, transcript_path, cwd):
    return {"session_id": sid, "source": "startup", "cwd": cwd, "transcript_path": transcript_path,
            "hook_event_name": "SessionStart"}


def _common(event, sid, tool_use_id, command):
    # The payload's own transcript_path is forged on purpose: the hook must use the registry's.
    return {"session_id": sid, "transcript_path": "/forged/by/payload.jsonl", "cwd": "/srv/elsewhere",
            "prompt_id": str(uuid.uuid4()), "permission_mode": "auto", "effort": "medium",
            "hook_event_name": event, "tool_name": "Bash",
            "tool_input": {"command": command, "description": "fixture"}, "tool_use_id": tool_use_id}


def denied(sid, tool_use_id, command, reason):
    return dict(_common("PermissionDenied", sid, tool_use_id, command), reason=reason)


def ran(event, sid, tool_use_id, command):
    payload = dict(_common(event, sid, tool_use_id, command), duration_ms=41)
    if event == "PostToolUseFailure":
        payload.update(error="Exit code 8\nOUTPUT-SECRET-1 pending checks", is_interrupt=False)
    else:
        payload["tool_response"] = {"stdout": "OUTPUT-SECRET-2", "stderr": ""}
    return payload


def transcript_rows(sid, tool_use_id, command, decision, shape):
    reason_type, kind, is_error = SHAPES[shape]
    assistant = {"type": "assistant", "sessionId": sid, "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": tool_use_id, "name": "Bash", "input": {"command": command}}]}}
    user = {"type": "user", "sessionId": sid,
            "permissionDecision": {"decision": decision, "source": "config", "reasonType": reason_type},
            "toolDenialKind": kind if decision == "reject" else None,
            "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": tool_use_id, "is_error": is_error,
                 "content": REFUSAL if decision == "reject" else "exit 8"}]}}
    return [assistant, user]


def append_transcript(path, sid, tool_use_id, command, decision, shape):
    with open(path, "a") as fh:
        for row in transcript_rows(sid, tool_use_id, command, decision, shape):
            fh.write(json.dumps(row) + "\n")


def write_settings(path, doc):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(doc, fh)


def write_snapshot(path, specs):
    panes = []
    for spec in specs:
        pane, sid, status = spec.split("=")
        panes.append({"pane_id": pane, "tab_id": "w2:t1", "workspace_id": pane.split(":")[0],
                      "terminal_id": "term_" + pane.split(":")[1], "agent": "claude", "agent_status": status,
                      "cwd": "/tmp", "label": None, "terminal_title_stripped": None,
                      "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sid}})
    doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
        "workspaces": [{"workspace_id": "w2", "label": "fixture"}],
        "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
        "panes": panes, "agents": panes}}}
    with open(path, "w") as fh:
        json.dump(doc, fh)


def untyped_prompt(sid, transcript_path, text):
    return {"session_id": sid, "prompt": text, "prompt_id": str(uuid.uuid4()),
            "transcript_path": transcript_path, "hook_event_name": "UserPromptSubmit"}


def main(argv):
    verb, args = argv[0], argv[1:]
    if verb == "session":
        print(json.dumps(session_start(*args)))
    elif verb == "denied":
        print(json.dumps(denied(*args)))
    elif verb == "ran":
        print(json.dumps(ran(*args)))
    elif verb == "transcript":
        append_transcript(*args)
    elif verb == "settings":
        write_settings(args[0], json.loads(args[1]))
    elif verb == "snapshot":
        write_snapshot(args[0], args[1:])
    elif verb == "untyped-prompt":
        print(json.dumps(untyped_prompt(*args)))
    else:
        raise SystemExit(f"unknown fixture verb {verb!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
