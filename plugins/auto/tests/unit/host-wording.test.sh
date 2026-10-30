#!/usr/bin/env bash
# auto unit test: user-facing text says "space" and "terminal host", never "herdr space" (R20).
#
# The scan has a control: the same grep must flag a scratch file that holds the phrase, so a green
# result proves the scan can fail. The scanned set is every file a user, an agent or a refusal line reads.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

# herdr_space_hits <path...>: file:line of every "herdr space(s)" in the given files and folders.
herdr_space_hits() {
  grep -rniE 'herdr spaces?' --include='*.md' --include='*.py' --include='*.sh' --include='*.ts' "$@" 2>/dev/null \
    | grep -v '\.test\.' | cut -d: -f1,2
}

cd "$ROOT" || exit 1
SCANNED=(commands skills README.md CONCEPTS.md lib mods .claude/hooks docs/programme-overview.md docs/contracts)

it "no user-facing file says herdr space"
HITS="$(herdr_space_hits "${SCANNED[@]}")"
if [ -z "$HITS" ]; then pass; else fail "$HITS"; fi

it "control: the scan flags a file that says herdr space"
mkdir -p "$WORK/commands"
printf 'Start a programme for this herdr space.\n' > "$WORK/commands/control.md"
has "control.md" "$(herdr_space_hits "$WORK/commands")"

it "CONCEPTS.md defines terminal host"
has "**terminal host**" "$(cat CONCEPTS.md)"

it "the resume command says what to do on a host that is not herdr"
has "Rex or Ghostty" "$(cat commands/programme-resume.md)"

it "the programme view shows a herdr space as server.workspace and any other host with its host"
OUT="$(/usr/bin/python3 - "$ROOT/lib" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from _bootstrap import load_lib_module
view = load_lib_module("programme_view")
print(view.remit_texts({"spaces": [{"server": "default", "workspace": "w2"}, {"host": "rex", "server": "s1", "workspace": "w1"}]})[0])
PYEOF
)"
has "spaces: default.w2, rex--s1--w1" "$OUT"

echo ""
echo "host-wording.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
