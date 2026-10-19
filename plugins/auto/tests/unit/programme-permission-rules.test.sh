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
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-permission-rules.test.sh"

WORK="$(mktemp -d -t auto-permission-rules.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
pr = load_lib_module("programme_permission_rules")
args = sys.argv[2:]
$(cat)
PYEOF
}

elig() {
  run_py "$1" <<'EOF'
r = pr.eligibility(args[0])
if r["eligible"]:
    calls = ";".join(f"{c['op']}={c['target']}" for c in r["calls"])
    print(f"ok|{','.join(r['operations'])}|{r['normalized']}|{calls}")
else:
    print(f"no|{r['kind']}|{r['subject']}")
EOF
}

cover() {
  run_py "$1" "${2:-[]}" "${3:-[]}" "${4:-[]}" "${5:-}" <<'EOF'
cmd, allow, ask, deny, classify = args
r = pr.coverage(cmd, json.loads(allow), json.loads(ask), json.loads(deny), classify_all_shell=bool(classify))
print(f"{r['outcome']}|{r['rule']}|{r['source']}|{r['layer']}|{r['note']}")
EOF
}

it "gh pr checks 12 is eligible as pr_checks with target 12"
check "ok|pr_checks|gh pr checks 12|pr_checks=12" "$(elig 'gh pr checks 12')"

it "gh pr view 12 --json statusCheckRollup is eligible as pr_view"
check "ok|pr_view|gh pr view 12 --json statusCheckRollup|pr_view=12" "$(elig 'gh pr view 12 --json statusCheckRollup')"

it "gh run view 5 --json jobs is eligible as run_view"
check "ok|run_view|gh run view 5 --json jobs|run_view=5" "$(elig 'gh run view 5 --json jobs')"

it "gh run list -L 5 --branch main is eligible as run_list, short flag normalized"
check "ok|run_list|gh run list --limit 5 --branch main|run_list=None" "$(elig 'gh run list -L 5 --branch main')"

it "--json=fields normalizes to the spaced form and extra spaces collapse"
check "ok|pr_checks|gh pr checks 7 --json name,state|pr_checks=7" "$(elig 'gh  pr checks 7 --json=name,state')"

it "gh pr checks with no number is eligible with no target"
check "ok|pr_checks|gh pr checks|pr_checks=None" "$(elig 'gh pr checks')"

it "gh pr checks 12 | head -5 is eligible because head is built-in read-only"
check "ok|pr_checks|gh pr checks 12 | head -5|pr_checks=12" "$(elig 'gh pr checks 12 | head -5')"

it "two catalog reads chained give both operation ids"
check "ok|pr_checks,pr_view|gh pr view 3 && gh pr checks 3|pr_view=3;pr_checks=3" "$(elig 'gh pr view 3 && gh pr checks 3')"

it "gh pr view 12 | jq .x is ineligible and names jq"
check "no|not_catalogued|jq" "$(elig 'gh pr view 12 | jq .x')"

it "gh pr merge 12 is ineligible and names gh pr merge"
check "no|not_catalogued|gh pr merge" "$(elig 'gh pr merge 12')"

it "gh pr checks 1 && gh pr merge 1 is ineligible and names gh pr merge"
check "no|not_catalogued|gh pr merge" "$(elig 'gh pr checks 1 && gh pr merge 1')"

it "a built-in only command has no catalog operation"
check "no|not_catalogued|no catalog operation" "$(elig 'ls && pwd')"

for cmd in 'gh pr checks 12 --repo o/r' 'gh pr checks -R o/r 12' 'GH_REPO=o/r gh pr checks' \
           'GH_TOKEN=x gh pr checks 12' 'GH_HOST=h gh pr checks 12' 'cd ../x && gh pr checks' \
           'gh pr checks $(cat n)' 'gh pr checks 12 > out' 'gh pr checks 12 # note' \
           'gh pr checks `cat n`' "gh pr checks '12'" 'gh -R o/r pr checks 12' 'gh pr checks 12 2>&1' \
           'gh pr checks 12 &&' 'gh pr checks 12 ; ; ls' 'gh pr checks 12 13' 'gh pr checks abc' \
           'gh pr checks 12 -C dir' 'gh run list --json' '(gh pr checks 12)' 'gh pr checks 12 | tail -f'; do
  it "ineligible: $cmd"
  has "no|" "$(elig "$cmd")"
done

it "an environment prefix is named as such"
check "no|unknown_scope|environment prefix GH_TOKEN" "$(elig 'GH_TOKEN=x gh pr checks 12')"

it "cd is named"
check "no|unknown_scope|cd" "$(elig 'cd ../x && gh pr checks')"

it "--repo is named"
check "no|unknown_scope|--repo" "$(elig 'gh pr checks 12 --repo o/r')"

it "a subshell is named"
check "no|unknown_scope|subshell" "$(elig 'gh pr checks $(cat n)')"

it "a redirection is named"
check "no|unknown_scope|redirection" "$(elig 'gh pr checks 12 > out')"

it "a comment is named"
check "no|unknown_scope|comment" "$(elig 'gh pr checks 12 # note')"

it "gh run view 5 --log is ineligible and names the flag"
check "no|unlisted_flag|--log" "$(elig 'gh run view 5 --log')"

it "gh run view 5 --log-failed is ineligible and names the flag"
check "no|unlisted_flag|--log-failed" "$(elig 'gh run view 5 --log-failed')"

it "gh pr view 12 --web is ineligible and names the flag"
check "no|unlisted_flag|--web" "$(elig 'gh pr view 12 --web')"

it "gh pr checks 12 --watch is ineligible and names the flag"
check "no|unlisted_flag|--watch" "$(elig 'gh pr checks 12 --watch')"

it "a bidi override character makes a command ineligible"
check "no|unknown_scope|control character" "$(elig "$(printf 'gh pr checks 12\342\200\256')")"

it "an escape control character makes a command ineligible"
check "no|unknown_scope|control character" "$(elig "$(printf 'gh pr checks 12\033[2K')")"

it "a newline splits subcommands like ;"
check "ok|pr_checks|gh pr checks 1 ; wc -l|pr_checks=1" "$(elig "$(printf 'gh pr checks 1\nwc -l')")"

it "a non-string or empty command is ineligible"
check "no|unknown_scope|empty command" "$(elig '')"

it "AE1: the pr_checks allow covers gh pr checks 12"
check "covered|Bash(gh pr checks *)|None|allow|" "$(cover 'gh pr checks 12' '["Bash(gh pr checks *)"]')"

it "AE1: the pr_checks allow does not cover gh pr checks 12 && gh pr merge 12"
has "not_covered|" "$(cover 'gh pr checks 12 && gh pr merge 12' '["Bash(gh pr checks *)"]')"

it "an uncovered subcommand is named in the note"
has "gh pr merge 12" "$(cover 'gh pr checks 12 && gh pr merge 12' '["Bash(gh pr checks *)"]')"

it "a built-in read-only pipe stage needs no allow rule"
check "covered|Bash(gh pr checks *)|None|allow|" "$(cover 'gh pr checks 12 | head -5' '["Bash(gh pr checks *)"]')"

it "each catalog rule covers its own operation"
out=""
for c in 'gh pr view 1 --json state|Bash(gh pr view *)' 'gh run view 5|Bash(gh run view *)' 'gh run list --limit 3|Bash(gh run list *)'; do
  out="${out}$(cover "${c%%|*}" "[\"${c#*|}\"]" | cut -d'|' -f1),"
done
check "covered,covered,covered," "$out"

it "every eligible normalized command, bare forms included, is covered by its own catalog rule"
check "ok" "$(run_py <<'EOF'
bad = []
for cmd in ["gh pr checks", "gh run list", "gh pr view", "gh pr checks 12", "gh pr view 3 --json state",
            "gh run view 5 --verbose", "gh run list --limit 2"]:
    e = pr.eligibility(cmd)
    rules = [pr.CATALOG[op]["rule"] for op in e["operations"]]
    if pr.coverage(e["normalized"], rules)["outcome"] != "covered":
        bad.append(cmd)
print("ok" if not bad else bad)
EOF
)"

it "an environment-prefixed command is never covered, even by Bash"
has "not_covered|" "$(cover 'GH_TOKEN=x gh pr checks 12' '["Bash", "Bash(*)", "Bash(GH_TOKEN=x gh pr checks 12)"]')"

it "the env-prefix refusal names the prefix"
has "environment prefix" "$(cover 'GH_TOKEN=x gh pr checks 12' '["Bash(*)"]')"

it "a broader covering rule Bash(gh *) covers with a reach note"
r="$(cover 'gh pr checks 12' '["Bash(gh *)"]')"
has "covered|Bash(gh *)|" "$r"
has "reaches more than Bash(gh pr checks *)" "$r"

it "a bare Bash allow covers with a reach note"
has "reaches more than" "$(cover 'gh pr checks 12' '["Bash"]')"

it "the exact catalog rule carries no reach note"
lacks "reaches more" "$(cover 'gh pr checks 12' '["Bash(gh *)", "Bash(gh pr checks *)"]')"

it "a deny rule Bash(gh pr checks *) gives blocked_elsewhere naming it"
has "blocked_elsewhere|Bash(gh pr checks *)|None|deny" "$(cover 'gh pr checks 12' '["Bash(gh pr checks *)"]' '[]' '["Bash(gh pr checks *)"]')"

it "an ask rule matching the command gives blocked_elsewhere naming it"
has "blocked_elsewhere|Bash(gh pr:*)|None|ask" "$(cover 'gh pr checks 12' '["Bash(gh pr checks *)"]' '["Bash(gh pr:*)"]')"

it "deny wins over ask"
has "blocked_elsewhere|Bash(gh *)|None|deny" "$(cover 'gh pr checks 12' '[]' '["Bash(gh pr:*)"]' '["Bash(gh *)"]')"

it "a deny on any subcommand blocks the compound command"
has "blocked_elsewhere|Bash(head *)" "$(cover 'gh pr checks 12 | head -5' '["Bash(gh pr checks *)"]' '[]' '["Bash(head *)"]')"

it "a deny rule matches the env-stripped subcommand"
has "blocked_elsewhere|Bash(gh pr checks *)" "$(cover 'GH_TOKEN=x gh pr checks 12' '[]' '[]' '["Bash(gh pr checks *)"]')"

it "a rule with its source file reports the file"
has "blocked_elsewhere|Bash(gh pr checks *)|/u/settings.json|deny" "$(cover 'gh pr checks 12' '[]' '[]' '[["Bash(gh pr checks *)", "/u/settings.json"]]')"

it "autoMode.classifyAllShell gives blocked_elsewhere"
has "blocked_elsewhere|autoMode.classifyAllShell|None|classifier" "$(cover 'gh pr checks 12' '["Bash(gh pr checks *)"]' '[]' '[]' 1)"

it "an allow written as Bash(gh pr checks:*) counts the same as Bash(gh pr checks *)"
check "covered|Bash(gh pr checks:*)|None|allow|" "$(cover 'gh pr checks 12' '["Bash(gh pr checks:*)"]')"

it "an empty allow list gives not_covered"
has "not_covered|" "$(cover 'gh pr checks 12' '[]')"

it "a non-Bash rule never covers a command"
has "not_covered|" "$(cover 'gh pr checks 12' '["Read(*)", "mcp__x"]')"

it "a prefix-only rule without a word boundary does not cover a longer word"
has "not_covered|" "$(cover 'gh pr checksum 12' '["Bash(gh pr checks *)"]')"

it "a command the splitter cannot read is not_covered"
has "not_covered|" "$(cover 'gh pr checks "$(id)"' '["Bash(gh pr checks *)"]')"

it "the coverage result states what files cannot show"
has "managed settings" "$(run_py <<'EOF'
print(pr.coverage("gh pr checks 1", ["Bash(gh pr checks *)"])["unseen"])
EOF
)"

it "broader-than: {pr_checks, pr_view} against decided {pr_checks} is broader by pr_view"
check "['pr_view']" "$(run_py <<'EOF'
print(pr.broader_by({"pr_checks", "pr_view"}, [{"pr_checks"}]))
EOF
)"

it "broader-than: {pr_checks} against decided {pr_checks, pr_view} is not broader"
check "[]" "$(run_py <<'EOF'
print(pr.broader_by({"pr_checks"}, [{"pr_checks", "pr_view"}]))
EOF
)"

it "broader-than: the union of several decided sets counts"
check "[]" "$(run_py <<'EOF'
print(pr.broader_by(["pr_checks", "run_view"], [["pr_checks"], ["run_view"]]))
EOF
)"

it "broader-than: nothing decided means every operation is new"
check "['pr_checks']" "$(run_py <<'EOF'
print(pr.broader_by({"pr_checks"}, []))
EOF
)"

it "the catalog holds exactly the four read operations"
check "pr_checks,pr_view,run_list,run_view" "$(run_py <<'EOF'
print(",".join(sorted(pr.CATALOG)))
EOF
)"

it "every rendered proposal has a reach statement and the four exclusions"
check "ok" "$(run_py <<'EOF'
bad = []
for op in pr.CATALOG:
    p = pr.render_proposal([op])
    text = " ".join(p["exclusions"]).lower()
    if not p["reach"] or not all(r.strip() for r in p["reach"]):
        bad.append(op + ":reach")
    for word in ("merge", "comment", "push", "credential"):
        if word not in text:
            bad.append(op + ":" + word)
    if p["rules"] != [pr.CATALOG[op]["rule"]]:
        bad.append(op + ":rule")
print("ok" if not bad else bad)
EOF
)"

it "a rendered proposal for two operations lists both rules in catalog order"
check "Bash(gh pr checks *),Bash(gh pr view *)" "$(run_py <<'EOF'
print(",".join(pr.render_proposal(["pr_view", "pr_checks"])["rules"]))
EOF
)"

it "render_proposal refuses an unknown operation id"
has "unknown operation" "$(run_py <<'EOF'
try:
    pr.render_proposal(["pr_merge"])
except ValueError as exc:
    print(exc)
EOF
)"

it "the run_view reach names --log"
has "--log" "$(run_py <<'EOF'
print(" ".join(pr.render_proposal(["run_view"])["reach"]))
EOF
)"

MAIN="${WORK}/main"
mkdir -p "${MAIN}/.git/worktrees/feat" "${WORK}/wt/feat" "${WORK}/other/.git/worktrees/x" "${WORK}/wt/x"
printf '../..\n' > "${MAIN}/.git/worktrees/feat/commondir"
printf 'gitdir: %s\n' "${MAIN}/.git/worktrees/feat" > "${WORK}/wt/feat/.git"
printf '../..\n' > "${WORK}/other/.git/worktrees/x/commondir"
printf 'gitdir: %s\n' "${WORK}/other/.git/worktrees/x" > "${WORK}/wt/x/.git"
mkdir -p "${WORK}/wt/rel"
mkdir -p "${MAIN}/.git/worktrees/rel"
printf '../..\n' > "${MAIN}/.git/worktrees/rel/commondir"
printf 'gitdir: ../../main/.git/worktrees/rel\n' > "${WORK}/wt/rel/.git"
mkdir -p "${WORK}/wt/nocommon" "${MAIN}/.git/modules/sub"
printf 'gitdir: %s\n' "${MAIN}/.git/modules/sub" > "${WORK}/wt/nocommon/.git"

dest() {
  run_py "$1" "$2" <<'EOF'
r = pr.destination(args[0], json.loads(args[1]))
print(f"ok|{r['main']}|{r['file']}" if r["ok"] else f"no|{r['reason']}")
EOF
}

REAL_MAIN="$(cd "$MAIN" && pwd -P)"
it "a linked worktree resolves to its main checkout through .git and commondir"
check "ok|${REAL_MAIN}|${REAL_MAIN}/.claude/settings.local.json" "$(dest "${WORK}/wt/feat" "[\"${MAIN}\"]")"

it "a relative gitdir resolves against the worktree"
check "ok|${REAL_MAIN}|${REAL_MAIN}/.claude/settings.local.json" "$(dest "${WORK}/wt/rel" "[\"${MAIN}\"]")"

it "the main checkout itself resolves to itself"
check "ok|${REAL_MAIN}|${REAL_MAIN}/.claude/settings.local.json" "$(dest "${MAIN}" "[\"${MAIN}\"]")"

it "a common directory outside the remit repositories is refused"
has "no|" "$(dest "${WORK}/wt/x" "[\"${MAIN}\"]")"

it "a remit path given with a trailing slash still matches"
has "ok|" "$(dest "${WORK}/wt/feat" "[\"${MAIN}/\"]")"

it "a gitdir with no commondir is refused"
has "no|" "$(dest "${WORK}/wt/nocommon" "[\"${MAIN}\"]")"

it "a path with no .git is refused"
mkdir -p "${WORK}/plain"
has "no|" "$(dest "${WORK}/plain" "[\"${WORK}/plain\"]")"

it "an empty remit refuses everything"
has "no|" "$(dest "${MAIN}" "[]")"

echo "programme-permission-rules.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
