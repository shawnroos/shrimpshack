#!/usr/bin/env bash
# Not run by the suite. Regenerating after the agreement consolidation changes any lib file
# replaces the old-shape records with new-shape ones and the compatibility test proves nothing.
set -euo pipefail

FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${FIX_DIR}/../../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
SENTINEL="__AGREEMENT_LEGACY_ROOT__"

if [ -n "$(git -C "$AUTO_ROOT" status --porcelain -- lib)" ]; then
  echo "generate.sh: plugins/auto/lib has uncommitted changes; run on unmodified code only" >&2
  exit 1
fi
SOURCE_SHA="$(git -C "$AUTO_ROOT" rev-list -1 HEAD -- lib)"

WORK="$(cd "$(mktemp -d -t auto-agreement-legacy.XXXXXX)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export HOME="${WORK}/home"
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export PYTHONDONTWRITEBYTECODE=1
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
mkdir -p "$HOME"
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
for tool in board herdr spinoff; do
  printf '#!/bin/sh\nexit 0\n' > "${FAKES}/${tool}"
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
from _bootstrap import load_lib_module
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
args = sys.argv[2:]
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

typed() {
  run_py "$RUN" "$1" <<'EOF'
print(fixture_prompt(args[0], "sess-pm", args[1], "typed")["prompt_id"])
EOF
}

OUT=""
prog() {
  OUT="$("$PY" "$PROG" "$@" --run "$RUN")"
}
field() {
  "$PY" -c 'import json,sys; print(eval(sys.argv[2], {"d": json.loads(sys.argv[1])}))' "$OUT" "$1"
}

prog propose-agreement --project-term "crop defaults=PM picks the crop default" \
  --project-term "prioritisation=use Amplitude" \
  --reserved-term "pricing copy=Shawn writes every price string" --source "repo README"
TERM_OPEN="$(field '[t["id"] for t in d["project_terms"] if t["area"] == "crop defaults"][0]')"
TERM_TOOL="$(field '[t["id"] for t in d["project_terms"] if t["area"] == "prioritisation"][0]')"
TERM_RESERVED="$(field '[t["id"] for t in d["project_terms"] if t["reserved"]][0]')"
prog accept-agreement --prompt "$(typed 'yes, I accept the agreement')"
prog set-source tracker --available --provider board

for item in herdr:browser-e2e herdr:docs-page herdr:linux-probe; do
  prog add-item "$item" --title "$item" --kind fix_only
done

prog record-instruction --prompt "$(typed 'keep every PR under 300 lines')"
INSTR_PLAIN="$(field 'd["instruction"]')"
prog record-instruction --prompt "$(typed 'waive the full eval for herdr:docs-page')" \
  --applies-to herdr:docs-page --until merged
INSTR_WAIVER="$(field 'd["instruction"]')"

prog record-decision d-browser --scope "ship the browser fix" --reason "customers hit the broken flow" \
  --limit "no prod flag changes" --applies-to herdr:browser-e2e \
  --prompt "$(typed 'record decision d-browser: ship the browser fix, no prod flag changes')"
prog assign-item herdr:browser-e2e --decision-id d-browser
prog define-requirement r-browser --text "the browser flow passes at runtime" \
  --check herdr:browser-e2e=verified --decision-id d-browser \
  --prompt "$(typed 'requirement r-browser: the browser flow passes its runtime check')"

prog record-decision d-docs --scope "fix the docs page" --reason "stale install steps" \
  --applies-to herdr:docs-page --prompt "$(typed 'record decision d-docs for docs-page')"
prog record-decision d-docs --scope "fix the docs page" --reason "stale install steps" \
  --applies-to herdr:docs-page --applies-to herdr:linux-probe \
  --prompt "$(typed 'widen d-docs to linux-probe too')"
[ "$(field 'd["state"]')" = pending_acceptance ]

prog propose-rule '{"id":"docs-verified","applies_when":{"change_kinds":["evals_or_docs"]},"requires":["merged","verified"],"evidence_bar":{"merged":"merged at the gate","verified":"checked at runtime"},"caveat":"","autonomy":"act_and_tell","added_by":"pm","added_at":"2026-10-06T10:00:00Z","why":"docs need a runtime check"}'
prog adopt-rule docs-verified --prompt "$(typed 'yes adopt docs-verified')"
prog adopt-autonomy prod_deploy never --prompt "$(typed 'yes, set prod_deploy to never')"

rm -rf "${FIX_DIR}/prompt-fixtures" "${FIX_DIR}/personal"
"$PY" - "$WORK" "$FIX_DIR" "$RUN" "$SENTINEL" "$SOURCE_SHA" \
  "$INSTR_PLAIN" "$INSTR_WAIVER" "$TERM_OPEN" "$TERM_RESERVED" "$TERM_TOOL" <<'PYEOF'
import glob, json, os, sqlite3, sys
work, out, run, sentinel, sha, instr_plain, instr_waiver, term_open, term_reserved, term_tool = sys.argv[1:]

def export(text):
    return text.replace(work, sentinel)

dump = export("\n".join(sqlite3.connect(os.path.join(work, "data", "programmes", run, "programme.db")).iterdump()))
with open(os.path.join(out, "programme.sql"), "w") as fh:
    fh.write(dump + "\n")
copied = [os.path.join("personal", "protocol.json")]
copied += sorted(os.path.relpath(p, work) for p in glob.glob(os.path.join(work, "prompt-fixtures", "*", "*.jsonl")))
for rel in copied:
    os.makedirs(os.path.dirname(os.path.join(out, rel)), exist_ok=True)
    with open(os.path.join(work, rel)) as src, open(os.path.join(out, rel), "w") as dst:
        dst.write(export(src.read()))
manifest = {"lib_commit": sha, "sentinel": sentinel, "sentinel_count_in_sql": dump.count(sentinel),
            "run": run, "machine": os.environ["CLAUDE_AUTO_MACHINE"], "session": os.environ["CLAUDE_CODE_SESSION_ID"],
            "instructions": {"plain": instr_plain, "waiver": instr_waiver},
            "project_terms": {"open": term_open, "reserved": term_reserved, "preferred_tool": term_tool},
            "decisions": ["d-browser", "d-docs"], "requirement": "r-browser",
            "personal": {"rule": "docs-verified", "autonomy": "prod_deploy"}, "files": copied}
with open(os.path.join(out, "manifest.json"), "w") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
    fh.write("\n")
PYEOF
echo "generate.sh: wrote ${FIX_DIR} from ${SOURCE_SHA} (run ${RUN})"
