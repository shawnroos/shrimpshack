# surfaces_test.sh — the plugin's manifest and its two reachable surfaces.
#
# Nothing here reads above the plugin directory. The version-sync check between
# plugin.json and the repo-root marketplace.json deliberately does NOT live here:
# a test that reads the repo root cannot pass from the installed cache or a
# plugin-only export, so it fails on packaging and reads as a regression. That
# check belongs to the publish step.

MANIFEST="$PLUGIN/.claude-plugin/plugin.json"

check "plugin.json parses" "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$MANIFEST'"
check "hooks.json parses" "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$PLUGIN/.claude/hooks/hooks.json'"

for key in skills commands hooks; do
  check "plugin.json declares $key" \
    "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in d else 1)' '$MANIFEST' '$key'"
done

check "the declared commands dir exists" "[ -d '$PLUGIN/commands' ]"
check "the declared skills dir exists"   "[ -d '$PLUGIN/skills' ]"
check "the declared hooks file exists"   "[ -r '$PLUGIN/.claude/hooks/hooks.json' ]"
check "the gate script is executable"    "[ -x '$PLUGIN/hooks/gate.sh' ]"

# --- the collision that makes a skill unreachable ---
# A command and a skill sharing a name resolve to the command, and the skill
# never loads -- no error, no warning, and the plugin still behaves plausibly.
# Enumerated dynamically, with a floor so two empty globs cannot pass vacuously.
_cmds=0
_skills=0
_collisions=""
for _f in "$PLUGIN"/commands/*.md; do
  [ -e "$_f" ] || continue
  _cmds=$((_cmds+1))
  _name="$(basename "$_f" .md)"
  [ -d "$PLUGIN/skills/$_name" ] && _collisions="$_collisions $_name"
done
for _d in "$PLUGIN"/skills/*/; do [ -d "$_d" ] && _skills=$((_skills+1)); done

check "at least one command exists" "[ '$_cmds' -ge 1 ]"
check "at least one skill exists"   "[ '$_skills' -ge 1 ]"
check_eq "no command name shadows a skill name" "" "$_collisions"

# --- the command's own frontmatter ---
_cut="$PLUGIN/commands/cut.md"
check "the cut command exists" "[ -r '$_cut' ]"
check "cut.md declares a description" "grep -q '^description:' '$_cut'"
check "cut.md declares an argument-hint" "grep -q '^argument-hint:' '$_cut'"
check "cut.md points at the skill by its full name" "grep -q 'comment-cut:comment-cut' '$_cut'"

# --- the skill's guard and its detector paths ---
_skill="$PLUGIN/skills/comment-cut/SKILL.md"
check "the skill carries the invoked-by-name guard" "grep -q 'Invoked by name only' '$_skill'"

# The detector is called from a target repo, where a bare relative path does not
# exist. Both references must resolve through the plugin root.
check_eq "no bare relative detector path remains" "0" \
  "$(grep -cE '(^|[^/A-Z_}])tools/comment-cut/run\.sh' "$_skill")"
_anchored="$(grep -c 'CLAUDE_PLUGIN_ROOT.*tools/comment-cut/run\.sh' "$_skill")"
check "the detector resolves through CLAUDE_PLUGIN_ROOT" "[ '$_anchored' -ge 2 ]"

# --- the README ---
_readme="$PLUGIN/README.md"
check "a README exists" "[ -r '$_readme' ]"
check "the README is not a stub" "[ \"\$(wc -l < '$_readme')\" -ge 30 ]"
check "the README names the command" "grep -q '/comment-cut:cut' '$_readme'"
check "the README explains the opt-in marker" "grep -q '.comment-cut-gate' '$_readme'"
check "the README names the kill switch" "grep -q 'COMMENT_CUT_GATE_OFF' '$_readme'"
check "the README states the advisory limit" "grep -qi 'not evidence' '$_readme'"
check "the README says the gate only sees in-session commands" "grep -qi 'session' '$_readme'"
