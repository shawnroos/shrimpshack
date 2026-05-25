#!/usr/bin/env bash
# U6 integration: /mode:setup install half of the round-trip.
#
# (Uninstall half is implemented in U7.)
#
# Scenarios covered (install half):
#   1. _global.yaml exists at 0600 with schema_version: 2 + enabledPlugins
#   2. settings.json.pristine exists at 0600, allowlist-filtered (keeps
#      settings.json
#   3. .installed-repos.txt exists at 0600 (empty)
#   4. Every original ~/.claude/commands/*.md is a symlink whose target is
#      under ~/.claude/modes/.user-catalog/commands/
#   5. Every original ~/.claude/agents/*.md likewise under agents/
#   6. cat <live-path> for each file yields byte-identical content to pre-install
#   7. discovery.yaml + delivery.yaml seeded
#   8. Sentinel .setup.in-progress is gone after success
#   9. .first-install.notice exists with the local-dev message
#  10. enabledPlugins carries over user plugins AND the synthetic
#      claude-modes@local-dev identifier when pristine lacked claude-modes
#  11. Existing claude-modes identifier in pristine → no synthetic add,
#      no first-install notice

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

PY="${CLAUDE_MODES_PYTHON3}"

_perms() {
  stat -f '%A' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

_sha() {
  shasum "$1" 2>/dev/null | awk '{print $1}'
}

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK A: clean install with user plugins (NO claude-modes
# pre-existing → synthetic add + notice).
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

# Seed realistic settings.json with user plugins + statusLine + permissions.
mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "compound-engineering@every-marketplace": true,
    "slate-devs@local-dev": true
  },
  "permissions": {
    "allow": ["Bash(git status)", "Bash(ls)"],
    "deny": []
  },
  "statusLine": {
    "type": "command",
    "command": "/Users/test/bin/my-statusline.sh"
  },
  "env": {
    "FOO": "bar"
  }
}
EOF

# Record pre-install state.
PRE_SETTINGS_SHA=$(_sha "${HOME}/.claude/settings.json")

# Seed user-authored commands + agents.
mkdir -p "${HOME}/.claude/commands"
mkdir -p "${HOME}/.claude/agents"
for n in alpha beta gamma; do
  printf '# %s command\n\nBody for %s.\n' "$n" "$n" > "${HOME}/.claude/commands/${n}.md"
done
for n in researcher coder; do
  printf '# %s agent\n\nAgent body for %s.\n' "$n" "$n" > "${HOME}/.claude/agents/${n}.md"
done

# Record sha256 of every catalog file pre-install (basename → sha map).
declare -A PRE_SHA
for f in "${HOME}/.claude/commands"/*.md "${HOME}/.claude/agents"/*.md; do
  PRE_SHA["$(basename "$f")"]=$(_sha "$f")
done

# Run setup.sh.
SETUP_OUT=$(bash "${PLUGIN_ROOT}/scripts/setup.sh" 2>&1)
SETUP_RC=$?

claude_modes_test::it "A: setup.sh exits 0"
claude_modes_test::assert_eq "0" "$SETUP_RC"

# ─── 1. _global.yaml ────────────────────────────────────────────────
claude_modes_test::it "A: _global.yaml exists"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/_global.yaml"

claude_modes_test::it "A: _global.yaml is 0600"
claude_modes_test::assert_eq "600" "$(_perms "${HOME}/.claude/modes/_global.yaml")"

claude_modes_test::it "A: _global.yaml has schema_version: 2"
sv=$("$PY" -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1])).get("schema_version"))' "${HOME}/.claude/modes/_global.yaml")
claude_modes_test::assert_eq "2" "$sv"

claude_modes_test::it "A: _global.yaml carries user plugins from pristine"
keys=$("$PY" -c '
import yaml, sys
d = yaml.safe_load(open(sys.argv[1])) or {}
mech = d.get("mechanism") or {}
ep = mech.get("enabledPlugins") or {}
print(",".join(sorted(ep.keys())))
' "${HOME}/.claude/modes/_global.yaml")
expected="claude-modes@local-dev,compound-engineering@every-marketplace,slate-devs@local-dev"
claude_modes_test::assert_eq "$expected" "$keys"

# ─── 2. pristine ────────────────────────────────────────────────────
claude_modes_test::it "A: pristine exists at 0600"
claude_modes_test::assert_file_exists "${HOME}/.claude/settings.json.pristine"
claude_modes_test::assert_eq "600" "$(_perms "${HOME}/.claude/settings.json.pristine")"

# sec-006/adv-012: pristine is now ALLOWLIST-FILTERED (enabledPlugins +
# theme + statusLine), NOT a byte copy — so it never snapshots secrets.
claude_modes_test::it "A: pristine keeps allowlisted keys (enabledPlugins, statusLine)"
pristine_keys=$("$PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(",".join(sorted(d.keys())))
' "${HOME}/.claude/settings.json.pristine")
claude_modes_test::assert_eq "enabledPlugins,statusLine" "$pristine_keys"

claude_modes_test::it "A: pristine DROPS secret-class keys (permissions, env canary)"
# The seed settings.json has env.FOO=bar + a permissions block; neither is
# allowlisted, so neither must appear in the filtered pristine.
pristine_text=$(cat "${HOME}/.claude/settings.json.pristine")
if printf '%s' "$pristine_text" | grep -q '"permissions"' \
   || printf '%s' "$pristine_text" | grep -q '"env"' \
   || printf '%s' "$pristine_text" | grep -q 'bar'; then
  claude_modes_test::fail "secret-class key leaked into pristine: ${pristine_text}"
else
  claude_modes_test::pass
fi

claude_modes_test::it "A: pristine still carries the user's plugin set"
pristine_plugins=$("$PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
ep = d.get("enabledPlugins") or {}
print(",".join(sorted(ep.keys())))
' "${HOME}/.claude/settings.json.pristine")
claude_modes_test::assert_eq "compound-engineering@every-marketplace,slate-devs@local-dev" "$pristine_plugins"

claude_modes_test::it "A: settings.json is NEVER modified by setup"
POST_SETTINGS_SHA=$(_sha "${HOME}/.claude/settings.json")
claude_modes_test::assert_eq "$PRE_SETTINGS_SHA" "$POST_SETTINGS_SHA"

# ─── 3. install registry ────────────────────────────────────────────
claude_modes_test::it "A: install registry exists at 0600"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/.installed-repos.txt"
claude_modes_test::assert_eq "600" "$(_perms "${HOME}/.claude/modes/.installed-repos.txt")"

claude_modes_test::it "A: install registry is initially empty"
lines=$(wc -l < "${HOME}/.claude/modes/.installed-repos.txt" | tr -d '[:space:]')
claude_modes_test::assert_eq "0" "$lines"

# ─── 4-6. user catalog symlinks + content integrity ──────────────────
for cat_pair in "commands:alpha beta gamma" "agents:researcher coder"; do
  IFS=':' read -r category names <<< "$cat_pair"
  for name in $names; do
    live="${HOME}/.claude/${category}/${name}.md"
    staging="${HOME}/.claude/modes/.user-catalog/${category}/${name}.md"

    claude_modes_test::it "A: ${category}/${name}.md is a symlink"
    claude_modes_test::assert_true "[ -L '$live' ]"

    claude_modes_test::it "A: ${category}/${name}.md symlink target is under staging"
    target=$("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$live")
    expected_target=$("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$staging")
    claude_modes_test::assert_eq "$expected_target" "$target"

    claude_modes_test::it "A: ${category}/${name}.md content sha matches pre-install"
    post_sha=$(_sha "$live")
    claude_modes_test::assert_eq "${PRE_SHA[${name}.md]}" "$post_sha"

    claude_modes_test::it "A: ${category}/${name}.md staging file is 0600"
    claude_modes_test::assert_eq "600" "$(_perms "$staging")"
  done
done

# ─── 7. seeded mode files ───────────────────────────────────────────
claude_modes_test::it "A: discovery.yaml seeded"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/discovery.yaml"
claude_modes_test::it "A: delivery.yaml seeded"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/delivery.yaml"

# ─── 8. sentinel cleared ────────────────────────────────────────────
claude_modes_test::it "A: sentinel .setup.in-progress is gone after success"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.setup.in-progress"

# ─── 9. first-install notice ────────────────────────────────────────
claude_modes_test::it "A: .first-install.notice exists"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/.first-install.notice"

claude_modes_test::it "A: notice mentions claude-modes@local-dev"
notice=$(cat "${HOME}/.claude/modes/.first-install.notice")
claude_modes_test::assert_contains "$notice" "claude-modes@local-dev"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK B: pristine ALREADY carries claude-modes → no synthetic
# add, no first-install notice.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "claude-modes@marketplace": true,
    "compound-engineering@every-marketplace": true
  }
}
EOF

bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1
B_RC=$?

claude_modes_test::it "B: setup.sh exits 0 (claude-modes pre-existed)"
claude_modes_test::assert_eq "0" "$B_RC"

claude_modes_test::it "B: _global.yaml does NOT carry claude-modes@local-dev"
keys=$("$PY" -c '
import yaml, sys
d = yaml.safe_load(open(sys.argv[1])) or {}
mech = d.get("mechanism") or {}
ep = mech.get("enabledPlugins") or {}
print(",".join(sorted(ep.keys())))
' "${HOME}/.claude/modes/_global.yaml")
expected="claude-modes@marketplace,compound-engineering@every-marketplace"
claude_modes_test::assert_eq "$expected" "$keys"

claude_modes_test::it "B: no .first-install.notice when claude-modes pre-existed"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.first-install.notice"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK C: no settings.json at all (fresh user).
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

# Don't create ~/.claude/settings.json at all.
mkdir -p "${HOME}/.claude"

bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1
C_RC=$?

claude_modes_test::it "C: setup.sh exits 0 with no settings.json"
claude_modes_test::assert_eq "0" "$C_RC"

claude_modes_test::it "C: _global.yaml created with synthetic claude-modes only"
keys=$("$PY" -c '
import yaml, sys
d = yaml.safe_load(open(sys.argv[1])) or {}
mech = d.get("mechanism") or {}
ep = mech.get("enabledPlugins") or {}
print(",".join(sorted(ep.keys())))
' "${HOME}/.claude/modes/_global.yaml")
claude_modes_test::assert_eq "claude-modes@local-dev" "$keys"

claude_modes_test::it "C: no pristine created when no settings.json existed"
claude_modes_test::assert_file_absent "${HOME}/.claude/settings.json.pristine"

claude_modes_test::it "C: .first-install.notice still produced"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/.first-install.notice"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# U7 UNINSTALL HALF
#
# All blocks below isolate ($HOME re-rooted) via setup/teardown.
# Each block recreates pre-install state from scratch and re-runs the
# install before exercising uninstall — A/B/C's teardowns nuked their
# sandboxes, so we cannot reuse their state.
#
# Path discipline:
#   - Test "fake repos" live UNDER $HOME (not /tmp) so macOS
#     /private/tmp canonicalization doesn't break the path-class
#     verification. git rev-parse --show-toplevel returns the exact
#     path we registered.
# ══════════════════════════════════════════════════════════════════════

# Helper: minimal init of a fake git repo. Returns the GIT-CANONICAL
# path on stdout (macOS sandbox dirs like /var/folders/... canonicalize
# to /private/var/folders/...; the cascade engine in production
# registers what git rev-parse --show-toplevel returns, so tests must
# register the canonical form too or the path-class check rejects).
_init_fake_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q 2>/dev/null
  # Echo the canonical path. Caller uses this for both filesystem
  # work and the registry entry.
  git -C "$path" rev-parse --show-toplevel 2>/dev/null
}

# Helper: simulate a cascade compile in a fake repo by writing
# settings.local.json + a matching sidecar (fingerprint = sha256 of
# settings.local.json contents). Avoids the trust-gate prompt + the
# rest of cascade-engine surface for these focused tests.
_write_cascade_artifacts() {
  local repo="$1"
  local settings_content="${2:-{\"enabledPlugins\": {\"claude-modes@local-dev\": true}}}"
  mkdir -p "${repo}/.claude/modes"
  printf '%s\n' "$settings_content" > "${repo}/.claude/settings.local.json"
  chmod 0600 "${repo}/.claude/settings.local.json"
  local fp
  fp=$(shasum -a 256 "${repo}/.claude/settings.local.json" | awk '{print $1}')
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  cat > "${repo}/.claude/modes/.cascade-meta.json" <<EOF
{
  "tool": "claude-modes",
  "version": "2.0",
  "fingerprint": "${fp}",
  "compiled_at": "${ts}",
  "source_modes": ["_global.yaml"]
}
EOF
  chmod 0600 "${repo}/.claude/modes/.cascade-meta.json"
  # Register the repo in the install registry so unmodes visits it.
  printf '%s\n' "$repo" >> "${HOME}/.claude/modes/.installed-repos.txt"
}

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK D (AE1): clean round-trip — install, no post-install
# edits, uninstall. User-catalog files come back as REGULAR files with
# byte-identical content. settings.json untouched throughout. Preserved
# audit log written.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

# Pre-install state: seed settings.json + user catalog.
mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "compound-engineering@every-marketplace": true
  },
  "permissions": {"allow": ["Bash(ls)"], "deny": []}
}
EOF
PRE_SETTINGS_SHA=$(_sha "${HOME}/.claude/settings.json")

mkdir -p "${HOME}/.claude/commands" "${HOME}/.claude/agents"
for n in alpha beta gamma; do
  printf '# %s command\n\nBody for %s.\n' "$n" "$n" > "${HOME}/.claude/commands/${n}.md"
done
for n in researcher coder; do
  printf '# %s agent\n\nAgent body for %s.\n' "$n" "$n" > "${HOME}/.claude/agents/${n}.md"
done

declare -A D_PRE_SHA
for f in "${HOME}/.claude/commands"/*.md "${HOME}/.claude/agents"/*.md; do
  D_PRE_SHA["$(basename "$f")"]=$(_sha "$f")
done

# Install.
bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1

# Sanity: install symlinked the catalog.
if [ ! -L "${HOME}/.claude/commands/alpha.md" ]; then
  echo "D PRECOND FAIL: setup did not symlink alpha.md" >&2
fi

# Run uninstall.
UNINSTALL_OUT=$(bash "${PLUGIN_ROOT}/scripts/unmodes.sh" 2>&1)
UNINSTALL_RC=$?

claude_modes_test::it "D: unmodes.sh exits 0 on clean round-trip"
claude_modes_test::assert_eq "0" "$UNINSTALL_RC"

claude_modes_test::it "D: ~/.claude/modes/ is gone after uninstall"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes"

claude_modes_test::it "D: ~/.claude/settings.json is byte-identical to pre-install"
POST_SETTINGS_SHA=$(_sha "${HOME}/.claude/settings.json")
claude_modes_test::assert_eq "$PRE_SETTINGS_SHA" "$POST_SETTINGS_SHA"

claude_modes_test::it "D: ~/.claude/settings.json.pristine is preserved untouched (forensic anchor)"
claude_modes_test::assert_file_exists "${HOME}/.claude/settings.json.pristine"

claude_modes_test::it "D: preserved uninstall log exists"
claude_modes_test::assert_file_exists "${HOME}/.claude/.claude-modes-uninstall.log"

claude_modes_test::it "D: preserved log is 0600"
claude_modes_test::assert_eq "600" "$(_perms "${HOME}/.claude/.claude-modes-uninstall.log")"

claude_modes_test::it "D: preserved log carries the original audit event(s)"
# Setup writes "event=setup" to the audit log; that must survive into
# the preserved log.
claude_modes_test::assert_true "grep -q 'event=setup' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::it "D: preserved log carries the final uninstall event"
claude_modes_test::assert_true "grep -q 'event=uninstall' '${HOME}/.claude/.claude-modes-uninstall.log'"

# Catalog files come back as regular files (not symlinks) with
# byte-identical content.
for cat_pair in "commands:alpha beta gamma" "agents:researcher coder"; do
  IFS=':' read -r category names <<< "$cat_pair"
  for name in $names; do
    live="${HOME}/.claude/${category}/${name}.md"

    claude_modes_test::it "D: ${category}/${name}.md is back as a regular file (not symlink)"
    if [ -L "$live" ]; then
      claude_modes_test::fail "expected regular file, got symlink: $live"
    elif [ ! -f "$live" ]; then
      claude_modes_test::fail "expected regular file to exist: $live"
    else
      claude_modes_test::pass
    fi

    claude_modes_test::it "D: ${category}/${name}.md sha256 matches pre-install"
    post_sha=$(_sha "$live")
    claude_modes_test::assert_eq "${D_PRE_SHA[${name}.md]}" "$post_sha"
  done
done

claude_modes_test::it "D: uninstall stdout confirms preserved log path"
claude_modes_test::assert_contains "$UNINSTALL_OUT" ".claude-modes-uninstall.log"

claude_modes_test::it "D: uninstall stdout reassures settings.json untouched"
claude_modes_test::assert_contains "$UNINSTALL_OUT" "settings.json"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK E: sidecar fingerprint MISMATCH → preserve
# settings.local.json (user edited post-cascade), remove sidecar only.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

# Install.
mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{"enabledPlugins": {"claude-modes@marketplace": true}}
EOF
bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1

# Build a fake repo with a plugin-authored cascade (sidecar matches
# settings.local.json fingerprint) — under $HOME for path-class safety.
REPO_E=$(_init_fake_repo "${HOME}/repoE")
_write_cascade_artifacts "$REPO_E"

# Verify pre-state.
if [ ! -f "${REPO_E}/.claude/settings.local.json" ]; then
  echo "E PRECOND FAIL: settings.local.json missing" >&2
fi

# Now the user "edits" settings.local.json post-cascade. The fingerprint
# in the sidecar no longer matches.
echo '  "userAddedKey": "value"' >> "${REPO_E}/.claude/settings.local.json"
USER_EDITED_SHA=$(_sha "${REPO_E}/.claude/settings.local.json")

# Run uninstall.
bash "${PLUGIN_ROOT}/scripts/unmodes.sh" >/dev/null 2>&1

claude_modes_test::it "E: settings.local.json is PRESERVED when fingerprint mismatches"
claude_modes_test::assert_file_exists "${REPO_E}/.claude/settings.local.json"

claude_modes_test::it "E: preserved settings.local.json content unchanged (user's edits intact)"
POST_E_SHA=$(_sha "${REPO_E}/.claude/settings.local.json")
claude_modes_test::assert_eq "$USER_EDITED_SHA" "$POST_E_SHA"

claude_modes_test::it "E: sidecar IS removed on mismatch"
claude_modes_test::assert_file_absent "${REPO_E}/.claude/modes/.cascade-meta.json"

claude_modes_test::it "E: preserved log notes the user-edited preservation"
claude_modes_test::assert_true "grep -q 'uninstall_preserve_settings' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::it "E: preserved log records the user-edited reason"
claude_modes_test::assert_true "grep -q 'reason=user-edited-post-cascade' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK F: no-sidecar preservation — a settings.local.json
# existed at the registered path BEFORE claude-modes ever ran a cascade
# (no sidecar). Uninstall must NOT delete it.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{"enabledPlugins": {"claude-modes@marketplace": true}}
EOF
bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1

REPO_F=$(_init_fake_repo "${HOME}/repoF")
mkdir -p "${REPO_F}/.claude"
# Pre-existing user-authored settings.local.json — NO sidecar at all.
cat > "${REPO_F}/.claude/settings.local.json" <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": []}]}}
EOF
PRE_F_SHA=$(_sha "${REPO_F}/.claude/settings.local.json")
# Register the repo in the install registry so uninstall visits it.
printf '%s\n' "$REPO_F" >> "${HOME}/.claude/modes/.installed-repos.txt"

bash "${PLUGIN_ROOT}/scripts/unmodes.sh" >/dev/null 2>&1

claude_modes_test::it "F: settings.local.json is PRESERVED when no sidecar exists"
claude_modes_test::assert_file_exists "${REPO_F}/.claude/settings.local.json"

claude_modes_test::it "F: preserved settings.local.json sha unchanged"
POST_F_SHA=$(_sha "${REPO_F}/.claude/settings.local.json")
claude_modes_test::assert_eq "$PRE_F_SHA" "$POST_F_SHA"

claude_modes_test::it "F: preserved log records no-sidecar reason"
claude_modes_test::assert_true "grep -q 'reason=no-sidecar' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK G: PATH-CLASS REFUSAL — a malicious / corrupt registry
# entry points at a non-git path. Uninstall MUST refuse to touch it.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{"enabledPlugins": {"claude-modes@marketplace": true}}
EOF
bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1

# Manually inject a non-git path into the registry. Pick a path that
# exists and has a real settings.local.json we MUST NOT touch.
NOTREPO="${HOME}/notrepo"
mkdir -p "${NOTREPO}/.claude/modes"
cat > "${NOTREPO}/.claude/settings.local.json" <<'EOF'
{"sensitiveKey": "should-not-be-deleted"}
EOF
PRE_G_SHA=$(_sha "${NOTREPO}/.claude/settings.local.json")

# Plant a sidecar with a matching fingerprint — even though fingerprint
# matches, path-class must refuse because $NOTREPO is not a git repo.
PRE_G_FP=$(shasum -a 256 "${NOTREPO}/.claude/settings.local.json" | awk '{print $1}')
cat > "${NOTREPO}/.claude/modes/.cascade-meta.json" <<EOF
{
  "tool": "claude-modes",
  "version": "2.0",
  "fingerprint": "${PRE_G_FP}",
  "compiled_at": "2026-01-01T00:00:00Z",
  "source_modes": ["_global.yaml"]
}
EOF
printf '%s\n' "$NOTREPO" >> "${HOME}/.claude/modes/.installed-repos.txt"

bash "${PLUGIN_ROOT}/scripts/unmodes.sh" >/dev/null 2>&1

claude_modes_test::it "G: non-git registry entry — settings.local.json PRESERVED"
claude_modes_test::assert_file_exists "${NOTREPO}/.claude/settings.local.json"

claude_modes_test::it "G: non-git path — settings.local.json sha unchanged"
POST_G_SHA=$(_sha "${NOTREPO}/.claude/settings.local.json")
claude_modes_test::assert_eq "$PRE_G_SHA" "$POST_G_SHA"

claude_modes_test::it "G: non-git path — sidecar PRESERVED (we never touched the tree)"
claude_modes_test::assert_file_exists "${NOTREPO}/.claude/modes/.cascade-meta.json"

claude_modes_test::it "G: preserved log records the path-class skip"
claude_modes_test::assert_true "grep -q 'uninstall_skip_path' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::it "G: preserved log identifies the not-git-repo reason"
claude_modes_test::assert_true "grep -q 'reason=not-git-repo' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK H: reinstall after uninstall — install → uninstall →
# install again succeeds (no leftover state breaks it).
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{"enabledPlugins": {"claude-modes@marketplace": true}}
EOF
mkdir -p "${HOME}/.claude/commands"
printf '# first\n' > "${HOME}/.claude/commands/first.md"

# Install round 1.
bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1
# Uninstall.
bash "${PLUGIN_ROOT}/scripts/unmodes.sh" >/dev/null 2>&1
# Install round 2.
SECOND_OUT=$(bash "${PLUGIN_ROOT}/scripts/setup.sh" 2>&1)
SECOND_RC=$?

claude_modes_test::it "H: second setup.sh after uninstall exits 0"
claude_modes_test::assert_eq "0" "$SECOND_RC"

claude_modes_test::it "H: second install re-created _global.yaml"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/_global.yaml"

claude_modes_test::it "H: second install re-symlinked first.md"
claude_modes_test::assert_true "[ -L '${HOME}/.claude/commands/first.md' ]"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK I: uninstall on a NEVER-installed system → graceful
# exit 0, no errors.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

# Don't install anything. The setup helper creates an empty
# ~/.claude/modes/ for plugin-state hygiene; remove it so the presence
# check fires correctly.
rm -rf "${HOME}/.claude/modes"

OUT=$(bash "${PLUGIN_ROOT}/scripts/unmodes.sh" 2>&1)
RC=$?

claude_modes_test::it "I: unmodes.sh on never-installed system exits 0"
claude_modes_test::assert_eq "0" "$RC"

claude_modes_test::it "I: stdout says 'not installed'"
claude_modes_test::assert_contains "$OUT" "not installed"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK J: alien live file in user-catalog area — uninstall
# must preserve everything, NOT clobber the user's regular file.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{"enabledPlugins": {"claude-modes@marketplace": true}}
EOF
mkdir -p "${HOME}/.claude/commands"
printf '# original alpha\n' > "${HOME}/.claude/commands/alpha.md"

# Install (alpha.md symlinks to staging).
bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1

# Remove the symlink and put a REGULAR file in its place (user replaced
# the symlink post-install — alien state).
rm -f "${HOME}/.claude/commands/alpha.md"
printf '# user replaced alpha post-install\n' > "${HOME}/.claude/commands/alpha.md"
ALIEN_SHA=$(_sha "${HOME}/.claude/commands/alpha.md")

bash "${PLUGIN_ROOT}/scripts/unmodes.sh" >/dev/null 2>&1

claude_modes_test::it "J: alien live file is preserved (sha unchanged)"
POST_J_SHA=$(_sha "${HOME}/.claude/commands/alpha.md")
claude_modes_test::assert_eq "$ALIEN_SHA" "$POST_J_SHA"

# Note: since we didn't remove ~/.claude/modes/ until the END, but
# step 6 deletes the whole tree, the staged copy is gone. That's fine
# — the user's live file is what matters. The audit log notes the skip.
claude_modes_test::it "J: preserved log notes the user-catalog skip"
claude_modes_test::assert_true "grep -q 'uninstall_skip_user_catalog' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# SCENARIO BLOCK K: live-absent — user deleted the live symlink post-
# install. Strict-spec behavior: preserve (skip), DON'T restore. The
# spec's "preserve everything, continue" applies to "live is anything
# other than our symlink," including absent.
# ══════════════════════════════════════════════════════════════════════
claude_modes_test::setup

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" <<'EOF'
{"enabledPlugins": {"claude-modes@marketplace": true}}
EOF
mkdir -p "${HOME}/.claude/commands"
printf '# alpha\n' > "${HOME}/.claude/commands/alpha.md"
printf '# beta\n' > "${HOME}/.claude/commands/beta.md"

bash "${PLUGIN_ROOT}/scripts/setup.sh" >/dev/null 2>&1

# User removes the live symlink for beta.md post-install (alpha kept intact).
rm -f "${HOME}/.claude/commands/beta.md"

bash "${PLUGIN_ROOT}/scripts/unmodes.sh" >/dev/null 2>&1

claude_modes_test::it "K: alpha.md (still symlinked) is restored as regular file"
claude_modes_test::assert_file_exists "${HOME}/.claude/commands/alpha.md"
if [ -L "${HOME}/.claude/commands/alpha.md" ]; then
  claude_modes_test::fail "alpha.md should be regular, got symlink"
fi

claude_modes_test::it "K: beta.md (deleted by user pre-uninstall) is NOT resurrected"
claude_modes_test::assert_file_absent "${HOME}/.claude/commands/beta.md"

claude_modes_test::it "K: preserved log notes live-absent for beta.md"
claude_modes_test::assert_true "grep -q 'reason=live-absent' '${HOME}/.claude/.claude-modes-uninstall.log'"

claude_modes_test::teardown

# ══════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════
printf '\n%s: %d passed, %d failed\n' \
  "install-uninstall-roundtrip.test.sh" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
