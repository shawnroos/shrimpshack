#!/usr/bin/env bats
# U1 — registry match/CRUD over routes.json (KTD-1/KTD-2). Each test uses a temp
# LINT_ROUTER_STATE_DIR seeded from seeds/routes.json and real throwaway git repos.

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"   # tools/lint-router/tests
  TOOL_DIR="$(dirname "$TESTS_DIR")"                            # tools/lint-router
  REG="$TOOL_DIR/registry.sh"
  export LINT_ROUTER_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$LINT_ROUTER_STATE_DIR"
  cp "$TOOL_DIR/seeds/routes.json" "$LINT_ROUTER_STATE_DIR/routes.json"
}

# mkrepo <dir> <origin-url> [eslint.config.mjs content]
mkrepo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q >/dev/null 2>&1
  git -C "$d" config user.email t@e.co >/dev/null 2>&1
  git -C "$d" config user.name tester >/dev/null 2>&1
  [ -n "${2:-}" ] && git -C "$d" remote add origin "$2" >/dev/null 2>&1
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$d/eslint.config.mjs"
  printf '%s' "$d"
}

@test "match: @angular-eslint web-app repo -> work + overlay linter applicable" {
  repo="$(mkrepo "$BATS_TEST_TMPDIR/ng" "git@github.com:me/app.git" "import x from '@angular-eslint/x';")"
  run bash "$REG" match "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"profile": "work"'
  echo "$output" | grep -q '"mode": "overlay"'
}

@test "match: plain personal repo -> personal + standalone linter" {
  repo="$(mkrepo "$BATS_TEST_TMPDIR/me" "git@github.com:me/thing.git")"
  run bash "$REG" match "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"profile": "personal"'
  echo "$output" | grep -q '"mode": "standalone"'
}

@test "match: slateteams origin, no angular config -> work matched, NO applicable linter (skip, exit 3)" {
  repo="$(mkrepo "$BATS_TEST_TMPDIR/team" "git@github.com:slateteams/backend.git")"
  run bash "$REG" match "$repo"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q '"profile": "work"'
  echo "$output" | grep -q '"linters": \[\]'
}

@test "add-profile then match picks the new profile by order (before default)" {
  repo="$(mkrepo "$BATS_TEST_TMPDIR/acme" "git@github.com:acme/site.git")"
  run bash "$REG" add-profile '{"name":"acme","when":{"origin":"*acme/*"},"linters":[{"linter":"eslint","mode":"standalone","config":"configs/acme.mjs","files":"\\.ts$"}]}'
  [ "$status" -eq 0 ]
  run bash "$REG" match "$repo"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"profile": "acme"'
}

@test "add-linter appends to a profile; remove drops it" {
  run bash "$REG" add-linter personal '{"linter":"ruff","mode":"standalone","config":"configs/ruff.toml","files":"\\.py$"}'
  [ "$status" -eq 0 ]
  run bash "$REG" list
  echo "$output" | grep -q '"linter": "ruff"'
  run bash "$REG" remove personal.ruff
  [ "$status" -eq 0 ]
  run bash "$REG" list
  ! echo "$output" | grep -q '"linter": "ruff"'
}

@test "malformed routes.json -> clear error, non-zero (never silently mis-routes)" {
  printf 'not json{' > "$LINT_ROUTER_STATE_DIR/routes.json"
  run bash "$REG" match "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'malformed'
}
