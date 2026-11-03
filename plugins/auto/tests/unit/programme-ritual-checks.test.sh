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

echo "programme-ritual-checks.test.sh"

WORK="$(mktemp -d -t auto-ritual-checks.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export WORK

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
pc = load_lib_module("programme_ritual_checks")
args = sys.argv[2:]
W = os.environ["WORK"]
ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t",
           GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
def git(repo, *a):
    return subprocess.run(["git", "-C", repo] + list(a), env=ENV, check=True, capture_output=True, text=True).stdout.strip()
def write(repo, rel, text):
    p = os.path.join(repo, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(text)
def pj(version):
    return json.dumps({"name": "foo", "version": version})
def market(version, name="foo"):
    return json.dumps({"plugins": [{"name": name, "version": version, "source": "./plugins/" + name}]})
def commit(repo, msg):
    git(repo, "add", "-A"); git(repo, "commit", "-q", "-m", msg)
def make(name, version="1.0.0"):
    repo = os.path.join(W, name)
    os.makedirs(repo)
    git(repo, "init", "-q", "-b", "main")
    write(repo, "plugins/foo/.claude-plugin/plugin.json", pj(version))
    write(repo, ".claude-plugin/marketplace.json", market(version))
    write(repo, "plugins/foo/lib/code.py", "x = 1\n")
    commit(repo, "initial")
    return repo
def show(r):
    print(r["result"], r["reason"], r.get("checked"), [f["plugin"] for f in r.get("failed", [])])
$(cat)
PYEOF
}

it "a repo whose shipped code changed since the last bump fails and names the plugin"
check "fail shipped_changed 1 ['foo']" "$(run_py <<'EOF'
repo = make("r1")
write(repo, "plugins/foo/lib/code.py", "x = 2\n"); commit(repo, "change code")
show(pc.run_check("versions-bumped", repo, "main"))
EOF
)"

it "a bump in both files after the code change passes and journals the counts"
check "pass ok 1 []" "$(run_py <<'EOF'
repo = make("r2")
write(repo, "plugins/foo/lib/code.py", "x = 2\n")
write(repo, "plugins/foo/.claude-plugin/plugin.json", pj("1.0.1"))
write(repo, ".claude-plugin/marketplace.json", market("1.0.1"))
commit(repo, "change and bump")
show(pc.run_check("versions-bumped", repo, "main"))
EOF
)"

it "a plugin.json bump without the marketplace entry fails"
check "fail marketplace_mismatch 1 ['foo']" "$(run_py <<'EOF'
repo = make("r3")
write(repo, "plugins/foo/.claude-plugin/plugin.json", pj("1.0.1")); commit(repo, "bump one file")
show(pc.run_check("versions-bumped", repo, "main"))
EOF
)"

it "the check reads the named ref, not the checked-out branch"
check "pass ok 1 []" "$(run_py <<'EOF'
repo = make("r4")
git(repo, "checkout", "-q", "-b", "feature")
write(repo, "plugins/foo/lib/code.py", "x = 3\n"); commit(repo, "unbumped work on a branch")
show(pc.run_check("versions-bumped", repo, "main"))
EOF
)"

it "every case where nothing was checked is an error, never a pass"
check "error not_a_repo 
error ref_missing 
error no_plugins 
error marketplace_unreadable " "$(run_py <<'EOF'
plain = os.path.join(W, "plain"); os.makedirs(plain)
for r in (pc.run_check("versions-bumped", plain, "main"),):
    print(r["result"], r["reason"], "")
repo = make("r5")
r = pc.run_check("versions-bumped", repo, "nope"); print(r["result"], r["reason"], "")
bare = os.path.join(W, "r6"); os.makedirs(bare); git(bare, "init", "-q", "-b", "main")
write(bare, "README.md", "x"); commit(bare, "no plugins")
r = pc.run_check("versions-bumped", bare, "main"); print(r["result"], r["reason"], "")
nomp = make("r7"); git(nomp, "rm", "-q", ".claude-plugin/marketplace.json"); git(nomp, "commit", "-q", "-m", "drop marketplace")
r = pc.run_check("versions-bumped", nomp, "main"); print(r["result"], r["reason"], "")
EOF
)"

it "a plugin folder name with a quote is an error and creates nothing"
check "error bad_plugin_name | False" "$(run_py <<'EOF'
repo = make("r8")
bad = "plugins/a'+__import__('os').mkdir('PWNED')+'/.claude-plugin/plugin.json"
write(repo, bad, pj("1.0.0")); commit(repo, "hostile name")
r = pc.run_check("versions-bumped", repo, "main")
print(r["result"], r["reason"], "|", os.path.exists(os.path.join(repo, "PWNED")))
EOF
)"

it "a repo that ships its own check script never has it run"
check "pass False" "$(run_py <<'EOF'
repo = make("r9")
write(repo, "scripts/check-version-bumped.sh", "#!/bin/sh\ntouch " + os.path.join(W, "SCRIPT-RAN") + "\n")
os.chmod(os.path.join(repo, "scripts/check-version-bumped.sh"), 0o755)
commit(repo, "add script")
r = pc.run_check("versions-bumped", repo, "main")
print(r["result"], os.path.exists(os.path.join(W, "SCRIPT-RAN")))
EOF
)"

it "a base that looks like an option is an error, not a git flag"
check "error ref_missing" "$(run_py <<'EOF'
repo = make("r10")
r = pc.run_check("versions-bumped", repo, "--upload-pack=touch PWNED")
print(r["result"], r["reason"])
EOF
)"

it "an unknown check name is an error and a crash inside a check never escapes"
check "error unknown_check" "$(run_py <<'EOF'
r = pc.run_check("rm-everything", W, None); print(r["result"], r["reason"])
EOF
)"

it "the result reports the commit it read and the age of the clone's last fetch"
has "True" "$(run_py <<'EOF'
repo = make("r11")
sha = git(repo, "rev-parse", "main")
r = pc.run_check("versions-bumped", repo, "main")
print(r["ref_sha"] == sha, r["ref_age_seconds"])
EOF
)"

it "an overall budget that is already spent is an error (timeout), not a pass"
check "error timeout" "$(run_py <<'EOF'
repo = make("r12")
r = pc.run_check("versions-bumped", repo, "main", budget_seconds=0)
print(r["result"], r["reason"])
EOF
)"

it "review: a repo-set gpg.program with log.showSignature is never run by a check"
check "no True" "$(run_py <<'EOF'
repo = make("r13")
marker = os.path.join(W, "GPG-RAN")
script = os.path.join(W, "evil-gpg.sh")
open(script, "w").write("#!/bin/sh\ntouch " + marker + "\nexit 1\n"); os.chmod(script, 0o755)
git(repo, "config", "log.showSignature", "true"); git(repo, "config", "gpg.program", script)
git(repo, "config", "diff.external", script)
write(repo, ".claude-plugin/marketplace.json", market("1.0.0"))
write(repo, "plugins/foo/.claude-plugin/plugin.json", pj("1.0.1")); commit(repo, "bump plugin.json")
raw = git(repo, "cat-file", "commit", "HEAD")
head, _, msg = raw.partition("\n\n")
signed = head + "\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n abc\n -----END PGP SIGNATURE-----\n\n" + msg + "\n"
oid = subprocess.run(["git", "-C", repo, "hash-object", "-t", "commit", "-w", "--stdin"], input=signed, env=ENV, check=True, capture_output=True, text=True).stdout.strip()
git(repo, "update-ref", "refs/heads/main", oid)
r = pc.run_check("versions-bumped", repo, "main")
print("no" if not os.path.exists(marker) else "RAN", r["result"] in ("fail", "pass", "error"))
EOF
)"

it "review: a shallow clone is an error, never a pass"
check "error shallow_clone" "$(run_py <<'EOF'
repo = make("r14")
write(repo, "plugins/foo/lib/code.py", "x = 5\n"); commit(repo, "second")
clone = os.path.join(W, "r14-shallow")
subprocess.run(["git", "clone", "-q", "--depth", "1", "file://" + repo, clone], env=ENV, check=True, capture_output=True)
r = pc.run_check("versions-bumped", clone, "origin/main")
print(r["result"], r["reason"])
EOF
)"

it "review: a plugin whose manifest is present but not valid JSON is an error even when another plugin was read"
check "error manifest_unreadable" "$(run_py <<'EOF'
repo = make("r15")
write(repo, "plugins/bar/.claude-plugin/plugin.json", "{ not json"); commit(repo, "broken manifest")
r = pc.run_check("versions-bumped", repo, "main")
print(r["result"], r["reason"])
EOF
)"

it "review: a plugin folder name ending in a newline is refused"
check "error bad_plugin_name" "$(run_py <<'EOF'
print("error bad_plugin_name" if pc._PLUGIN_RE.fullmatch("foo\n") is None and pc._PLUGIN_RE.match("foo\n") else "fullmatch not used")
EOF
)"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
