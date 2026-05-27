#!/usr/bin/env bash
# claude-modes (0.3.0 / U2): catalog candidate resolver — SHARED PRIMITIVE.
#
# Resolves a user-supplied identifier ("figma", "ce-correctness-reviewer",
# "rams") to one or more fully-qualified plugin/skill records by searching
# three sources, in order. The public function and its TSV output contract
# are a STABLE INTERFACE: mode-author, mode-suggester, the mode agent, and
# all /mode:* slash commands consume this, so treat shape changes as breaking.
#
# Public API:
#   claude_modes::resolve_candidate <query>
#     → prints N records to stdout, one per line, TSV:
#         kind=<plugin|skill|agent>\tid=<fqn>\tsource=<cache|installed|marketplace>\tinstalled=<Y|N>
#     → empty result → exit 0 with NO stdout (caller decides the error message)
#     → returns 0 always (the absence of matches is not an error)
#
# FQN (id=) shapes — PINNED so U3/U5 inherit a stable contract:
#   - skill   (source=cache):       <plugin>:<skill_name>      e.g. iloom-lite:planner
#   - plugin  (source=installed):   <plugin>@<marketplace>     e.g. figma@every-marketplace
#   - plugin  (source=marketplace): <plugin>@<marketplace>     (marketplace = the
#                                   marketplace.json top-level `name`, NOT the dir)
#
# SKILL ROW PARENT-PLUGIN FIELD (U2 / Batch-4 fix):
#   A plugin-shipped skill is enabled by enabling its PARENT PLUGIN, never by
#   appending the colon-FQN to user_catalog.agents (that resolves user-authored
#   BASENAMES staged under ~/.claude/modes/.user-catalog/; a plugin skill is
#   never staged there, so a colon-FQN would be a dangling, never-enabling
#   reference). So every `kind=skill source=cache` row carries an EXTRA field:
#       parent_plugin=<plugin>@<marketplace>
#   resolved by cross-referencing installed_plugins.json for which marketplace
#   the skill's plugin is installed from. If the plugin is NOT in the registry
#   (not installed), the field is emitted EMPTY (`parent_plugin=`) and the
#   orchestrator refuses with "install the plugin first". This is an ADDITIVE
#   field — the kind=/id=/source=/installed= contract is unchanged.
#   - agent:  RESERVED. No source currently emits kind=agent. The enum value is
#             reserved in the TSV contract so a future unit can add an
#             agent-scanning source without a breaking change; U2 does not scan
#             agents (the plan lists exactly three sources, all plugin/skill).
#
# Search sources, IN ORDER (the order is specificity: a named skill is more
# precise than a plugin; an installed plugin is more usable than an installable
# one):
#   1. Skills cache — BOTH on-disk layouts (Phase 0 Spike A: 525 SKILL.md files
#      exist on the live cache; the single-layout glob matched only ~28):
#        ~/.claude/plugins/cache/*/*/*/.claude/skills/*/SKILL.md  (Anthropic-convention)
#        ~/.claude/plugins/cache/*/*/*/skills/*/SKILL.md          (convention; NO .claude/ infix)
#      Match by `name:` frontmatter. DEDUPLICATE across version dirs: keep the
#      highest semver per (plugin, skill_name), or newest mtime when the version
#      dir is not a semver (live caches use git-SHA version dirs — the mtime
#      fallback is load-bearing, not defensive).
#   2. ~/.claude/plugins/installed_plugins.json — LIST-of-records aware. Real
#      entries key a plugin to a LIST of install records, NOT a single dict
#      (mirrors lib/cascade-engine.sh:87-95; a dict-shaped guard silently skips
#      every real entry).
#   3. ~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json —
#      installable-but-NOT-installed entries (installed=N).
#
# Failure semantics:
#   - A source whose path EXISTS but fails to parse → a diagnostic row is
#     emitted to STDERR (NOT stdout):  source=missing\treason=<short>
#     so the caller can distinguish "tried all 3, none matched" (clean stdout)
#     from "a source was unreadable, results may be incomplete" (stderr row).
#   - A source whose path is simply ABSENT is NOT a failure (a user may have no
#     marketplaces, no installed_plugins.json on first run). It is skipped
#     silently — absence is an expected state, not an error.
#   - Multiple matches → ALL returned. The resolver never silently ranks or
#     filters; the caller disambiguates (e.g. via AskUserQuestion).
#
# SECURITY (R7 / terminal-escape class — see docs/solutions/terminal-escape-audit.md):
#   Every output field that interpolates an attacker-controllable value (plugin
#   keys, marketplace names, SKILL.md `name:` field values) is routed through
#   claude_modes::sanitize_for_display BEFORE the printf and stored in a
#   `_d`-suffixed local. A hostile plugin cache / marketplace.json could plant
#   ESC/OSC/CSI or Cf bidi bytes in any of these; the disambiguation UI prints
#   them to a human terminal. Sanitizing at the format site closes that.

# shellcheck disable=SC1091
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/sanitize.sh"

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# __claude_modes::emit_candidates_from_skills_cache <query>
#
# Source 1. Scans BOTH cache layouts for SKILL.md frontmatter whose `name:`
# equals <query>. Python does the heavy lifting (glob walk + frontmatter parse
# + semver/mtime dedup) and prints, per surviving match, a single TAB-separated
# TRIPLE:  <plugin>\t<skill_name>\t<parent_plugin_fqn>
# where parent_plugin_fqn is the "<plugin>@<marketplace>" key from
# installed_plugins.json for that plugin (empty if the plugin isn't installed).
# Bash then sanitizes each field and formats the stable TSV record (adding the
# parent_plugin= field to skill rows). On a parse failure of the WHOLE source
# (python crash), a stderr diagnostic row is emitted.
__claude_modes::emit_candidates_from_skills_cache() {
  local query="$1"
  local registry="${HOME}/.claude/plugins/installed_plugins.json"

  local raw rc
  raw=$("$CLAUDE_MODES_PYTHON3" - "$query" "$HOME" "$registry" "$SCRIPT_DIR" <<'PYEOF'
import sys, os, glob, json

query = sys.argv[1]
home = sys.argv[2]
registry_path = sys.argv[3]
sys.path.insert(0, sys.argv[4])
from registry import iter_plugin_entries, load_registry  # noqa: E402
# Transport-boundary strip (Cc+Cf) — canonical impl shared with the bash twin.
from sanitize import sanitize_for_display as _sd  # noqa: E402

if not query:
    sys.exit(0)

cache_root = os.path.join(home, ".claude", "plugins", "cache")
if not os.path.isdir(cache_root):
    # Absent cache is not an error — nothing to scan.
    sys.exit(0)


def _build_plugin_fqn_map(path):
    # Map plugin NAME -> first "<name>@<marketplace>" key from
    # installed_plugins.json, so a cached skill can name its installed parent
    # plugin's FQN. A missing/unparseable registry → empty map (the skill row's
    # parent_plugin field is then emitted empty; the orchestrator refuses with
    # "install the plugin first"). Registry shape handled by the canonical
    # lib/registry.py::iter_plugin_entries.
    out = {}
    for key, _records in iter_plugin_entries(load_registry(path)):
        name = key.split("@", 1)[0]
        # First-wins: keep the first install record's FQN for a given name.
        if name not in out:
            out[name] = key
    return out


plugin_fqn_map = _build_plugin_fqn_map(registry_path)

# BOTH layouts. The cache hierarchy is marketplace/plugin/version, hence */*/*.
patterns = [
    os.path.join(cache_root, "*", "*", "*", ".claude", "skills", "*", "SKILL.md"),
    os.path.join(cache_root, "*", "*", "*", "skills", "*", "SKILL.md"),
]


def read_name_frontmatter(path):
    # Minimal YAML-frontmatter reader: pull the top-level `name:` value from the
    # leading --- ... --- block. We avoid yaml.safe_load to keep this cheap over
    # hundreds of files and because the value is one scalar line.
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            first = fh.readline()
            if first.strip() != "---":
                return None
            for line in fh:
                stripped = line.strip()
                if stripped == "---":
                    return None  # end of frontmatter, no name
                if stripped.startswith("name:"):
                    val = stripped[len("name:"):].strip()
                    # Strip optional surrounding quotes.
                    if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                        val = val[1:-1]
                    return val
    except OSError:
        return None
    return None


def version_sort_key(version_dir, path):
    # Semver → (1, (major, minor, patch)) sorts ABOVE non-semver → (0, mtime).
    # Descending sort then prefers a real semver; among non-semvers, newest mtime.
    parts = version_dir.split(".")
    if len(parts) == 3 and all(p.isdigit() for p in parts):
        return (1, (int(parts[0]), int(parts[1]), int(parts[2])), 0.0)
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        mtime = 0.0
    return (0, (0, 0, 0), mtime)


# Dedup key: (plugin, skill_name). Value: (sort_key, plugin, skill_name).
best = {}
for pattern in patterns:
    for path in glob.glob(pattern):
        name = read_name_frontmatter(path)
        if name is None or name != query:
            continue
        # path = .../cache/<marketplace>/<plugin>/<version>/[.claude/]skills/<skill>/SKILL.md
        skill_dir = os.path.dirname(path)             # .../skills/<skill>
        skill_name = os.path.basename(skill_dir)
        skills_parent = os.path.dirname(skill_dir)    # .../[.claude/]skills
        # Walk up to the version dir: skills_parent is either <version>/skills
        # (convention) or <version>/.claude/skills (Anthropic). Detect which.
        above_skills = os.path.dirname(skills_parent)  # <version> OR <version>/.claude
        if os.path.basename(above_skills) == ".claude":
            version_dir_path = os.path.dirname(above_skills)
        else:
            version_dir_path = above_skills
        version_dir = os.path.basename(version_dir_path)
        plugin = os.path.basename(os.path.dirname(version_dir_path))

        key = (plugin, skill_name)
        sk = version_sort_key(version_dir, path)
        if key not in best or sk > best[key][0]:
            best[key] = (sk, plugin, skill_name)

for (_sk, plugin, skill_name) in best.values():
    # TAB-separated TRIPLE; bash sanitizes + formats the final TSV record. Strip
    # control/format chars HERE so an injected \n/\t can never reach the
    # record/field separator (transport-boundary defense). The parent FQN comes
    # from the registry key (already control/format-safe in the same sense — it
    # is also user-writable JSON, so strip it too).
    parent_fqn = plugin_fqn_map.get(plugin, "")
    sys.stdout.write(
        _sd(plugin) + "\t" + _sd(skill_name) + "\t" + _sd(parent_fqn) + "\n")

sys.exit(0)
PYEOF
)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'source=missing\treason=skills-cache-parse-failed\n' >&2
    return 0
  fi

  # Format each match. Sanitize attacker-controllable fields BEFORE printf.
  # parent_raw is the registry-derived parent-plugin FQN (may be empty — then
  # parent_plugin= is emitted empty and the orchestrator refuses).
  local plugin_raw skill_raw parent_raw plugin_d skill_d parent_d fqn_d
  while IFS=$'\t' read -r plugin_raw skill_raw parent_raw; do
    [ -z "$plugin_raw" ] && [ -z "$skill_raw" ] && continue
    plugin_d="$(claude_modes::sanitize_for_display "$plugin_raw")"
    skill_d="$(claude_modes::sanitize_for_display "$skill_raw")"
    parent_d="$(claude_modes::sanitize_for_display "$parent_raw")"
    fqn_d="${plugin_d}:${skill_d}"
    printf 'kind=skill\tid=%s\tsource=cache\tinstalled=Y\tparent_plugin=%s\n' \
      "$fqn_d" "$parent_d"
  done <<< "$raw"
}

# __claude_modes::emit_candidates_from_installed_plugins <query>
#
# Source 2. Reads ~/.claude/plugins/installed_plugins.json (LIST-of-records
# aware — mirrors cascade-engine.sh:87-95). Matches when the plugin NAME (the
# part of "<name>@<marketplace>" before the @) equals <query>. Emits the full
# "<name>@<marketplace>" key as the FQN. installed=Y.
__claude_modes::emit_candidates_from_installed_plugins() {
  local query="$1"
  local registry="${HOME}/.claude/plugins/installed_plugins.json"

  # Absent registry: not an error (first-run state). Skip silently.
  [ -f "$registry" ] || return 0

  local raw rc
  raw=$("$CLAUDE_MODES_PYTHON3" - "$registry" "$query" "$SCRIPT_DIR" <<'PYEOF'
import sys, json

registry_path = sys.argv[1]
query = sys.argv[2]
sys.path.insert(0, sys.argv[3])
from registry import iter_plugin_entries  # noqa: E402
from sanitize import sanitize_for_display as _sd  # noqa: E402

if not query:
    sys.exit(0)

# Explicit load (NOT registry.load_registry) so a parse failure can signal the
# caller via exit 3 — the caller emits an "installed-plugins-parse-failed"
# diagnostic on non-zero rc. load_registry would swallow the error to {}.
try:
    with open(registry_path) as f:
        data = json.load(f)
except Exception:
    sys.exit(3)

# Registry shape + record-validity handled by the canonical iterator.
seen = set()
for key, _records in iter_plugin_entries(data):
    name = key.split("@", 1)[0]
    if name != query:
        continue
    if key in seen:
        continue
    seen.add(key)
    # Strip control/format chars HERE so an injected \n/\t in the registry key
    # can't forge a phantom record before the bash split (transport-boundary).
    sys.stdout.write(_sd(key) + "\n")

sys.exit(0)
PYEOF
)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'source=missing\treason=installed-plugins-parse-failed\n' >&2
    return 0
  fi

  local key_raw key_d
  while IFS= read -r key_raw; do
    [ -z "$key_raw" ] && continue
    key_d="$(claude_modes::sanitize_for_display "$key_raw")"
    printf 'kind=plugin\tid=%s\tsource=installed\tinstalled=Y\n' "$key_d"
  done <<< "$raw"
}

# __claude_modes::emit_candidates_from_marketplaces <query>
#
# Source 3. Enumerates installable-but-NOT-installed plugins from every
# ~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json whose plugin
# `name` equals <query>. The FQN is "<plugin-name>@<marketplace-name>" where the
# marketplace name is the marketplace.json TOP-LEVEL `name` (not the directory —
# they may differ). installed=N.
#
# An entry already present in installed_plugins.json is suppressed here (we want
# only installable-but-not-installed). Python reads the registry to do that
# membership check in-process.
__claude_modes::emit_candidates_from_marketplaces() {
  local query="$1"
  local market_glob_root="${HOME}/.claude/plugins/marketplaces"
  local registry="${HOME}/.claude/plugins/installed_plugins.json"

  # Absent marketplaces dir: not an error. Skip silently.
  [ -d "$market_glob_root" ] || return 0

  local raw rc
  raw=$("$CLAUDE_MODES_PYTHON3" - "$query" "$market_glob_root" "$registry" "$SCRIPT_DIR" <<'PYEOF'
import sys, os, json, glob

query = sys.argv[1]
market_root = sys.argv[2]
registry_path = sys.argv[3]
sys.path.insert(0, sys.argv[4])
from registry import iter_plugin_entries, load_registry  # noqa: E402
from sanitize import sanitize_for_display as _sd  # noqa: E402

if not query:
    sys.exit(0)

# Build the set of already-installed "<name>@<marketplace>" keys so we only emit
# installable-but-not-installed entries. A missing/unparseable registry just
# means "treat nothing as installed" (best-effort; the registry-parse failure is
# separately reported by source 2). Registry shape via canonical iterator.
installed_keys = {key for key, _records in iter_plugin_entries(load_registry(registry_path))}

any_parse_failure = False
pattern = os.path.join(market_root, "*", ".claude-plugin", "marketplace.json")
emitted = set()
for path in glob.glob(pattern):
    try:
        with open(path) as f:
            mdata = json.load(f)
    except Exception:
        any_parse_failure = True
        continue
    if not isinstance(mdata, dict):
        any_parse_failure = True
        continue
    market_name = mdata.get("name")
    if not isinstance(market_name, str) or not market_name:
        # Fall back to the marketplace directory name.
        market_name = os.path.basename(os.path.dirname(os.path.dirname(path)))
    plugins = mdata.get("plugins")
    if not isinstance(plugins, list):
        continue
    for entry in plugins:
        if not isinstance(entry, dict):
            continue
        pname = entry.get("name")
        if not isinstance(pname, str) or pname != query:
            continue
        # Strip control/format chars from BOTH components before joining, so an
        # injected \n/\t in either can't forge a phantom record (transport-
        # boundary). The '@' separator is structural and stays intact.
        fqn = _sd(pname) + "@" + _sd(market_name)
        if fqn in installed_keys or fqn in emitted:
            continue
        emitted.add(fqn)
        sys.stdout.write(fqn + "\n")

# Signal "a marketplace file existed but failed to parse" so the caller can warn.
if any_parse_failure:
    sys.exit(3)
sys.exit(0)
PYEOF
)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'source=missing\treason=marketplace-parse-failed\n' >&2
    # A parse failure still leaves any successfully-read entries in $raw; emit them.
  fi

  local fqn_raw fqn_d
  while IFS= read -r fqn_raw; do
    [ -z "$fqn_raw" ] && continue
    fqn_d="$(claude_modes::sanitize_for_display "$fqn_raw")"
    printf 'kind=plugin\tid=%s\tsource=marketplace\tinstalled=N\n' "$fqn_d"
  done <<< "$raw"
}

# claude_modes::resolve_candidate <query>
#
# Public entry point. Runs all three sources in order, concatenating their TSV
# rows to stdout. Empty query → no output (exit 0). Always returns 0; the
# absence of matches is not an error (the caller decides the message).
claude_modes::resolve_candidate() {
  local query="${1:-}"

  # Empty query → caller decides the error. No output, clean exit.
  [ -z "$query" ] && return 0

  __claude_modes::emit_candidates_from_skills_cache "$query"
  __claude_modes::emit_candidates_from_installed_plugins "$query"
  __claude_modes::emit_candidates_from_marketplaces "$query"

  return 0
}

# Dual-purpose: sourceable AND runnable.
#   bash lib/resolve-catalog-candidate.sh <query>
#
# CLI guard (mirrors lib/audit.sh): a zero-arg / empty-query CLI invocation is a
# usage error, not a clean no-match — exit 2 with a usage message on stderr so a
# caller can tell "you forgot the query" from "queried, nothing matched". The
# FUNCTION stays silent-on-empty (callers depend on that); only the CLI surface
# distinguishes the missing-query case.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
    echo "Usage: $0 <query>" >&2
    exit 2
  fi
  claude_modes::resolve_candidate "$1"
fi
