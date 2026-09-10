#!/usr/bin/env bash
# work test harness.
#
# There is no CI in this repo, so this harness is the whole automated
# verification contract. It is source-safe on purpose: `wire_smoke` and
# `secret_scan` carry real rules, and a rule nothing can test in isolation is a
# rule that rots. Sourcing this file defines the functions and runs nothing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

# Prove the harness can fail. A suite is trusted only after it has been seen to
# report a deliberately-false assertion as failing; without this, a runner that
# silently swallows bats' exit code reports green forever.
self_check() {
    printf '%sHarness self-check (deliberate-fail)...%s\n' "$YELLOW" "$NC"
    local tmp; tmp="$(mktemp -d)"
    cat > "$tmp/deliberate_fail.bats" <<'EOF'
@test "deliberate failure — the harness MUST report this as failing" {
    [ "1" = "2" ]
}
EOF
    if bats "$tmp/deliberate_fail.bats" >/dev/null 2>&1; then
        rm -rf "$tmp"
        printf '%sself-check FAILED%s — the runner called a false assertion green.\n' "$RED" "$NC"
        return 1
    fi
    rm -rf "$tmp"
    printf '%sself-check passed%s\n' "$GREEN" "$NC"
}

# The count of suite files committed alongside this guard (2026-09-05). Bump it
# up whenever a suite file is added; if it is ever lowered, say why in the
# commit — this number is what turns "the tests directory got renamed" into a
# failure instead of a smaller, silently-green run.
HERDR_LINEAR_MIN_SUITES="${HERDR_LINEAR_MIN_SUITES:-17}"

run_suite() {
    local failed=0 f count=0 dir="${1:-$PLUGIN_ROOT/tests/unit}"
    for f in "$dir"/*.bats; do
        [ -e "$f" ] || continue
        count=$((count + 1))
        printf '%s%s%s\n' "$YELLOW" "$(basename "$f")" "$NC"
        bats "$f" || failed=1
    done
    # A loop that never ran is a loop that never failed. Refuse the silent
    # green rather than let a moved directory or a broken glob report PASS.
    if [ "$count" -eq 0 ]; then
        printf '%srun_suite FAILED%s — zero .bats files found under %s; nothing ran.\n' "$RED" "$NC" "$dir"
        return 1
    fi
    if [ "$count" -lt "$HERDR_LINEAR_MIN_SUITES" ]; then
        printf '%srun_suite FAILED%s — %d suite file(s) found under %s, expected at least %d.\n' \
            "$RED" "$NC" "$count" "$dir" "$HERDR_LINEAR_MIN_SUITES"
        failed=1
    fi
    return "$failed"
}

# scan_or_fail <label> [python-args...] -- the scanner itself arrives on stdin.
#
# Every check that shells out to a scanner needs the same three-way reading, and
# writing it out per check produced three different wrappers, two of which
# reported the scanner's own crash as a clean tree. There is one wrapper now.
#
#   status != 0  the scan did not complete; nothing was proven -> fail
#   stdout       the findings -> print them and fail
#   neither      pass
#
# So a scanner behind this helper PRINTS its findings and exits 0; it must not
# use its exit status to report one, because that status is reserved for "I
# crashed". Callers must write `scan_or_fail ... || return 1`: errexit is off
# inside a check invoked as `check || rc=1`, so without it the caller's own green
# line runs anyway and the failure is thrown away.
scan_or_fail() {
    local label="$1" out rc=0
    shift
    out="$(python3 - "$@")" || rc=$?
    if [ -n "$out" ]; then printf '%s\n' "$out"; fi
    if [ "$rc" -ne 0 ]; then
        printf '%s%s FAILED%s — the scan itself did not complete; nothing was proven.\n' \
            "$RED" "$label" "$NC"
        return 1
    fi
    if [ -n "$out" ]; then
        printf '%s%s FAILED%s — see the line(s) above.\n' "$RED" "$label" "$NC"
        return 1
    fi
    return 0
}

# The helper's contract holds only while every caller writes `|| return 1`. A
# call without it prints the failure and then falls through to the caller's own
# green line, which is exactly the defect the helper was written to remove -- so
# the shape is refused here rather than left to the next author's memory.
scan_caller_check() {
    printf '%sscan_or_fail caller check...%s\n' "$YELLOW" "$NC"
    local self="$SCRIPT_DIR/run-tests.sh" calls bare
    [ -r "$self" ] || {
        printf '%sscan_or_fail caller check FAILED%s — %s is not readable; nothing was checked.\n' \
            "$RED" "$NC" "$self"; return 1; }
    # A call is the first word of its own line. Anchoring there is what keeps
    # this from matching the name inside its own comments and messages -- a
    # predicate that matches itself reports a defect on a clean file. The cost is
    # that a call buried mid-line is outside what this sees; the shapes that hide
    # one there (`if ! scan_or_fail ...`) already handle the failure.
    # A pattern that stopped matching would call every caller correct, so the
    # count is asserted too.
    calls="$(grep -cE '^[[:space:]]*scan_or_fail[[:space:]]' "$self" || true)"
    if [ "$calls" -eq 0 ]; then
        printf '%sscan_or_fail caller check FAILED%s — no call recognised in %s; the shape moved.\n' \
            "$RED" "$NC" "$self"
        return 1
    fi
    bare="$(grep -nE '^[[:space:]]*scan_or_fail[[:space:]]' "$self" | grep -v '|| return 1$' || true)"
    if [ -n "$bare" ]; then
        printf '%s\n' "$bare"
        printf '%sscan_or_fail caller check FAILED%s — the line(s) above drop the trailing\n' "$RED" "$NC"
        printf 'guard, so a failed scan falls through to the green line below it.\n'
        return 1
    fi
    printf '%sall %d call(s) stop on a failed scan%s\n' "$GREEN" "$calls" "$NC"
}

# The two version fields must agree. Nothing enforces this repo-wide, so each
# plugin that wants the check writes its own.
version_sync_check() {
    local manifest="${1:-$PLUGIN_ROOT/.claude-plugin/plugin.json}"
    local marketplace="${2:-$REPO_ROOT/.claude-plugin/marketplace.json}"
    scan_or_fail "version sync check" "$manifest" "$marketplace" <<'PY' || return 1
import json, sys
m = json.load(open(sys.argv[1]))
mk = json.load(open(sys.argv[2]))
entry = next((p for p in mk.get("plugins", []) if p.get("name") == m["name"]), None)
if entry is None:
    print("plugin %r is not registered in the marketplace" % m["name"])
elif entry.get("version") != m.get("version"):
    print("version drift: plugin.json %s, marketplace %s" % (m.get("version"), entry.get("version")))
PY
}

# `claude plugin validate` exits 0 even when it reports problems, so its output
# is what decides, not its status.
# `claude plugin validate` PASSES a manifest that declares ./hooks/hooks.json,
# and the plugin then fails to LOAD with "Duplicate hooks file detected" -- the
# standard path is auto-loaded, so naming it makes the whole plugin unavailable.
# Validation is not the loader, and this is the gap between them.
manifest_autoload_check() {
    local m="$PLUGIN_ROOT/.claude-plugin/plugin.json"
    printf '%sManifest auto-load check...%s\n' "$YELLOW" "$NC"
    [ -r "$m" ] || { printf '%sno manifest at %s%s\n' "$RED" "$m" "$NC"; return 1; }
    scan_or_fail "manifest auto-load check" "$m" "$PLUGIN_ROOT" <<'PY' || return 1
import json, os, sys
m, root = sys.argv[1], sys.argv[2]
d = json.load(open(m))
bad = []
# Only hooks/hooks.json is auto-loaded; skills/ and commands/ are declared
# normally by every other plugin in this marketplace and must stay.
h = d.get("hooks")
if isinstance(h, str) and os.path.normpath(h.lstrip("./")) == os.path.join("hooks", "hooks.json"):
    if os.path.exists(os.path.join(root, "hooks", "hooks.json")):
        bad.append("hooks: %s duplicates the auto-loaded hooks/hooks.json, so the "
                   "plugin would fail to load; remove the key (the file is still used)" % h)
print("\n".join(bad))
PY
    printf '%smanifest declares no auto-loaded path%s\n' "$GREEN" "$NC"
    return 0
}

validate_check() {
    # A gate that cannot run is not a gate that passed. Opt out by name when
    # that is deliberate; silence here would let `all` go green on a machine
    # that never validated the manifest at all.
    if ! command -v claude >/dev/null 2>&1; then
        if [ -n "${HERDR_LINEAR_SKIP_VALIDATE:-}" ]; then
            printf 'claude absent; validate skipped by HERDR_LINEAR_SKIP_VALIDATE\n'; return 0
        fi
        printf '%sclaude is not on PATH, so the manifest was never validated%s\n' "$RED" "$NC"; return 1
    fi
    local out; out="$(claude plugin validate "$PLUGIN_ROOT" 2>&1 || true)"
    printf '%s\n' "$out"
    if printf '%s' "$out" | grep -qiE 'error|invalid|failed'; then return 1; fi
}

# Credential shapes that must never appear in the tree. spawn's set covers
# sk-ant-, sk-, AKIA, gh[pousr]_, xox and PEM headers; a Linear key is lin_api_
# and matches none of them, which is the shape this plugin actually handles.
SECRET_PATTERNS='lin_api_[A-Za-z0-9]{16,}|lin_oauth_[A-Za-z0-9]{16,}|sk-ant-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

# scan_paths <path>... -> non-zero when any path carries a credential shape.
scan_paths() {
    local hit=0 p
    for p in "$@"; do
        # -l, never -n: printing the matching LINE copies a live credential into
        # the terminal, the transcript and any log of the run, so the detector
        # would spread the very thing it found. Name the file instead.
        if grep -rIlE "$SECRET_PATTERNS" "$p" 2>/dev/null; then hit=1; fi
    done
    return "$hit"
}

secret_scan() {
    printf '%sSecret scan...%s\n' "$YELLOW" "$NC"
    # grep exiting 2 because the path is absent is not a match, so a scan of
    # nothing prints the same "no credential shapes found" as a clean tree. This
    # is the credential guard; it does not get to say that about a directory it
    # never opened. The guard is written out here rather than shared with
    # brand_scan's, so that neither can be relaxed on the other's behalf.
    if [ ! -d "$PLUGIN_ROOT/lib" ] || [ ! -r "$PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
        printf '%ssecret scan FAILED%s — %s is not the plugin root; nothing was scanned.\n' \
            "$RED" "$NC" "$PLUGIN_ROOT"
        return 1
    fi
    if scan_paths "$PLUGIN_ROOT"; then
        printf '%sno credential shapes found%s\n' "$GREEN" "$NC"
    else
        printf '%ssecret scan FAILED%s — a credential shape is present in the tree.\n' "$RED" "$NC"
        return 1
    fi
}

# R8. The organisation and product name this plugin was written for must appear
# in nothing it ships; the tracker's own name is not in that class. This file is
# the single exclusion, because it is where the forbidden spelling is written
# down. The leading `[^A-Za-z]` keeps ordinary words that end in the same
# letters ("translate") out of the class. Two exact strings are exempt, by span
# so a second name on the same line is still a hit: the maintainer's own address
# in the manifest, which is identity rather than branding, and the deprecated
# environment variable name, which the fallback in lib/contain.sh has to spell
# out to name what the user must rename. Both exemptions go when the thing they
# name goes.
#
# Every letter is a class because the name is spelled in three cases here and
# the pattern could reach only two of them: the SHOUTING form inside
# HERDR_LINEAR_SLATE_ROOT went unseen, which made the green line claim more than
# it had looked at and left the exemption for that variable suppressing nothing.
BRAND_PATTERN='(^|[^A-Za-z])[Ss][Ll][Aa][Tt][Ee]'

brand_scan() {
    printf '%sBrand scan...%s\n' "$YELLOW" "$NC"
    # A recursive walk over a directory that is not there finds nothing and
    # reads exactly like a clean tree, so prove the root before trusting it.
    if [ ! -d "$PLUGIN_ROOT/lib" ] || [ ! -r "$PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
        printf '%sbrand scan FAILED%s — %s is not the plugin root; nothing was scanned.\n' \
            "$RED" "$NC" "$PLUGIN_ROOT"
        return 1
    fi
    scan_or_fail "brand scan" "$PLUGIN_ROOT" "$REPO_ROOT/.claude-plugin/marketplace.json" "$BRAND_PATTERN" <<'PYEOF' || return 1
import glob, json, os, re, sys

plugin_root, marketplace, pattern = sys.argv[1], sys.argv[2], sys.argv[3]
rx = re.compile(pattern)
manifest = json.load(open(os.path.join(plugin_root, ".claude-plugin", "plugin.json")))
# The manifest address is looked up rather than written down, so it cannot go
# stale -- whatever the manifest carries is what is exempt. The deprecated
# variable name is a literal, and a literal outlives its reason unless something
# checks: an exemption that survives the thing it excused is a hole in the scan,
# so it expires with the fallback that needs it.
DEPRECATED_ENV = "HERDR_LINEAR_SLATE_ROOT"
lib_text = "".join(open(f).read() for f in sorted(glob.glob(os.path.join(plugin_root, "lib", "*.sh"))))

exempt = [e for e in [(manifest.get("author") or {}).get("email"),
                      DEPRECATED_ENV] if e]

def spans(line):
    out = []
    for token in exempt:
        start = 0
        while True:
            i = line.find(token, start)
            if i < 0:
                break
            out.append((i, i + len(token)))
            start = i + 1
    return out

hits = []
if DEPRECATED_ENV not in lib_text:
    hits.append("run-tests.sh: the exemption for %s is no longer justified -- it "
                "appears nowhere under lib/, so remove it from BRAND_PATTERN's "
                "exempt list" % DEPRECATED_ENV)

for dirpath, dirnames, filenames in os.walk(plugin_root):
    dirnames[:] = [d for d in dirnames if d != ".git"]
    for fn in sorted(filenames):
        path = os.path.join(dirpath, fn)
        if fn == "run-tests.sh":
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            allowed = spans(line)
            for m in rx.finditer(line):
                if any(a <= m.start() and m.end() <= b for a, b in allowed):
                    continue
                hits.append("%s:%d:%s" % (os.path.relpath(path, plugin_root), n, line.strip()))

entry = next((e for e in json.load(open(marketplace)).get("plugins", [])
              if e.get("name") == manifest["name"]), None)
if entry is None:
    hits.append("marketplace.json: %r is not registered" % manifest["name"])
elif rx.search(json.dumps(entry, ensure_ascii=False)):
    hits.append("marketplace.json: the %r entry names the organisation" % manifest["name"])

print("\n".join(hits))
PYEOF
    printf '%sno shipped file names the organisation%s\n' "$GREEN" "$NC"
}

# A `!`-negated command is exempt from errexit, so `! grep -q X` in a bats test
# detects the defect and lets the test pass. Two sanitiser tests and a Keychain
# guard were inert this way. The suite refuses the shape rather than trusting
# the next author to remember.
assertion_lint() {
    printf '%sAssertion lint...%s\n' "$YELLOW" "$NC"
    local hits f count=0
    # A grep that matched nothing and a grep that was handed nothing print the
    # same empty string. Count what was examined and refuse the second, the way
    # run_suite refuses a loop that never ran.
    for f in "$PLUGIN_ROOT"/tests/unit/*.bats; do [ -e "$f" ] && count=$((count + 1)); done
    if [ "$count" -eq 0 ]; then
        printf '%sassertion lint FAILED%s — no .bats file under %s/tests/unit; nothing was linted.\n' \
            "$RED" "$NC" "$PLUGIN_ROOT"
        return 1
    fi
    hits="$(grep -rnE '^[[:space:]]*![[:space:]]' "$PLUGIN_ROOT"/tests/unit/*.bats 2>/dev/null || true)"
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits"
        printf '%sassertion lint FAILED%s — a `!`-negated assertion cannot fail its test; use refute_match.\n' "$RED" "$NC"
        return 1
    fi
    printf '%sno negated assertions%s\n' "$GREEN" "$NC"
}

# Each SKILL.md hand-copies its own subset of `source lib/*.sh` lines, and
# nothing else checks that the subset is actually enough. This computes the
# real dependency closure from the lib files themselves (which function calls
# which, defined where) and fails a skill whose declared sourcing is short of
# what the functions it calls transitively need -- the "undefined function at
# the worst moment" failure the copy-pasted lists cannot see coming.
#
# owned_docs is every document this plugin ships that carries a bash fence
# calling into lib/. It is globbed, never listed: a hand-written list is
# complete only until the next skill is added, and the file nobody remembered to
# add is exactly where a retired verb survives unnoticed.
skill_lib_sync_check() {
    printf '%sSkill lib-sourcing check...%s\n' "$YELLOW" "$NC"
    local root="${1:-$PLUGIN_ROOT}"
    scan_or_fail "skill lib-sourcing check" "$root" <<'PY' || return 1
import re, sys, glob, os

plugin_root = sys.argv[1]
owned_docs = sorted(
    os.path.relpath(p, plugin_root)
    for p in glob.glob(os.path.join(plugin_root, "skills", "*", "SKILL.md"))
    + glob.glob(os.path.join(plugin_root, "commands", "*.md"))
)
# An empty glob makes the loop below a no-op, and a no-op reports clean.
if not owned_docs:
    print("no skill or command document found under %s" % plugin_root); raise SystemExit

lib_names = sorted(os.path.basename(f)[:-3] for f in glob.glob(os.path.join(plugin_root, "lib", "*.sh")))

defs = {}
for name in lib_names:
    text = open(os.path.join(plugin_root, "lib", name + ".sh")).read()
    for m in re.finditer(r'^herdr_linear::([A-Za-z0-9_]+)\s*\(\)', text, re.M):
        defs[m.group(1)] = name

file_deps = {}
for name in lib_names:
    text = open(os.path.join(plugin_root, "lib", name + ".sh")).read()
    used = set()
    for m in re.finditer(r'herdr_linear::([A-Za-z0-9_]+)', text):
        fn = m.group(1)
        if fn in defs and defs[fn] != name:
            used.add(defs[fn])
    file_deps[name] = used

def closure(start_names):
    seen, stack = set(), list(start_names)
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        stack.extend(file_deps.get(n, ()))
    return seen

def sourced_names(fence_text):
    names = set(re.findall(r'lib/([a-zA-Z][a-zA-Z-]*)\.sh', fence_text))
    m = re.search(r'for\s+f\s+in\s+([a-zA-Z0-9_ \-]+?)\s*;\s*do', fence_text)
    if m:
        names.update(m.group(1).split())
    return names

for rel in owned_docs:
    path = os.path.join(plugin_root, rel)
    text = open(path).read()
    fence_text = "\n".join(re.findall(r'```bash\n(.*?)```', text, re.S))
    declared = sourced_names(fence_text)
    called = set(re.findall(r'herdr_linear::([A-Za-z0-9_]+)', fence_text))

    unknown = sorted(fn for fn in called if fn not in defs)
    if unknown:
        print("%s: calls undefined function(s): %s" % (path, ", ".join(unknown)))

    required = closure({defs[fn] for fn in called if fn in defs})
    missing = sorted(required - declared)
    if missing:
        print("%s: sources %s, missing %s (needed transitively by what it calls)"
              % (path, sorted(declared), missing))

    bogus = sorted(n for n in declared if n not in lib_names)
    if bogus:
        print("%s: sources nonexistent lib file(s): %s" % (path, bogus))
PY
    printf '%severy owned document sources what it calls%s\n' "$GREEN" "$NC"
}

# The enforcement point is the thing under test, and one red test proves ONE
# write site. This forces the consent reader to say yes everywhere, then demands
# a named red test per write verb. A verb that forgot the check stays green under
# the mutation, and its absence from this list is the finding.
#
# The lib/ tree is copied and patched; nothing under the checkout is touched, so
# a killed run leaves no half-mutated source behind.
consent_mutation_check() {
    printf '%sConsent mutation (reader forced true)...%s\n' "$YELLOW" "$NC"
    # `cp -R "$PLUGIN_ROOT"` is only safe while PLUGIN_ROOT really is the plugin.
    # A copy of this script run from somewhere else resolves it to `/` and the
    # phase then copies the whole filesystem -- which is how it filled a disk
    # once. Prove the target first; the copy is the destructive step.
    if [ ! -r "$PLUGIN_ROOT/.claude-plugin/plugin.json" ] || [ ! -d "$PLUGIN_ROOT/lib" ]; then
        printf '%s%s is not the plugin root; refusing to copy it%s\n' "$RED" "$PLUGIN_ROOT" "$NC"
        return 1
    fi
    # Every one of these must go red. They are named, because "the suite failed"
    # is exactly the answer that hides a verb with no check in it.
    local -a expect=(
        "create.bats:an answer given in an unrelated worktree does not enable issue creation"
        "create.bats:an answer for another team does not enable project creation"
        "start.bats:an answer for another team does not enable creation"
        "description.bats:a description is not written when nobody has answered"
        "documents.bats:a document is not published when nobody has answered"
        "reconcile.bats:a hook with no recorded answer records the question rather than sending"
    )
    # The names above are the point of the list and they stay. What a hand-kept
    # list cannot do is notice the write verb added next year: a seventh call
    # site with no line here is forgotten in the one phase that then reports
    # every verb covered. So the same list is derived from the call sites
    # themselves and the two must agree -- the list can drift, but not quietly.
    local derived expected
    derived="$(awk '
        /herdr_linear::consent_gate/ && $0 !~ /^[[:space:]]*#/ && $0 !~ /herdr_linear::consent_gate\(\)/ {
            n = split(FILENAME, p, "/"); f = p[n]; sub(/\.sh$/, ".bats", f); print f
        }' "$PLUGIN_ROOT"/lib/*.sh | sort)"
    expected="$(printf '%s\n' "${expect[@]}" | sed 's/:.*//' | sort)"
    if [ "$derived" != "$expected" ]; then
        printf '%sconsent mutation FAILED%s — the named list and the real consent_gate call sites disagree.\n' \
            "$RED" "$NC"
        printf '  < named above, > found under lib/; add or remove a named test to match.\n'
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$derived") | sed 's/^/  /'
        return 1
    fi
    local tmp; tmp="$(mktemp -d)"
    # The whole plugin, because a .bats file resolves lib/ from its OWN
    # directory -- copying lib/ alone would run every test against the real one
    # and report a green mutation for a reason that has nothing to do with the
    # code under test.
    cp -R "$PLUGIN_ROOT" "$tmp/work"
    cat >> "$tmp/work/lib/binding.sh" <<'EOF'

herdr_linear::consent_ok() { return 0; }
EOF
    local rc=0 entry file name out
    for entry in "${expect[@]}"; do
        file="${entry%%:*}"; name="${entry#*:}"
        out="$(bats -f "$name" "$tmp/work/tests/unit/$file" 2>&1 || true)"
        # The filter matching nothing prints "0 tests" and exits 0, which reads
        # exactly like a pass. Require the test to have RUN and to have failed.
        if ! printf '%s' "$out" | grep -q "^ok 1 \|^not ok 1 "; then
            printf '%s  %s / %s — the mutation phase ran no such test%s\n' "$RED" "$file" "$name" "$NC"; rc=1; continue
        fi
        if printf '%s' "$out" | grep -q "^not ok 1 "; then
            printf '%s  red: %s / %s%s\n' "$GREEN" "$file" "$name" "$NC"
        else
            printf '%s  STILL GREEN: %s / %s — this verb does not read the consent record%s\n' "$RED" "$file" "$name" "$NC"; rc=1
        fi
    done
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] && printf '%severy write verb turns red without the consent check%s\n' "$GREEN" "$NC"
    return "$rc"
}

# consent_confirm and consent_decline have exactly one class of caller: the
# ask-and-record fence in a write skill, every one of them
# disable-model-invocation. Both record a PERSON'S answer -- no is an answer --
# so a caller under lib/, hooks/ or commands/ would let the plugin answer its
# own question either way.
consent_caller_check() {
    printf '%sConsent answer-verb caller check...%s\n' "$YELLOW" "$NC"
    local hits d verb
    # An absent directory yields no hits and reads as "no caller", so name the
    # three the rule is about and require each to be there before believing it.
    for d in lib hooks commands; do
        if [ ! -d "$PLUGIN_ROOT/$d" ]; then
            printf '%sconsent-confirm caller check FAILED%s — %s/%s is not there; it was never swept.\n' \
                "$RED" "$NC" "$PLUGIN_ROOT" "$d"
            return 1
        fi
    done
    for verb in consent_confirm consent_decline; do
        hits="$(grep -rn "herdr_linear::$verb" \
            "$PLUGIN_ROOT/lib" "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/commands" 2>/dev/null \
            | grep -v "^.*/lib/binding.sh:.*herdr_linear::$verb() {" || true)"
        if [ -n "$hits" ]; then
            printf '%s\n' "$hits"
            printf '%s%s caller check FAILED%s — only a write skill may record an answer.\n' \
                "$RED" "$verb" "$NC"
            return 1
        fi
    done
    printf '%sneither answer verb has a caller under lib/, hooks/ or commands/%s\n' "$GREEN" "$NC"
}

# Sourcing lib/ writes to stderr -- the deprecated-root warning in contain.sh
# does -- and a hook has no stderr to spare: R26 is no output at all, not less
# of it. Both hooks discard it on the source loop today; this is what stops the
# next hook, or a rewrite of an existing one, from dropping the redirection and
# leaking lib chatter into a session that was never pointed at this plugin.
hook_source_stderr_check() {
    printf '%sHook source-stderr check...%s\n' "$YELLOW" "$NC"
    local rc=0 f hits loops count=0
    for f in "$PLUGIN_ROOT"/hooks/*.sh; do
        [ -e "$f" ] || continue
        count=$((count + 1))
        # The rule is enforced by recognising one exact spelling of the source
        # loop. A hook that spells it differently matches nothing and passes
        # while leaking, so require the line to be FOUND before reading anything
        # into the fact that none of them was bare.
        loops="$(grep -c '\. "\$LIB/\$f"' "$f" || true)"
        if [ "$loops" -eq 0 ]; then
            printf '%s: no `. "$LIB/$f"` line, so this check saw nothing in it. Every hook\n' "$(basename "$f")"
            printf '    is required to carry that exact line; a hook that sources lib some other\n'
            printf '    way, or sources none at all, needs this check widened rather than trusted.\n'
            rc=1
            continue
        fi
        hits="$(grep -n '\. "\$LIB/\$f"' "$f" | grep -v '2>/dev/null' || true)"
        if [ -n "$hits" ]; then
            printf '%s: %s\n' "$(basename "$f")" "$hits"
            rc=1
        fi
    done
    if [ "$count" -eq 0 ]; then
        printf '%shook source-stderr check FAILED%s — no hook under %s/hooks; nothing was checked.\n' \
            "$RED" "$NC" "$PLUGIN_ROOT"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        printf '%shook source-stderr check FAILED%s — a hook sources lib without discarding stderr.\n' "$RED" "$NC"
        return 1
    fi
    printf '%severy hook sources lib with stderr discarded%s\n' "$GREEN" "$NC"
}

# The act-or-ask rubric is copied into all eight skills because a skill file is
# what is in context when it runs. Eight copies drift, and a drifted copy ships
# green -- so the identity is asserted here rather than assumed, and the failure
# names the file that moved.
rubric_sync_check() {
    printf '%sRubric sync check...%s\n' "$YELLOW" "$NC"
    local root="${1:-$PLUGIN_ROOT}"
    scan_or_fail "rubric sync check" "$root" <<'PYEOF' || return 1
import sys, os, glob, hashlib

root = sys.argv[1]
paths = sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md")))
if not paths:
    print("no SKILL.md files found under %s/skills" % root); raise SystemExit

# The rubric is bounded by its own closing sentence, not by the next heading:
# in most skills the text after it is file-specific prose with no heading
# between, and a heading-bounded window would compare that prose too.
TERMINATOR = "never a reason to stop."

def block(path):
    lines = open(path).read().splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "## Act or ask":
            out = [line]
            for nxt in lines[i + 1:]:
                out.append(nxt)
                if nxt.rstrip().endswith(TERMINATOR):
                    return "\n".join(out).rstrip()
            return None
    return None

blocks = {p: block(p) for p in paths}
missing = sorted(p for p, b in blocks.items() if b is None)
for p in missing:
    print("%s: carries no `## Act or ask` rubric, or one that never closes" % p)

present = {p: b for p, b in blocks.items() if b is not None}
if present:
    # The majority spelling is the reference, so one drifted file is named as
    # the drift rather than renaming the other seven.
    counts = {}
    for b in present.values():
        counts[b] = counts.get(b, 0) + 1
    ref = max(counts, key=lambda b: counts[b])
    ref_sum = hashlib.md5(ref.encode()).hexdigest()[:8]
    for p in sorted(present):
        if present[p] != ref:
            print("%s: rubric differs from the other %d (%s vs %s)"
                  % (p, counts[ref], hashlib.md5(present[p].encode()).hexdigest()[:8], ref_sum))
PYEOF
    printf '%sthe rubric is one text in every skill%s\n' "$GREEN" "$NC"
}

# A function that turns an identifier into a filesystem path must call the one
# validator. This is the half a unit test cannot answer: is_safe_identifier had
# two passing tests and one production caller, and the traversal in cache_read
# sat under both of them. The check is grep-shaped ON PURPOSE -- it asks whether
# the call is WRITTEN, and the positive-path unit tests carry the other half,
# which is whether the function is DEFINED when the code runs.
#
# Anchored on the path construction, not on a name: a site is any line that puts
# a variable segment under a *_DIR or *CACHE root. Two sites consume a shasum
# key rather than an identifier and are named below with that reason.
#
# WHAT IT DOES NOT SEE, so nobody reads more from a green than is there:
# constructions at a script's TOP LEVEL rather than inside a function, and roots
# that are neither *_DIR nor *CACHE -- start.sh builds "$root/$name" from a
# slugged title, which lib/sanitize.sh guards by a different route.
identifier_path_check() {
    printf '%sIdentifier path-construction check...%s\n' "$YELLOW" "$NC"
    local rc=0 f out
    for f in "$PLUGIN_ROOT"/lib/*.sh "$PLUGIN_ROOT"/hooks/*.sh "$PLUGIN_ROOT"/bin/*.sh; do
        [ -e "$f" ] || continue
        out="$(awk -v file="$f" '
            # binding_key and _pin_branch_key both emit 16 hex characters from
            # shasum. There is no identifier in either path.
            BEGIN {
                skip["herdr_linear::_record_path"] = 1
                skip["herdr_linear::binding_seed_candidate"] = 1
            }
            # ANY function header, not just a herdr_linear:: one. The cache
            # WRITER is a bare write_nodes(), and a prefix-only pattern walked
            # straight past the one traversal that writes rather than reads.
            /^[A-Za-z_][A-Za-z0-9_:]*\(\)[[:space:]]*\{/ {
                fn = $0; sub(/\(\).*/, "", fn)
                body = ""; site = ""; next
            }
            fn != "" { body = body "\n" $0 }
            # A *_DIR root with a variable segment under it. Skips the top-level
            # defaulting assignments, which have the _DIR on the left.
            fn != "" && (/_DIR/ || /CACHE/) && /\$\{?[a-z_0-9]/ \
                && !/^[[:space:]]*[A-Z_]+=/ {
                if (site == "") site = NR ": " $0
            }
            /^\}/ {
                if (fn != "" && site != "" && !(fn in skip) \
                    && body !~ /is_safe_identifier/)
                    print file ":" site "   [" fn "]"
                fn = ""; body = ""; site = ""
            }
        ' "$f")"
        [ -n "$out" ] && { printf '%s\n' "$out"; rc=1; }
    done
    # The other half. A grep proves the call is written; nothing above proves
    # the function is DEFINED when it runs. No lib sources another, and
    # ground.sh sources sanitize.sh AFTER the files that need it -- so a caller
    # without this line gets 127 from an undefined function, which its `||`
    # branch reads as a refusal and every negative test passes for that reason.
    for f in "$PLUGIN_ROOT"/lib/*.sh "$PLUGIN_ROOT"/bin/*.sh; do
        [ -e "$f" ] || continue
        case "$f" in */sanitize.sh) continue ;; esac
        grep -q 'is_safe_identifier' "$f" || continue
        grep -qE 'sanitize\.sh"?$|/sanitize\.sh' "$f" && continue
        printf '%s: calls is_safe_identifier and never sources sanitize.sh\n' "$f"
        rc=1
    done

    if [ "$rc" -ne 0 ]; then
        printf '%sidentifier path check FAILED%s — a path is built from a value that was never validated, or by a validator that is not loaded.\n' "$RED" "$NC"
        return 1
    fi
    printf '%severy identifier that becomes a path is validated, by a validator this file loads%s\n' "$GREEN" "$NC"
}

wire_smoke() {
    printf '%sWire smoke...%s\n' "$YELLOW" "$NC"
    local rc=0
    assertion_lint || rc=1
    scan_caller_check || rc=1
    version_sync_check || rc=1
    validate_check || rc=1
    manifest_autoload_check || rc=1
    secret_scan || rc=1
    brand_scan || rc=1
    skill_lib_sync_check || rc=1
    rubric_sync_check || rc=1
    consent_caller_check || rc=1
    identifier_path_check || rc=1
    hook_source_stderr_check || rc=1
    return "$rc"
}

main() {
    local what="${1:-all}" rc=0
    case "$what" in
        self-check) self_check || rc=1 ;;
        unit) self_check || rc=1; run_suite || rc=1 ;;
        smoke) wire_smoke || rc=1 ;;
        mutation) consent_mutation_check || rc=1 ;;
        all) self_check || rc=1; run_suite || rc=1; wire_smoke || rc=1; consent_mutation_check || rc=1 ;;
        *) printf 'usage: run-tests.sh [all|unit|self-check|smoke|mutation]\n' >&2; return 2 ;;
    esac
    if [ "$rc" -eq 0 ]; then printf '%sPASS%s\n' "$GREEN" "$NC"; else printf '%sFAIL%s\n' "$RED" "$NC"; fi
    return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
