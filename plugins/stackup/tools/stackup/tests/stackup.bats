#!/usr/bin/env bats
#
# Both hooks exit 0 on every path by design, so every assertion here is on
# STDOUT. An exit-code assertion would hold whether or not the ask fired.

setup() {
  TOOLS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RUN="$TOOLS/run.sh"
  TMP="$(mktemp -d)"
  export STACKUP_STATE_DIR="$TMP/state"
  unset STACKUP_AUDIT
}
teardown() { rm -rf "$TMP"; }

# The payload goes to a file and is redirected in; interpolating JSON straight
# into `bash -c` makes bash try to execute it as a command.
plan_payload() { jq -nc --arg p "$1" '{tool_input:{file_path:$p}}' > "$TMP/in.json"; }
bash_payload() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' > "$TMP/in.json"; }
hook() { run bash -c "bash '$RUN' $1 < '$TMP/in.json'"; }
asked()     { [ -n "$output" ] && echo "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null; }
not_asked() { [ -z "$output" ]; }

mkplan() { # $1=path $2=unit count
  mkdir -p "$(dirname "$1")"
  : > "$1"
  for i in $(seq 1 "$2"); do printf '### U%s. thing\n\nbody\n\n' "$i" >> "$1"; done
}

# ---------- U3: plan-time hook ----------

@test "plan with five units and no strategy asks" {
  mkplan "$TMP/docs/plans/a-plan.md" 5
  plan_payload "$TMP/docs/plans/a-plan.md"; hook plan
  asked
}

@test "single-unit plan does not ask" {
  mkplan "$TMP/docs/plans/b-plan.md" 1
  plan_payload "$TMP/docs/plans/b-plan.md"; hook plan
  not_asked
}

@test "plan that already records a strategy does not ask" {
  mkplan "$TMP/docs/plans/c-plan.md" 4
  echo '## PR & landing strategy' >> "$TMP/docs/plans/c-plan.md"
  plan_payload "$TMP/docs/plans/c-plan.md"; hook plan
  not_asked
}

@test "a written file that is not a plan does not ask" {
  mkdir -p "$TMP/src"; echo hi > "$TMP/src/thing.md"
  plan_payload "$TMP/src/thing.md"; hook plan
  not_asked
}

@test "plan whose units cannot be counted still asks" {
  mkdir -p "$TMP/docs/plans"; printf 'no unit headings at all\n' > "$TMP/docs/plans/d-plan.md"
  plan_payload "$TMP/docs/plans/d-plan.md"; hook plan
  asked
}

@test "unreadable plan file still asks" {
  plan_payload "$TMP/docs/plans/missing-plan.md"; hook plan
  asked
}

@test "plan ask admits a one-pull-request answer" {
  mkplan "$TMP/docs/plans/e-plan.md" 3
  plan_payload "$TMP/docs/plans/e-plan.md"; hook plan
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -qi 'one pull request'
}

@test "plan hook names PostToolUse as the firing event" {
  mkplan "$TMP/docs/plans/f-plan.md" 3
  plan_payload "$TMP/docs/plans/f-plan.md"; hook plan
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
}

@test "empty payload asks nothing" {
  run bash -c ": > '$TMP/in.json'; bash '$RUN' plan < '$TMP/in.json'"
  not_asked
}

# ---------- U4: pull-request-time hook ----------

@test "opening a pull request asks" {
  bash_payload 'gh pr create --fill'; hook pr
  asked
}

@test "a multi-line pull-request command still matches" {
  bash_payload 'cd /tmp && \
gh pr create --title x \
  --body y'; hook pr
  asked
}

@test "unusual flag ordering still matches" {
  bash_payload 'gh   pr    create -R owner/repo --draft'; hook pr
  asked
}

@test "a gh stack command does not ask" {
  bash_payload 'gh stack submit'; hook pr
  not_asked
}

@test "an unrelated shell command does not ask" {
  bash_payload 'ls -la'; hook pr
  not_asked
}

@test "pr hook names PreToolUse as the firing event" {
  bash_payload 'gh pr create'; hook pr
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null
}

@test "pr hook never returns a permission decision" {
  bash_payload 'gh pr create'; hook pr
  ! echo "$output" | grep -q 'permissionDecision'
}

# ---------- U2: capability gate ----------

@test "no cached capability result still asks" {
  bash_payload 'gh pr create'; hook pr
  asked
}

@test "a recorded unavailable result suppresses the ask" {
  bash "$TOOLS/capability.sh" record-unavailable
  bash_payload 'gh pr create'; hook pr
  not_asked
}

@test "a corrupt cache entry asks rather than suppressing" {
  bash "$TOOLS/capability.sh" record-unavailable
  find "$STACKUP_STATE_DIR" -type f -exec sh -c 'printf garbage > "$1"' _ {} \;
  bash_payload 'gh pr create'; hook pr
  asked
}

@test "forget clears a recorded unavailable result" {
  bash "$TOOLS/capability.sh" record-unavailable
  bash "$TOOLS/capability.sh" forget
  bash_payload 'gh pr create'; hook pr
  asked
}

@test "the audit switch surfaces a suppressed decision" {
  bash "$TOOLS/capability.sh" record-unavailable
  bash_payload 'gh pr create'
  run bash -c "STACKUP_AUDIT=1 bash '$RUN' pr < '$TMP/in.json'"
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -qi 'audit'
}

@test "emitted payload is valid JSON with non-empty context" {
  mkplan "$TMP/docs/plans/g-plan.md" 3
  plan_payload "$TMP/docs/plans/g-plan.md"; hook plan
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 20' >/dev/null
}
