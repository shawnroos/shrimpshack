#!/usr/bin/env bash
# claude-modes V2 U12: /mode:registry — list globally-defined modes.
#
# Lists every <name>.yaml at ~/.claude/modes/ (excluding the framework
# files _global.yaml and _repo.yaml — those are tier-2/tier-4 baselines,
# not modes).
#
# For each mode prints:
#   - name (filename without .yaml)
#   - schema_version (if parseable)
#   - description (first non-blank line, truncated)
#   - enabledPlugins count
#   - user_catalog count (commands + agents)
#   - prose layer presence (philosophy/scope/lens/constraints any present)
#
# Flags:
#   --new    Surface a pointer at the mode-author skill (conversational,
#            so this just prints instructions — no automatic Skill tool
#            invocation from a shell script).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/mode-yaml.sh"

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# Extract a one-line summary description for display.
# Strategy: read top-level `description`, take first non-blank line,
# truncate to ~80 chars. Empty if absent.
__claude_modes::registry_short_description() {
  local yaml_file="$1"
  "$CLAUDE_MODES_PYTHON3" - "$yaml_file" <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
desc = data.get("description") or ""
if not isinstance(desc, str):
    sys.exit(0)
for line in desc.splitlines():
    line = line.strip()
    if line:
        if len(line) > 80:
            line = line[:77] + "..."
        print(line)
        break
PYEOF
}

# Returns the integer count of mechanism.enabledPlugins entries.
__claude_modes::registry_plugin_count() {
  local yaml_file="$1"
  "$CLAUDE_MODES_PYTHON3" - "$yaml_file" <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    print(0); sys.exit(0)
mech = data.get("mechanism") or {}
ep = mech.get("enabledPlugins") or {}
print(len(ep) if isinstance(ep, dict) else 0)
PYEOF
}

# Returns the integer count of user_catalog.commands + user_catalog.agents.
__claude_modes::registry_user_catalog_count() {
  local yaml_file="$1"
  "$CLAUDE_MODES_PYTHON3" - "$yaml_file" <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    print(0); sys.exit(0)
mech = data.get("mechanism") or {}
uc = mech.get("user_catalog") or {}
total = 0
for cat in ("commands", "agents"):
    entries = uc.get(cat) or []
    if isinstance(entries, list):
        total += len(entries)
print(total)
PYEOF
}

# "yes" if any prose-layer field is non-empty, else "no".
__claude_modes::registry_has_prose() {
  local yaml_file="$1"
  "$CLAUDE_MODES_PYTHON3" - "$yaml_file" <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    print("no"); sys.exit(0)
for field in ("philosophy", "scope", "lens", "constraints"):
    v = data.get(field)
    if v:
        print("yes"); sys.exit(0)
print("no")
PYEOF
}

# Reads schema_version (best-effort). Prints "?" if unparseable.
__claude_modes::registry_schema_version() {
  local yaml_file="$1"
  "$CLAUDE_MODES_PYTHON3" - "$yaml_file" <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    print("?"); sys.exit(0)
v = data.get("schema_version")
print(v if v is not None else "?")
PYEOF
}

__claude_modes::registry_new_pointer() {
  cat <<'EOF'
Authoring a new mode is a conversational flow handled by the
mode-author skill. To start:

  1. Activate the mode-author skill via the Skill tool (or, if you
     are reading this in a chat, say "use the mode-author skill"
     and the assistant will load it).
  2. The skill walks you through intent capture, definition
     synthesis, cascade-awareness, mechanism population, and an
     atomic write via lib/write-mode-yaml.sh.
  3. After the YAML lands, run /mode:set <name> to activate it on
     the current branch.

Skill location:
  .claude/skills/mode-author/SKILL.md (relative to plugin root)

If you want to author by hand instead, drop a YAML at
~/.claude/modes/<name>.yaml. Use the example files in this plugin's
examples/ dir as a starting point — example-discovery.yaml and
example-delivery.yaml are working references.
EOF
}

# claude_modes::registry [--new]
claude_modes::registry() {
  local arg="${1:-}"

  local modes_dir="${HOME}/.claude/modes"

  echo "claude-modes /mode:registry"
  echo "==========================="
  echo ""
  echo "Modes directory: ${modes_dir}"
  echo ""

  if [ ! -d "$modes_dir" ]; then
    echo "No modes directory exists yet — run /mode:setup to bootstrap."
    if [ "$arg" = "--new" ]; then
      echo ""
      __claude_modes::registry_new_pointer
    fi
    return 0
  fi

  # Collect mode YAMLs (exclude framework files _global.yaml/_repo.yaml).
  local yamls=()
  local f basename
  while IFS= read -r -d '' f; do
    basename=$(basename "$f")
    case "$basename" in
      _global.yaml|_repo.yaml) continue ;;
      *) yamls+=("$f") ;;
    esac
  done < <(find "$modes_dir" -maxdepth 1 -type f -name '*.yaml' -print0 2>/dev/null | sort -z)

  if [ "${#yamls[@]}" -eq 0 ]; then
    echo "No modes defined."
    echo ""
    echo "Modes live at ~/.claude/modes/<name>.yaml. Author one via the"
    echo "mode-author skill, or run /mode:registry --new for instructions."
  else
    echo "Modes (${#yamls[@]}):"
    echo ""
    for f in "${yamls[@]}"; do
      basename=$(basename "$f")
      local name="${basename%.yaml}"
      local sv desc pc uc prose
      sv=$(__claude_modes::registry_schema_version "$f")
      desc=$(__claude_modes::registry_short_description "$f")
      pc=$(__claude_modes::registry_plugin_count "$f")
      uc=$(__claude_modes::registry_user_catalog_count "$f")
      prose=$(__claude_modes::registry_has_prose "$f")

      echo "  - ${name}"
      echo "      path:            $f"
      echo "      schema_version:  ${sv}"
      if [ -n "$desc" ]; then
        echo "      description:     ${desc}"
      else
        echo "      description:     (none)"
      fi
      echo "      enabledPlugins:  ${pc}"
      echo "      user_catalog:    ${uc}  (commands+agents combined)"
      echo "      prose layer:     ${prose}"
      echo ""
    done
  fi

  if [ "$arg" = "--new" ]; then
    __claude_modes::registry_new_pointer
  fi

  return 0
}

# Allow direct invocation:
#   bash lib/registry.sh [--new]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  claude_modes::registry "${1:-}"
fi
