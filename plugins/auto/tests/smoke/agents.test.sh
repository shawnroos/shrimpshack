#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "agents.test.sh"
"$PY" - "$AUTO_ROOT" <<'EOF'
import json, os, re, sys
root = sys.argv[1]
agents = os.path.join(root, "agents")
passed = failed = 0
def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1; print(f"  \033[32m✓\033[0m {name}")
    else:
        failed += 1; print(f"  \033[31m✗\033[0m {name}\n      {detail}")

WRITE_VERBS = ("hand-item", "answer-handed", "mark-read", "validate", "check-deliverable",
               "tracker-synced", "update-ask", "ask-shown", "ask-relayed", "log-decision")
BYPASS = ("bypassPermissions", "dangerously", "--no-verify", "permissionMode")
taken = set(os.listdir(os.path.join(root, "skills"))) | {f[:-3] for f in os.listdir(os.path.join(root, "commands")) if f.endswith(".md")}
files = sorted(f for f in os.listdir(agents) if f.endswith(".md"))
check("the plugin ships the five programme agents", len(files) == 5, files)
for f in files:
    text = open(os.path.join(agents, f)).read()
    head = text.split("---", 2)[1] if text.startswith("---") else ""
    meta = dict(re.findall(r"^(\w+):\s*(.*)$", head, re.M))
    body = text.split("---", 2)[2] if head else text
    check(f"{f}: name matches the file", meta.get("name") == f[:-3], meta.get("name"))
    check(f"{f}: model is pinned to haiku or sonnet", meta.get("model") in ("haiku", "sonnet"), meta.get("model"))
    tools = json.loads(meta.get("tools", "null") or "null")
    check(f"{f}: tools is an explicit list", isinstance(tools, list) and tools, meta.get("tools"))
    check(f"{f}: no permission-bypass flag", not any(b in text for b in BYPASS))
    runs = re.findall(r"programme\.sh\"?\s+([a-z-]+)", body)
    check(f"{f}: runs no programme write verb", not any(v in WRITE_VERBS for v in runs), runs)
    check(f"{f}: never told to pass --pin", "check-mergeable <pr> --pin" not in body and "--pin <" not in body)
    check(f"{f}: name does not shadow a skill or command", f[:-3] not in taken)
pack = open(os.path.join(agents, "programme-sweep-packager.md")).read()
meta_tools = json.loads(re.search(r"^tools:\s*(.*)$", pack, re.M).group(1))
check("sweep packager: its tools are exactly Read and Write, no shell", meta_tools == ["Read", "Write"], meta_tools)
check("sweep packager: names no programme.sh command, it reads a saved file", "programme.sh" not in pack)
check("sweep packager: reads <home>/sweep-inputs.json", "`<home>/sweep-inputs.json`" in pack or "<home>/sweep-inputs.json" in pack)
check("sweep packager: writes the digest with the Write tool to <home>/sweep-digest.md and ends it with DIGEST-DONE", "with the Write tool" in pack and "<home>/sweep-digest.md" in pack and "DIGEST-DONE" in pack)
check("sweep packager: copies the verdict and may not turn changed into unchanged", "copy them" in pack and "You may not turn `changed` into `unchanged`" in pack)
check("sweep packager: an unreadable input is unknown", "An empty or failed read is unknown" in pack)
check("sweep packager: states the 6,000 character limit", "6,000 characters" in pack)
upd = open(os.path.join(agents, "programme-tracker-updater.md")).read()
check("tracker updater: writes only the listed issues", "Write only to the issues listed" in upd)
check("tracker updater: never writes a done or canceled state", "Never set a state whose type is completed or canceled" in upd)
check("tracker updater: never writes a root-cause comment", "root cause" in upd and "Never post a comment" in upd)
print(f"agents.test.sh: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
EOF
