#!/usr/bin/env bash
# claude-modes V2: mode YAML parser and cascade-tier resolver.
#
# Responsibilities:
#   - Resolve <name> → mode YAML file (global ~/.claude/modes/<name>.yaml)
#   - Parse the YAML safely (yaml.safe_load — never bare yaml.load(),
#     which would execute Python tags as code)
#   - Validate schema_version (must equal 2 in V2; clear error otherwise)
#   - Provide getter functions for:
#     - Mechanism layer: enabledPlugins (cascade payload — V2.0 scope),
#       disable.enabledPlugins (subtract), user_catalog manifest
#     - Prose layer: name, description, philosophy, scope, lens,
#       constraints, command_heuristics (for R25 UserPromptSubmit injection)
#
# V2 vs V1 changes:
#   - schema_version: 2 (was 1)
#   - delegation.{agents,skills}.{mount,unmount} REMOVED (V1 mechanism)
#   - mechanism.enabledPlugins + mechanism.user_catalog ADDED
#   - mechanism.{env,permissions,mcpServers,hooks} NOT in V2.0 cascade
#     payload per binary verification 2026-05-18 — getters still exist
#     so future V2.0.1+ can use them, but the cascade engine ignores them
#   - disable block ADDED for subtractive merge semantics
#
# WHY /usr/bin/python3 (not bare `python3`):
#   On macOS the user's PATH often resolves `python3` to a Homebrew
#   install that does NOT include the `yaml` module. /usr/bin/python3
#   (Apple-shipped) carries PyYAML 6.0.2+ by default. Pinning to it makes
#   the plugin robust against PATH ordering and Python proliferation.

set -uo pipefail

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# Internal: run a python expression against a YAML file using safe_load.
# Echoes the result; non-zero exit on error.
#
# Security contract: the py_expr body must NEVER shell-interpolate
# user-controlled strings into Python source. Instead, reference values
# via sys.argv inside the body. The caller passes the values as extra
# bash arguments; this function forwards them as Python argv. Closes the
# Python-injection class of bugs (V1 sec-001 pattern).
__claude_modes::py_yaml_query() {
  local yaml_file="$1"
  local py_expr="$2"
  shift 2

  "$CLAUDE_MODES_PYTHON3" - "$yaml_file" "$@" <<PYEOF
import sys, yaml
path = sys.argv[1]
# argv[2..] are caller-supplied untrusted strings — Python receives them
# as bytes via argv, NOT via source interpolation. Reference them as
# sys.argv[N] inside py_expr.
try:
    with open(path) as f:
        data = yaml.safe_load(f) or {}
except FileNotFoundError:
    sys.stderr.write(f"mode-yaml: file not found: {path}\n")
    sys.exit(2)
except yaml.YAMLError as e:
    sys.stderr.write(f"mode-yaml: parse error in {path}: {e}\n")
    sys.exit(3)
${py_expr}
PYEOF
}

# claude_modes::resolve_mode_file <name>
#
# Resolves <name> to a global mode YAML at ~/.claude/modes/<name>.yaml.
# Returns the resolved path on stdout, exits 0 on success.
# Returns nothing + exits 1 if the file doesn't exist.
#
# V2 simplification vs V1: no per-repo override resolution here.
# Repo-tier customization happens via tier-4 _repo.yaml in the cascade
# engine, not via mode-file shadowing. tier-5 override.yaml is V2.1.
claude_modes::resolve_mode_file() {
  local name="$1"
  local global_path="${HOME}/.claude/modes/${name}.yaml"

  if [ -f "$global_path" ]; then
    printf '%s' "$global_path"
    return 0
  fi

  echo "mode-yaml: mode '${name}' not found at ${global_path}" >&2
  return 1
}

# claude_modes::validate_schema_version <yaml_file>
#
# Reads schema_version from the YAML; ensures it equals 2 (V2's only
# supported version). Errors visibly on mismatch.
claude_modes::validate_schema_version() {
  local yaml_file="$1"
  local version
  version=$(__claude_modes::py_yaml_query "$yaml_file" '
v = data.get("schema_version")
if v is None:
    sys.stderr.write(f"mode-yaml: missing schema_version in {path} (V2 requires schema_version: 2)\n")
    sys.exit(4)
print(v)
') || return $?

  if [ "$version" != "2" ]; then
    if [ "$version" = "1" ]; then
      echo "mode-yaml: ${yaml_file} declares schema_version=1 (V1 mode) — V2 plugin does not migrate V1 YAMLs. See ~/.claude/modes/.v1-archive/ for archived files; re-author in V2 with /mode:registry." >&2
    else
      echo "mode-yaml: ${yaml_file} declares schema_version=${version}, but this plugin only knows schema_version=2 — upgrade the plugin or use an older mode file" >&2
    fi
    return 5
  fi
  return 0
}

# claude_modes::get_field <yaml_file> <field>
#
# Returns the value of a top-level scalar field (name, description,
# philosophy, scope, lens). Empty + exit 0 if missing.
claude_modes::get_field() {
  local yaml_file="$1"
  local field="$2"
  __claude_modes::py_yaml_query "$yaml_file" '
field = sys.argv[2]
v = data.get(field)
if v is not None:
    print(v)
' "$field"
}

# claude_modes::get_constraints <yaml_file>
#
# Returns the constraints list, one per line. Empty if absent.
claude_modes::get_constraints() {
  local yaml_file="$1"
  __claude_modes::py_yaml_query "$yaml_file" "
for c in (data.get('constraints') or []):
    print(c)
"
}

# claude_modes::get_enabled_plugins <yaml_file>
#
# Returns each enabledPlugins entry as a line: "<name>@<marketplace>=<true|false>".
# Used by U4 cascade engine to merge plugin sets across tiers.
# Empty if mechanism.enabledPlugins is absent.
claude_modes::get_enabled_plugins() {
  local yaml_file="$1"
  __claude_modes::py_yaml_query "$yaml_file" "
mech = data.get('mechanism') or {}
ep = mech.get('enabledPlugins') or {}
for key, val in ep.items():
    print(f'{key}={str(val).lower()}')
"
}

# claude_modes::get_disabled_plugins <yaml_file>
#
# Returns each disable.enabledPlugins entry as a line: "<name>@<marketplace>".
# Used by U4 cascade engine to subtract from the cascade-merged plugin set.
# Empty if disable.enabledPlugins is absent.
claude_modes::get_disabled_plugins() {
  local yaml_file="$1"
  __claude_modes::py_yaml_query "$yaml_file" "
dis = data.get('disable') or {}
ep = dis.get('enabledPlugins') or []
for entry in ep:
    print(entry)
"
}

# claude_modes::get_user_catalog <yaml_file> <commands|agents>
#
# Returns the list of user-catalog manifest entries for this category.
# Empty if user_catalog.<category> is absent.
# Used by U8 symlink-rebuild to determine which user-authored files
# are visible in this mode.
claude_modes::get_user_catalog() {
  local yaml_file="$1"
  local category="$2"  # commands|agents
  __claude_modes::py_yaml_query "$yaml_file" '
category = sys.argv[2]
mech = data.get("mechanism") or {}
uc = mech.get("user_catalog") or {}
entries = uc.get(category) or []
for entry in entries:
    print(entry)
' "$category"
}

# claude_modes::get_heuristic <yaml_file> <command> <field>
#
# Returns the value of command_heuristics[command][field], where field is
# one of focus/bar/behavior/scope (carried from V1; extensible). Empty +
# exit 0 if absent. Used by R25 prose injection.
#
# NOTE: V2 uses underscore `command_heuristics` (Python-friendly key);
# V1 used hyphen `command-heuristics`. Examples use the V2 form.
claude_modes::get_heuristic() {
  local yaml_file="$1"
  local command="$2"
  local field="$3"
  __claude_modes::py_yaml_query "$yaml_file" '
command = sys.argv[2]
field = sys.argv[3]
# Accept both V2 (command_heuristics) and V1-style (command-heuristics)
# during transition period for forward-compat with existing user YAMLs.
ch = (data.get("command_heuristics") or data.get("command-heuristics") or {})
h = ch.get(command) or {}
v = h.get(field)
if v is not None:
    print(v)
' "$command" "$field"
}

# claude_modes::has_heuristic <yaml_file> <command>
#
# Exit 0 if the mode has an authored heuristic for this command,
# non-zero otherwise.
claude_modes::has_heuristic() {
  local yaml_file="$1"
  local command="$2"
  __claude_modes::py_yaml_query "$yaml_file" '
command = sys.argv[2]
ch = (data.get("command_heuristics") or data.get("command-heuristics") or {})
sys.exit(0 if command in ch else 1)
' "$command"
}

# claude_modes::list_command_heuristics <yaml_file>
#
# Emits the list of slash commands that have authored bindings in this
# mode, one per line. Used by /mode:status.
claude_modes::list_command_heuristics() {
  local yaml_file="$1"
  __claude_modes::py_yaml_query "$yaml_file" "
ch = (data.get('command_heuristics') or data.get('command-heuristics') or {})
for cmd in ch.keys():
    print(cmd)
"
}

# claude_modes::sha256_of_file <path>
#
# Returns the SHA-256 hash of the file's contents. Used by:
#   - .cascade-meta.json fingerprint for uninstall deletion gate
#   - .trusted-repos.txt content-hash check for tier-4 trust gate
claude_modes::sha256_of_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 1
  fi
  # Use Python rather than shelling to shasum so we're consistent with
  # the rest of the cascade engine. macOS has both shasum and openssl;
  # Python's hashlib is universal.
  "$CLAUDE_MODES_PYTHON3" -c "
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
" "$path"
}

# Allow execution as a script for debugging:
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    resolve)            claude_modes::resolve_mode_file "${2:-}" ;;
    validate)           claude_modes::validate_schema_version "${2:-}" ;;
    field)              claude_modes::get_field "${2:-}" "${3:-}" ;;
    constraints)        claude_modes::get_constraints "${2:-}" ;;
    enabled-plugins)    claude_modes::get_enabled_plugins "${2:-}" ;;
    disabled-plugins)   claude_modes::get_disabled_plugins "${2:-}" ;;
    user-catalog)       claude_modes::get_user_catalog "${2:-}" "${3:-}" ;;
    heuristic)          claude_modes::get_heuristic "${2:-}" "${3:-}" "${4:-}" ;;
    has-heuristic)      claude_modes::has_heuristic "${2:-}" "${3:-}" ;;
    list-heuristics)    claude_modes::list_command_heuristics "${2:-}" ;;
    sha256)             claude_modes::sha256_of_file "${2:-}" ;;
    *)
      cat >&2 <<USAGE
Usage: $0 <subcommand> [args]
Subcommands:
  resolve <name>                    — resolve mode name to YAML path
  validate <path>                   — verify schema_version: 2
  field <path> <field>              — get top-level scalar
  constraints <path>                — list constraints
  enabled-plugins <path>            — list mechanism.enabledPlugins entries
  disabled-plugins <path>           — list disable.enabledPlugins entries
  user-catalog <path> <category>    — list mechanism.user_catalog.<category>
  heuristic <path> <cmd> <field>    — get command_heuristics[cmd][field]
  has-heuristic <path> <cmd>        — exit 0 if cmd has heuristic
  list-heuristics <path>            — list commands with heuristics
  sha256 <path>                     — hash a file (for fingerprinting)
USAGE
      exit 2
      ;;
  esac
fi
