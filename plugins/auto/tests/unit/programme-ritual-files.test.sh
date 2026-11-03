#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "programme-ritual-files.test.sh"

WORK="$(mktemp -d -t auto-ritual-files.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export TZ=UTC
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_CARRYOVER_STORE="${WORK}/personal/carryover.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_RITUALS_STORE="${WORK}/stores/rituals.json"
unset CLAUDE_AUTO_BEHAVIOURS_STORE HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
export WORK

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import datetime, hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
pr = load_lib_module("programme_rituals")
due = load_lib_module("programme_rituals_due")
args = sys.argv[2:]
UTC = datetime.timezone.utc
def at(text):
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")
def record(run):
    return core.read_run_record(ph.home_path(run), run)
def ritual(rid, layer="programme", **kw):
    entry = {"id": rid, "layer": layer, "state": "active", "at": "2026-11-01T00:00:00Z",
             "when": {"text": "every Monday", "trigger": "calendar",
                      "schedule": {"every": "week", "weekday": 0, "at": "09:00"}},
             "steps": ["report what drifted"]}
    if layer == "repo":
        entry["repo_key"] = "acme/alpha"
    entry.update(kw)
    return entry
def event_ritual(rid, trigger="handover", **kw):
    return ritual(rid, when={"text": "at handover", "trigger": trigger}, **kw)
def setup(rituals, clock=None):
    counter = os.path.join(os.environ["WORK"], "spaces")
    n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
    open(counter, "w").write(str(n))
    run = ph.create_programme(["w%d" % n], "sess-pm")["run"]
    def mutate(rec):
        rec["programme"]["rituals"] = rituals
        rec["programme"]["ritual_clock"] = clock or {}
    core._with_locked_run_record(ph.home_path(run), run, mutate)
    return run
def jrow(kind, when, **payload):
    return {"kind": kind, "at": when, "payload": payload}
def states(result):
    return sorted("%s:%s" % (r["ritual"], r["state"]) for b in ("due", "missed", "in_flight") for r in result[b])
def prompt_for(run, text):
    row = fixture_prompt(run, "sess-pm", text)
    return {"prompt_id": row["prompt_id"], "quote": text,
            "text_hash": "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()}
$(cat)
PYEOF
}

PROG="${AUTO_ROOT}/lib/programme.py"
OUT=""
CODE=0
prog() { OUT="$("$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
new_run() {
  run_py <<'EOF'
print(setup([]))
EOF
}
tprompt() {
  run_py "$1" "$2" "${3:-typed}" <<'EOF'
print(fixture_prompt(args[0], "sess-pm", args[1], args[2])["prompt_id"])
EOF
}
q() {
  run_py "$1" "$2" <<'EOF'
run, expr = args
rec = record(run)
prog = rec["programme"]
def kinds():
    return [r["kind"] for r in pj.read(run)]
def count(kind):
    return kinds().count(kind)
print(eval(expr))
EOF
}
jfield() { "$PY" -c 'import json,sys; d=json.loads(sys.argv[1].splitlines()[-1]); print(eval(sys.argv[2]))' "$1" "$2" 2>&1; }

GITENV=(-c user.name=t -c user.email=t@t)
FILE_OK='---
when: every morning
schedule: daily 09:00
check: versions-bumped
---
Steps:
- check the plugin versions
Offers:
- ask Shawn whether to publish the plugin now
'
# mkrepo NAME: a bare origin plus a clone whose origin/HEAD is set, one committed ritual file pushed to origin/main.
mkrepo() {
  local name="$1" file="${2:-plugin-versions.md}" text="${3-$FILE_OK}"
  git init -q --bare -b main "${WORK}/${name}.git"
  git clone -q "${WORK}/${name}.git" "${WORK}/${name}" 2>/dev/null
  git -C "${WORK}/${name}" checkout -q -b main 2>/dev/null
  mkdir -p "${WORK}/${name}/plugins/foo/.claude-plugin" "${WORK}/${name}/.claude-plugin" "${WORK}/${name}/.auto/rituals"
  printf '{"name": "foo", "version": "1.0.0"}' > "${WORK}/${name}/plugins/foo/.claude-plugin/plugin.json"
  printf '{"plugins": [{"name": "foo", "version": "1.0.0"}]}' > "${WORK}/${name}/.claude-plugin/marketplace.json"
  [ -n "$file" ] && printf '%s' "$text" > "${WORK}/${name}/.auto/rituals/${file}"
  git -C "${WORK}/${name}" add -A
  git -C "${WORK}/${name}" "${GITENV[@]}" commit -q -m initial
  git -C "${WORK}/${name}" push -q origin main 2>/dev/null
  git -C "${WORK}/${name}" fetch -q origin 2>/dev/null
  git -C "${WORK}/${name}" remote set-head origin main >/dev/null 2>&1
}
push_file() { # name file text: commit a new version of a ritual file and push it to origin/main
  printf '%s' "$3" > "${WORK}/$1/.auto/rituals/$2"
  git -C "${WORK}/$1" add -A
  git -C "${WORK}/$1" "${GITENV[@]}" commit -q -m "edit $2"
  git -C "${WORK}/$1" push -q origin main 2>/dev/null
}
files_run() { # name -> a programme whose remit is that clone, key acme/<name>
  run_py "$1" <<'EOF'
name = args[0]
run = setup([])
def mutate(rec):
    rec["programme"]["remit"]["repos"] = [{"path": os.path.join(os.environ["WORK"], name), "github": "acme/" + name}]
core._with_locked_run_record(ph.home_path(run), run, mutate)
print(run)
EOF
}
fview() { # run -> JSON of the file-ritual states resolve reports
  run_py "$1" <<'EOF'
rec = record(args[0])
got = pr.resolve(rec)
fr = got["file_rituals"]
print(json.dumps({"in_force": sorted(e["id"] for e in got["in_force"]),
                  "proposals": sorted((p["id"], p["state"]) for p in fr["proposals"]),
                  "adopted": sorted((a["id"], a["state"]) for a in fr["adopted"]),
                  "rejected": sorted((r["id"], r["reason"]) for r in got["rejected"]),
                  "notices": got["notices"]}, sort_keys=True))
EOF
}
fh() { # run -> short hash of the first proposal
  run_py "$1" <<'EOF'
rec = record(args[0])
print(pr.resolve(rec)["file_rituals"]["proposals"][0]["hash_short"])
EOF
}

mkrepo r1
RUN1="$(files_run r1)"

it "F1: a committed ritual file on origin/HEAD is proposed, not in force"
check '{"adopted": [], "in_force": [], "notices": [], "proposals": [["plugin-versions", "proposed"]], "rejected": []}' "$(fview "$RUN1")"

it "F2: an uncommitted edit, a new local branch and an unpushed local commit change nothing (same hash as before)"
HBEFORE="$(fh "$RUN1")"
printf '%s' "---
when: edited
schedule: daily 10:00
---
Steps:
- do something else
" > "${WORK}/r1/.auto/rituals/plugin-versions.md"
printf 'x' > "${WORK}/r1/.auto/rituals/uncommitted.md"
git -C "${WORK}/r1" checkout -q -b worker
git -C "${WORK}/r1" add -A
git -C "${WORK}/r1" "${GITENV[@]}" commit -q -m "worker edit"
check '{"adopted": [], "in_force": [], "notices": [], "proposals": [["plugin-versions", "proposed"]], "rejected": []}' "$(fview "$RUN1")"
check "$HBEFORE" "$(fh "$RUN1")"
git -C "${WORK}/r1" checkout -q main
git -C "${WORK}/r1" "${GITENV[@]}" merge -q worker 2>/dev/null
check "$HBEFORE" "$(fh "$RUN1")"
git -C "${WORK}/r1" reset -q --hard origin/main

it "F2b: an origin/HEAD that does not resolve is a visible notice, with no fallback to local main"
mkrepo r2
git -C "${WORK}/r2" remote set-head origin -d >/dev/null 2>&1
RUN2="$(files_run r2)"
check "True True" "$(run_py "$RUN2" <<'EOF'
got = pr.resolve(record(args[0]))
print(got["file_rituals"]["proposals"] == [], any("origin/HEAD" in n for n in got["notices"]))
EOF
)"

it "F3: a symlinked rituals folder and a symlinked file are never read"
mkrepo r3 ""
rm -rf "${WORK}/r3/.auto/rituals"
mkdir -p "${WORK}/r3/real"; printf '%s' "$FILE_OK" > "${WORK}/r3/real/plugin-versions.md"
ln -s ../real "${WORK}/r3/.auto/rituals"
git -C "${WORK}/r3" add -A; git -C "${WORK}/r3" "${GITENV[@]}" commit -q -m "symlinked folder"; git -C "${WORK}/r3" push -q origin main 2>/dev/null
RUN3="$(files_run r3)"
check "[]" "$(fview "$RUN3" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["proposals"]))')"
mkrepo r4 ""
ln -s /etc/hosts "${WORK}/r4/.auto/rituals/linked.md"
git -C "${WORK}/r4" add -A; git -C "${WORK}/r4" "${GITENV[@]}" commit -q -m "symlinked file"; git -C "${WORK}/r4" push -q origin main 2>/dev/null
RUN4="$(files_run r4)"
check "[[\"linked\", \"bad_value\"]]" "$(fview "$RUN4" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["rejected"]))')"

it "F3b: a gitlink named like a ritual file is rejected, never read"
mkrepo r10 ""
git -C "${WORK}/r10" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,.auto/rituals/sub.md
git -C "${WORK}/r10" "${GITENV[@]}" commit -q -m "gitlink"; git -C "${WORK}/r10" push -q origin main 2>/dev/null
RUN10="$(files_run r10)"
check "[[\"sub\", \"bad_value\"]]" "$(fview "$RUN10" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["rejected"]))')"

it "F4: a bad file is a rejected row naming the id and the reason, and never stops the others"
mkrepo r5 "bad.md" "---
when: x
bogus: 1
---
Steps:
- y
"
push_file r5 "good.md" "$FILE_OK"
RUN5="$(files_run r5)"
check '{"adopted": [], "in_force": [], "notices": ["ritual file acme/r5/bad.md rejected: unknown_key (bogus)"], "proposals": [["good", "proposed"]], "rejected": [["bad", "unknown_key"]]}' "$(fview "$RUN5")"

it "F4b: a protected step in a file is rejected, an offer naming it is fine, a check outside the list is rejected"
mkrepo r6 "step.md" "---
when: x
schedule: daily 09:00
---
Steps:
- publish the plugin
"
push_file r6 "offer.md" "---
when: x
schedule: daily 09:00
---
Steps:
- look at the versions
Offers:
- ask whether to publish
"
push_file r6 "check.md" "---
when: x
schedule: daily 09:00
check: rm-everything
---
Steps:
- look
"
RUN6="$(files_run r6)"
check '[["check", "bad_value"], ["step", "protected_escalation"]]' "$(fview "$RUN6" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["rejected"]))')"
check '[["offer", "proposed"]]' "$(fview "$RUN6" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["proposals"]))')"

it "F4c: the ritual file this repo ships is valid, its check is in the list, and the ask is an offer"
EXAMPLE_DIR="${AUTO_ROOT}/../../.auto/rituals"
if [ -d "$EXAMPLE_DIR" ]; then
  check "plugin-versions-bumped versions-bumped True" "$(run_py "${EXAMPLE_DIR}/plugin-versions-bumped.md" <<'EOF'
prf = load_lib_module("programme_ritual_files")
e = prf.parse_text(open(args[0]).read(), "plugin-versions-bumped", "shawnroos/shrimpshack")
print(e["id"], e["check"]["name"], "publish" not in " ".join(e["steps"]) and bool(e["offers"]))
EOF
)"
else
  echo "  skipped: .auto/rituals is not above the plugin folder (an installed copy)"; pass
fi

# ---- adoption by content hash ----
it "F5: adopt-ritual-file needs typed words naming the id, the check and the hash, and puts it in force"
H1="$(fh "$RUN1")"
P_NO="$(tprompt "$RUN1" "adopt plugin-versions")"
prog adopt-ritual-file acme/r1/plugin-versions --prompt "$P_NO" --run "$RUN1"
check 1 "$CODE"
has "does not name" "$OUT"
P_NOHASH="$(tprompt "$RUN1" "adopt plugin-versions with the versions bumped check")"
prog adopt-ritual-file acme/r1/plugin-versions --prompt "$P_NOHASH" --run "$RUN1"
check 1 "$CODE"
has "${H1}" "$OUT"
P_OK="$(tprompt "$RUN1" "adopt plugin-versions ${H1} with the versions bumped check")"
prog adopt-ritual-file acme/r1/plugin-versions --prompt "$P_OK" --run "$RUN1"
check 0 "$CODE"
check '{"adopted": [["plugin-versions", "adopted"]], "in_force": ["plugin-versions"], "notices": [], "proposals": [], "rejected": []}' "$(fview "$RUN1")"

it "F5b: a prompt that names the id and hash but not the check is refused for a file that carries a check"
mkrepo r11
RUN11="$(files_run r11)"
H11="$(fh "$RUN11")"
P_NOCHK="$(tprompt "$RUN11" "adopt plugin-versions ${H11}")"
prog adopt-ritual-file acme/r11/plugin-versions --prompt "$P_NOCHK" --run "$RUN11"
check 1 "$CODE"
has "versions bumped" "$OUT"
check '{"adopted": [], "in_force": [], "notices": [], "proposals": [["plugin-versions", "proposed"]], "rejected": []}' "$(fview "$RUN11")"

it "F5c: the adopted ritual is a repo-layer ritual with its repo key and check, and it counts as a file ritual"
check "repo acme/r1 versions-bumped" "$(run_py "$RUN1" <<'EOF'
e = [e for e in pr.in_force(record(args[0])) if e["id"] == "plugin-versions"][0]
print(e["layer"], e["repo_key"], e["check"]["name"])
EOF
)"

it "F6: a prompt that names a stale hash is refused"
mkrepo r7
RUN7="$(files_run r7)"
HOLD="$(fh "$RUN7")"
push_file r7 "plugin-versions.md" "---
when: changed
schedule: daily 09:00
---
Steps:
- a different step
"
P_STALE="$(tprompt "$RUN7" "adopt plugin-versions ${HOLD} with the versions bumped check")"
prog adopt-ritual-file acme/r7/plugin-versions --prompt "$P_STALE" --run "$RUN7"
check 1 "$CODE"
has "changed since" "$OUT"

it "F7: a changed file proposes again while the adopted snapshot stays in force"
push_file r1 "plugin-versions.md" "---
when: every morning, new wording
schedule: daily 09:00
check: versions-bumped
---
Steps:
- check the plugin versions again
"
check '{"adopted": [["plugin-versions", "changed_since_adoption"]], "in_force": ["plugin-versions"], "notices": [], "proposals": [["plugin-versions", "changed"]], "rejected": []}' "$(fview "$RUN1")"
check "check the plugin versions" "$(run_py "$RUN1" <<'EOF'
print([e for e in pr.in_force(record(args[0])) if e["id"] == "plugin-versions"][0]["steps"][0])
EOF
)"

it "F8: declining takes the ritual out of force, and a changed file proposes it again"
H2="$(fh "$RUN1")"
P_DEC="$(tprompt "$RUN1" "decline plugin-versions ${H2}")"
prog decline-ritual-file acme/r1/plugin-versions --prompt "$P_DEC" --run "$RUN1"
check 0 "$CODE"
check '{"adopted": [], "in_force": [], "notices": [], "proposals": [], "rejected": []}' "$(fview "$RUN1")"
push_file r1 "plugin-versions.md" "---
when: third wording
schedule: daily 09:00
---
Steps:
- yet another step
"
check '[["plugin-versions", "proposed"]]' "$(fview "$RUN1" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["proposals"]))')"

# ---- collisions ----
it "F9: a file whose id matches a personal ritual or another repo's file is rejected and the established ritual stays"
mkrepo r8
mkrepo r9
RUN89="$(run_py <<'EOF'
run = setup([ritual("plugin-versions", layer="programme")])
def mutate(rec):
    rec["programme"]["remit"]["repos"] = [{"path": os.path.join(os.environ["WORK"], "r8"), "github": "acme/r8"},
                                          {"path": os.path.join(os.environ["WORK"], "r9"), "github": "acme/r9"}]
core._with_locked_run_record(ph.home_path(run), run, mutate)
print(run)
EOF
)"
check '[["plugin-versions", "id_collision"], ["plugin-versions", "id_collision"]]' "$(fview "$RUN89" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["rejected"]))')"
check '["plugin-versions"]' "$(fview "$RUN89" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["in_force"]))')"

it "F9b: the due digest lists proposed files so the PM can put them to Shawn"
check "[('plugin-versions', 'proposed')]" "$(run_py "$RUN11" <<'EOF'
d = due.due(record(args[0]), args[0])
print([(p["ritual"], p["state"]) for p in d["file_proposals"]])
EOF
)"

it "F10: the Programme view shows the layer, the commit, the age of the clone and the adoption state"
RUNV="$(files_run r5)"
check "True" "$(run_py "$RUNV" <<'EOF'
pv = load_lib_module("programme_view")
rows = pv.rituals_view(record(args[0]), [])
good = [r for r in rows if r["id"] == "good"][0]
text = pv._ritual_text(good)
print("repo (file)" in text and "proposed" in text and good["file"]["commit"][:7] in text and "clone last fetched" in text)
EOF
)"

# ---- code review round 1 ----
adopted_run() { # name -> a programme that has adopted <name>'s plugin-versions file
  local run hash prompt
  run="$(files_run "$1")"
  hash="$(fh "$run")"
  prompt="$(tprompt "$run" "adopt plugin-versions ${hash} with the versions bumped check")"
  prog adopt-ritual-file "acme/$1/plugin-versions" --prompt "$prompt" --run "$run"
  echo "$run"
}
snapshot() { # run -> in_force ids and adopted states, as the resolver reports them
  run_py "$1" <<'EOF'
got = pr.resolve(record(args[0]))
print(sorted(e["id"] for e in got["in_force"]), sorted((a["id"], a["state"]) for a in got["file_rituals"]["adopted"]))
EOF
}

it "G1: a git read that fails part-way keeps the adopted snapshot in force as unread"
mkrepo g1
RUNG1="$(adopted_run g1)"
check "['plugin-versions'] [('plugin-versions', 'unread')]" "$(run_py "$RUNG1" <<'EOF'
prf = load_lib_module("programme_ritual_files")
checks = prf.programme_ritual_checks
orig = checks._Repo.run
def broken(self, argv, **kw):
    if argv[0] == "cat-file":
        raise checks._Stop("timeout")
    return orig(self, argv, **kw)
checks._Repo.run = broken
prf.invalidate()
got = pr.resolve(record(args[0]))
print(sorted(e["id"] for e in got["in_force"]), sorted((a["id"], a["state"]) for a in got["file_rituals"]["adopted"]))
EOF
)"

it "G2: an adopted file that turns invalid stays in force as unverified, and the bad content is a rejected row"
mkrepo g2
RUNG2="$(adopted_run g2)"
push_file g2 "plugin-versions.md" "---
when: x
bogus: 1
---
Steps:
- y
"
check "['plugin-versions'] [('plugin-versions', 'unverified')]" "$(snapshot "$RUNG2")"
check '[["plugin-versions", "unknown_key"]]' "$(fview "$RUNG2" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["rejected"]))')"

it "G3: another repo shipping the same id does not switch off the adopted ritual"
mkrepo g3a
RUNG3="$(adopted_run g3a)"
mkrepo g3b
run_py "$RUNG3" <<'EOF'
def mutate(rec):
    rec["programme"]["remit"]["repos"].append({"path": os.path.join(os.environ["WORK"], "g3b"), "github": "acme/g3b"})
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
check "['plugin-versions'] [('plugin-versions', 'adopted')]" "$(snapshot "$RUNG3")"
check '[["plugin-versions", "id_collision"]]' "$(fview "$RUNG3" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["rejected"]))')"

it "G4: a folder over the file cap keeps the adopted snapshot as unverified"
mkrepo g4
RUNG4="$(adopted_run g4)"
push_file g4 "second.md" "$FILE_OK"
check "['plugin-versions'] [('plugin-versions', 'unverified')]" "$(run_py "$RUNG4" <<'EOF'
prf = load_lib_module("programme_ritual_files")
prf.MAX_FILES = 1
prf.invalidate()
got = pr.resolve(record(args[0]))
print(sorted(e["id"] for e in got["in_force"]), sorted((a["id"], a["state"]) for a in got["file_rituals"]["adopted"]))
EOF
)"

it "G5: the hash a prompt must name is 20 characters, and the view names the default branch it was read from"
check "20 refs/remotes/origin/main" "$(run_py "$RUN11" <<'EOF'
row = pr.resolve(record(args[0]))["file_rituals"]["proposals"][0]
print(len(row["hash_short"]), row["file"]["ref"])
EOF
)"
check "True" "$(run_py "$RUN11" <<'EOF'
pv = load_lib_module("programme_view")
rows = pv.rituals_view(record(args[0]), [])
print("refs/remotes/origin/main" in pv._ritual_text([r for r in rows if r["id"] == "plugin-versions"][0]))
EOF
)"

it "G6: an adopted ritual whose repo has left the remit is out of force"
mkrepo g6
RUNG6="$(adopted_run g6)"
run_py "$RUNG6" <<'EOF'
def mutate(rec):
    rec["programme"]["remit"]["repos"] = []
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
check "[] []" "$(snapshot "$RUNG6")"

it "G7: a file named with spaces or capitals is rejected under a safe label, never its raw name"
mkrepo g7 "Bad Name.md" "x"
RUNG7="$(files_run g7)"
check '[["<unnamed file>", "bad_value"]]' "$(fview "$RUNG7" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["rejected"]))')"

it "G8: an adoption record whose snapshot is no longer valid, or has none, never takes the resolver down"
mkrepo g8
RUNG8="$(adopted_run g8)"
run_py "$RUNG8" <<'EOF'
def mutate(rec):
    a = rec["programme"]["ritual_adoptions"]["acme/g8/plugin-versions"]
    a["snapshot"]["steps"] = ["publish the plugin"]
    rec["programme"]["ritual_adoptions"]["acme/g8/ghost"] = {"state": "adopted", "hash": "0" * 64}
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
check "[] []" "$(snapshot "$RUNG8")"
check "True True" "$(fview "$RUNG8" | python3 -c 'import json,sys; r = [x[1] for x in json.load(sys.stdin)["rejected"]]; print("protected_escalation" in r, "adoption_malformed" in r)')"

it "G9: two programmes in one process that list one path under different keys each see their own key"
check "acme/g9 /" "$(run_py <<'EOF'
mkp = lambda repo: {"remit": {"repos": [repo]}, "ritual_adoptions": {}}
path = os.path.join(W, "g9") if False else os.path.join(os.environ["WORK"], "r1")
a = pr.resolve({"programme": mkp({"path": path, "github": "acme/g9"})})["file_rituals"]["proposals"]
b = pr.resolve({"programme": mkp({"path": path})})["file_rituals"]["proposals"]
print(a[0]["repo_key"], "/" if b[0]["repo_key"].startswith("/") else b[0]["repo_key"])
EOF
)"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
