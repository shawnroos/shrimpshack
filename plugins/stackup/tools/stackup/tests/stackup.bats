#!/usr/bin/env bats
#
# Both hooks exit 0 on every path by design, so every assertion here is on
# STDOUT. An exit-code assertion would hold whether or not the ask fired.

# --separate-stderr needs 1.5+; the ask signal is stdout only.
bats_require_minimum_version 1.5.0

setup() {
  TOOLS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RUN="$TOOLS/run.sh"
  TMP="$(mktemp -d)"
  export STACKUP_STATE_DIR="$TMP/state"
  unset STACKUP_AUDIT
  # Without this the pr-mode tests measure whatever repo the suite was run
  # from, so a single-file working branch fails them for unrelated reasons.
  mkdir -p "$TMP/nogit"
}
teardown() { rm -rf "$TMP"; }

# The payload goes to a file and is redirected in; interpolating JSON straight
# into `bash -c` makes bash try to execute it as a command.
plan_payload() { jq -nc --arg p "$1" '{tool_input:{file_path:$p}}' > "$TMP/in.json"; }
bash_payload() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' > "$TMP/in.json"; }
# --separate-stderr keeps $output as stdout only: the ask signal is stdout, and
# stderr noise on a silent path would otherwise read as "it asked".
hook() { run --separate-stderr bash -c "cd '$TMP/nogit' && bash '$RUN' $1 < '$TMP/in.json'"; }
record_unavailable_in() { ( cd "$1" && bash "$TOOLS/capability.sh" record-unavailable ); }
forget_in() { ( cd "$1" && bash "$TOOLS/capability.sh" forget ); }
# A cd that fails would short-circuit into empty output, which reads as a pass on
# every not_asked assertion. Fail loudly instead.
hook_in() { [ -d "$1" ] || { echo "hook_in: no such dir: $1" >&2; return 1; }; run --separate-stderr bash -c "cd '$1' && bash '$RUN' $2 < '$TMP/in.json'"; }
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
  run --separate-stderr bash -c ": > '$TMP/in.json'; cd '$TMP/nogit' && bash '$RUN' plan < '$TMP/in.json'"
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
  record_unavailable_in "$TMP/nogit"
  bash_payload 'gh pr create'; hook pr
  not_asked
}

@test "a corrupt cache entry asks rather than suppressing" {
  record_unavailable_in "$TMP/nogit"
  find "$STACKUP_STATE_DIR" -type f -exec sh -c 'printf garbage > "$1"' _ {} \;
  bash_payload 'gh pr create'; hook pr
  asked
}

@test "forget clears a recorded unavailable result" {
  record_unavailable_in "$TMP/nogit"
  forget_in "$TMP/nogit"
  bash_payload 'gh pr create'; hook pr
  asked
}

@test "the audit switch surfaces a suppressed decision" {
  record_unavailable_in "$TMP/nogit"
  bash_payload 'gh pr create'
  run --separate-stderr bash -c "cd '$TMP/nogit' && STACKUP_AUDIT=1 bash '$RUN' pr < '$TMP/in.json'"
  echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -qi 'audit'
}

@test "emitted payload is valid JSON with non-empty context" {
  mkplan "$TMP/docs/plans/g-plan.md" 3
  plan_payload "$TMP/docs/plans/g-plan.md"; hook plan
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 20' >/dev/null
}

mkrepo() { # $1=dir  $2..=files to change on a feature branch off master
  local r="$1"; shift
  mkdir -p "$r"
  git -C "$r" init -q -b master
  git -C "$r" config user.email t@e; git -C "$r" config user.name t
  echo seed > "$r/seed.txt"; git -C "$r" add -A; git -C "$r" commit -qm base
  git -C "$r" checkout -q -b feat
  local f; for f in "$@"; do echo "$RANDOM" > "$r/$f"; done
  git -C "$r" add -A; git -C "$r" commit -qm work
}

@test "single-file change suppresses on a master-default repo with no origin/HEAD" {
  # Regression: a hardcoded origin/main fallback named a ref that does not exist
  # here, so the diff failed, the count read 0, and this suppression never fired.
  mkrepo "$TMP/repo" a.txt
  bash_payload 'gh pr create --fill'
  hook_in "$TMP/repo" pr
  [ -z "$output" ]
}

@test "multi-file change still asks on a master-default repo" {
  mkrepo "$TMP/repo2" a.txt b.txt c.txt
  bash_payload 'gh pr create --fill'
  hook_in "$TMP/repo2" pr
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null
}

@test "html plan with several units asks" {
  mkdir -p "$TMP/docs/plans"
  printf '<h3 id="u1">U1. alpha</h3>\n<h3 id="u2">U2. beta</h3>\n' > "$TMP/docs/plans/h-plan.html"
  plan_payload "$TMP/docs/plans/h-plan.html"; hook plan
  asked
}

@test "a recorded one-pull-request decision stops the ask" {
  # The wording ASK_PLAN tells the agent to use must be the wording that suppresses,
  # or complying with the answer earns the same question on every later edit.
  mkplan "$TMP/docs/plans/i-plan.md" 4
  printf '\n## PR & landing strategy\n\nOne pull request: this is one logical change.\n' >> "$TMP/docs/plans/i-plan.md"
  plan_payload "$TMP/docs/plans/i-plan.md"; hook plan
  not_asked
}

@test "the wording ASK_PLAN asks for is the wording that suppresses" {
  mkplan "$TMP/docs/plans/j-plan.md" 3
  plan_payload "$TMP/docs/plans/j-plan.md"; hook plan
  token="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -oiE 'PR & landing strategy' | head -1)"
  [ -n "$token" ]
  printf '\n## %s\n\nOne pull request.\n' "$token" >> "$TMP/docs/plans/j-plan.md"
  plan_payload "$TMP/docs/plans/j-plan.md"; hook plan
  not_asked
}

@test "pr payload with no command asks nothing" {
  printf '{}' > "$TMP/in.json"
  hook pr
  not_asked
}

@test "pr hook outside a git repository still asks" {
  bash_payload 'gh pr create --fill'
  hook pr
  asked
}

@test "origin/HEAD is preferred over the guessed candidates" {
  bare="$TMP/bare.git"; git init -q --bare -b main "$bare"
  r="$TMP/repo3"; mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@e; git -C "$r" config user.name t
  echo seed > "$r/seed.txt"; git -C "$r" add -A; git -C "$r" commit -qm base
  git -C "$r" remote add origin "$bare"; git -C "$r" push -q origin main
  git -C "$r" fetch -q origin
  git -C "$r" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$r" checkout -q -b feat
  echo x > "$r/a.txt"; git -C "$r" add -A; git -C "$r" commit -qm one-file
  bash_payload 'gh pr create --fill'
  hook_in "$r" pr
  not_asked
}

@test "jq missing goes quiet, and the audit switch says why" {
  # The plugin's whole-product death mode. Silent by design; the audit switch is
  # the only instrument that can reveal it, so it must survive this path.
  # A shim PATH holding only what runs before the jq guard, so jq is genuinely
  # absent. An "everything but jq" system PATH is not reliable — jq lives in
  # /usr/bin on some machines — and a skip here would be a vacuous pass.
  NOJQ="$TMP/shim"; mkdir -p "$NOJQ"
  ln -sf "$(command -v dirname)" "$NOJQ/dirname"
  PATH="$NOJQ" command -v jq >/dev/null 2>&1 && { echo "shim PATH still resolves jq" >&2; return 1; }
  bash_payload 'gh pr create --fill'
  run --separate-stderr bash -c "cd '$TMP/nogit' && PATH=$NOJQ /bin/bash '$RUN' pr < '$TMP/in.json'"
  [ -z "$output" ]
  run --separate-stderr bash -c "cd '$TMP/nogit' && PATH=$NOJQ STACKUP_AUDIT=1 /bin/bash '$RUN' pr < '$TMP/in.json'"
  echo "$output" | grep -qi 'jq'
}

@test "an unknown mode argument asks nothing" {
  bash_payload 'gh pr create --fill'
  run --separate-stderr bash -c "cd '$TMP/nogit' && bash '$RUN' typo < '$TMP/in.json'"
  [ -z "$output" ]
}

@test "a compound command containing gh stack does not ask" {
  # The bypass only bites on a command that ALSO matches gh pr create; without
  # this the line could be deleted and the suite would stay green.
  bash_payload 'gh stack submit && gh pr create --fill'
  hook pr
  not_asked
}

@test "a prose heading starting with U is not counted as a unit" {
  mkdir -p "$TMP/docs/plans"
  printf '### Understanding the problem\n\nprose only, no units\n' > "$TMP/docs/plans/k-plan.md"
  plan_payload "$TMP/docs/plans/k-plan.md"; hook plan
  asked
}

@test "two remote-less repositories do not share a capability record" {
  mkrepo "$TMP/ra" a.txt b.txt
  mkrepo "$TMP/rb" a.txt b.txt
  record_unavailable_in "$TMP/ra"
  bash_payload 'gh pr create --fill'
  hook_in "$TMP/ra" pr
  [ -z "$output" ]
  bash_payload 'gh pr create --fill'
  hook_in "$TMP/rb" pr
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null
}
