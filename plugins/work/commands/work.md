---
description: Report what this session is bound to on the board, and whether the board can hear this session's Linear writes. With an issue identifier, start work on it instead.
argument-hint: "[WEB-1234] | [setup] | [status] | nothing"
allowed-tools: Bash, Skill, AskUserQuestion, mcp__board__open_board, mcp__board__close_board, mcp__board__bind, mcp__board__state, mcp__claude_ai_Linear__get_issue, mcp__linear__get_issue
---

What this session is bound to, and whether the board is listening.

## With no argument

Run both parts and report what they print. Read the state, do not guess it.

### 1. The binding

```bash
R="${CLAUDE_PLUGIN_ROOT}"
source "$R/lib/sanitize.sh"

if [ -z "${HERDR_WORKSPACE_ID:-}" ]; then
    echo "outside herdr"
elif ! command -v board >/dev/null 2>&1; then
    echo "binding unknown: board is not installed"
else
    board linear session --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("binding unknown: board linear session did not answer"); sys.exit()
b = d.get("binding") or {}
if d.get("space_bound") is False:
    print("space not bound to a project (bind it in the board)"); sys.exit()
if not b.get("issue"):
    print("unbound"); sys.exit()
print("issue:  " + str(b["issue"]))
print("column: " + str(d.get("column") or "none"))
for m in d.get("marks") or []:
    print(("mark:   " + str(m.get("kind") or "") + " " + str(m.get("text") or "")).rstrip())
' | herdr_linear::sanitize_stream
fi
```

Say it in one line:

| Output | Say |
|---|---|
| `outside herdr` | this session is not in a herdr pane, so it has no board binding |
| `space not bound to a project` … | this herdr workspace is not bound to a project on the board. Bind it in the board first |
| `unbound` | this worktree is not bound. `/work:start WEB-1234` starts bound work |
| `issue:` … | name the issue and its column, and list any marks |
| `binding unknown:` … | say why, then rely on the health lines below |

### 2. Health

Each check is fast and none starts the daemon. A check that passes prints
nothing.

```bash
{
if ! command -v board >/dev/null 2>&1; then
    echo "board is not installed. Install board, then run /work again."
else
    board linear report --help >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 64 ]; then
        echo "board is too old to receive Linear writes. Upgrade board."
    elif [ "$rc" -ne 0 ]; then
        echo "board linear report --help exited $rc. Upgrade board."
    fi

    board version --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("board version --json did not answer. Reinstall board."); sys.exit()
cli, daemon = d.get("cli_version"), d.get("daemon_version")
if not daemon:
    print("the board daemon is not answering. Run: board daemon start")
elif daemon != cli:
    print("the board daemon runs " + daemon + " and the CLI is " + str(cli) + ". Run: board daemon stop")
'
fi

claude mcp list 2>/dev/null | grep -qE '^board:' \
    || echo "board mcp is not registered. Run: claude mcp add --scope user board -- board mcp"

for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
         "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json" \
         "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.local.json"; do
    if grep -q 'board linear report' "$f" 2>/dev/null; then
        echo "$f has its own board linear report hook, so every write is reported twice. Remove that hook; the plugin already runs one."
    fi
done
} | awk '{ print } END { if (NR) print "Run /work setup to fix these." }'
```

Pass every line on as printed. When nothing prints, say the board hears this
session's Linear writes.

## With an issue identifier

`/work WEB-3308` means *start on this*. Read
`${CLAUDE_PLUGIN_ROOT}/skills/start/SKILL.md` and follow it with the
identifier as its argument. Do not invoke `/work:start` as a skill: only the
user can invoke it. That flow creates the worktree at a path derived from the
ticket and binds it on the board — or, when more than one repository or none is recorded for the ticket's
project, asks which repository to use and creates nothing until that is
answered.

## With `setup`

`/work setup` walks the person through everything the plugin needs: the board,
its daemon, the board tools, the Linear key, and the first space and worktree
bindings. Read `${CLAUDE_PLUGIN_ROOT}/skills/setup/SKILL.md` and follow it. Do
not invoke it as a skill: only the user can invoke it. It shows each fix and
runs one only after the person says yes, and it is safe to run again.

## With `status`

The same report, plus the credential:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/migrate-credential.sh" report
```

## The rest

| Command | For |
|---|---|
| `/work:start` | begin work, from a ticket or from nothing |
| `/work:layout` | give each sub-issue of a bound parent a worktree and a column |

Linear tickets are created and changed through Linear's own MCP tools. The
board hears about each change through the plugin's hook.

**Never invent state.** If a check fails or the board does not answer, say so.
A confident wrong answer about what a session is bound to is worse than "I
could not read it".
