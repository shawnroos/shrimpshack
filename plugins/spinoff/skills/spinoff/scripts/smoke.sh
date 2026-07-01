#!/usr/bin/env bash
#
# smoke.sh — fast, dependency-free checks for spinoff.sh's arg-validation,
# session-transcript passthrough, and back-compat. Exercises everything that
# runs BEFORE the cmux automation (which is gated on CMUX_WORKSPACE_ID, unset
# here), so it needs no cmux and no real Claude session — just git.
#
# Run: bash smoke.sh   →   exits 0 if all checks pass, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SPINOFF="$HERE/spinoff.sh"
PASS=0 FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

# Isolated git repo + a handoff fixture; cmux automation disabled.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && git init -q && git config user.email s@s.s && git config user.name s \
    && git commit -q --allow-empty -m init ) || { echo "git setup failed"; exit 1; }
HANDOFF="$WORK/handoff.md"
printf '# Spinoff: smoke\n## Source session\n<!-- SESSION -->\n' > "$HANDOFF"
run() { ( cd "$WORK" && unset CMUX_WORKSPACE_ID && bash "$SPINOFF" "$@" 2>&1 ); }

echo "spinoff.sh smoke checks:"

# 1. Arg validation (each must exit non-zero).
run --handoff "$HANDOFF" >/dev/null 2>&1 && bad "missing --name should fail" || ok "missing --name rejected"
run --name a >/dev/null 2>&1 && bad "missing --handoff should fail" || ok "missing --handoff rejected"
run --name a --handoff /no/such/file >/dev/null 2>&1 && bad "missing handoff file should fail" || ok "missing handoff file rejected"
out="$(run --name a --handoff "$HANDOFF" --target bogus)"
echo "$out" | grep -q "invalid --target" && ok "invalid --target rejected with message" || bad "invalid --target not rejected: $out"

# 2. Explicit session passthrough → resume line uses the passed cwd + UUID.
touch "$WORK/sess.jsonl"
out="$(run --name feat-pass --handoff "$HANDOFF" --session-transcript "$WORK/sess.jsonl" --session-cwd /tmp/originating)"
resume="$(grep -h 'Resume:' "$WORK/worktrees/feat-pass/docs/handoff.md" 2>/dev/null)"
echo "$resume" | grep -q "cd /tmp/originating && claude -r sess" \
  && ok "resume line uses --session-cwd and transcript UUID" \
  || bad "resume line wrong: ${resume:-<none>}"

# 3. Missing --session-transcript file → warns (does not silently fall through).
out="$(run --name feat-warn --handoff "$HANDOFF" --session-transcript /tmp/nope-$$.jsonl)"
echo "$out" | grep -q "not found — falling back to auto-discovery" \
  && ok "missing --session-transcript warns loudly" \
  || bad "missing --session-transcript did not warn"

# 4. Back-compat: old-only flags still produce a worktree + handoff.
run --name feat-compat --handoff "$HANDOFF" >/dev/null 2>&1
[ -f "$WORK/worktrees/feat-compat/docs/handoff.md" ] \
  && ok "old-only flags still create worktree + handoff" \
  || bad "back-compat worktree/handoff missing"

# 5. Label default → "<repo-basename>/<name>" when --label omitted.
repo_base="$(basename "$WORK")"
out="$(run --name feat-deflabel --handoff "$HANDOFF")"
echo "$out" | grep -qE "label: +$repo_base/feat-deflabel" \
  && ok "label defaults to <repo>/<name>" \
  || bad "default label wrong: $(echo "$out" | grep -i 'label:' || echo '<none>')"

# 6. Explicit --label is used verbatim.
out="$(run --name feat-label --handoff "$HANDOFF" --label 'smoke·work')"
echo "$out" | grep -qE 'label: +smoke·work' \
  && ok "explicit --label used verbatim" \
  || bad "explicit label wrong: $(echo "$out" | grep -i 'label:' || echo '<none>')"

# 7. --repo roots the worktree in the named repo from a NON-repo cwd.
OUTSIDE="$(mktemp -d)"            # not a git repo
trap 'rm -rf "$WORK" "$OUTSIDE"' EXIT
run_out() { ( cd "$OUTSIDE" && unset CMUX_WORKSPACE_ID && bash "$SPINOFF" "$@" 2>&1 ); }
run_out --name feat-repo --handoff "$HANDOFF" --repo "$WORK" >/dev/null 2>&1
[ -f "$WORK/worktrees/feat-repo/docs/handoff.md" ] \
  && ok "--repo roots worktree in target repo from outside cwd" \
  || bad "--repo did not create worktree in target repo"

# 8. --repo with a nonexistent path fails clearly.
out="$(run_out --name feat-norepo --handoff "$HANDOFF" --repo /no/such/repo)"
echo "$out" | grep -q "repo path not found" \
  && ok "--repo nonexistent path rejected" \
  || bad "--repo nonexistent path not rejected: $out"

# 9. No --repo and cwd not a git repo → helpful failure naming --repo.
out="$(run_out --name feat-nogit --handoff "$HANDOFF")"
echo "$out" | grep -q -- "--repo" \
  && ok "non-repo cwd fails with a message naming --repo" \
  || bad "non-repo cwd failure did not mention --repo: $out"

# 10. --repo with a RELATIVE --handoff (cwd outside repo) → real body lands,
#     not the placeholder fallback (canonicalized before the cd).
printf '# Spinoff: rel\nBODY-MARKER\n## Source session\n<!-- SESSION -->\n' > "$OUTSIDE/rel-handoff.md"
( cd "$OUTSIDE" && unset CMUX_WORKSPACE_ID && bash "$SPINOFF" \
    --name feat-rel --handoff rel-handoff.md --repo "$WORK" ) >/dev/null 2>&1
grep -q "BODY-MARKER" "$WORK/worktrees/feat-rel/docs/handoff.md" 2>/dev/null \
  && ok "--repo + relative --handoff lands the real body" \
  || bad "--repo + relative --handoff lost the handoff body"

# 11. Stale base: a local branch behind its upstream warns (non-blocking).
# Build a behind-upstream state with local plumbing only (no network): point
# origin/feat one commit ahead of feat, and wire enough remote config that
# `feat@{upstream}` resolves (branch.* + a remote.origin fetch refspec).
base_sha="$(git -C "$WORK" rev-parse HEAD)"
ahead_sha="$(git -C "$WORK" commit-tree "HEAD^{tree}" -p "$base_sha" -m ahead)"
git -C "$WORK" branch feat "$base_sha"
git -C "$WORK" update-ref refs/remotes/origin/feat "$ahead_sha"
git -C "$WORK" config remote.origin.url .
git -C "$WORK" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$WORK" config branch.feat.remote origin
git -C "$WORK" config branch.feat.merge refs/heads/feat
out="$(run --name feat-stale --handoff "$HANDOFF" --base feat)"
echo "$out" | grep -q "behind" \
  && ok "stale local base (behind upstream) warns" \
  || bad "stale base did not warn: $out"
[ -d "$WORK/worktrees/feat-stale" ] \
  && ok "stale base warning is non-blocking (worktree still created)" \
  || bad "stale base blocked worktree creation"

# 12. Local branch with NO upstream → no stale warning (silent skip).
git -C "$WORK" branch noup "$base_sha"
out="$(run --name feat-noup --handoff "$HANDOFF" --base noup)"
echo "$out" | grep -q "behind" \
  && bad "no-upstream base should not warn: $out" \
  || ok "no-upstream local base does not warn"

# 13. Docs carry: the WHOLE docs/ tree is carried (nested + oddly-named +
#     uncommitted), not a name/recency-filtered slice; handoff.md is not re-copied.
mkdir -p "$WORK/docs/plans"
printf 'nested plan\n' > "$WORK/docs/plans/nested.md"      # nested subdir
printf 'assessment\n'  > "$WORK/docs/odd-name.md"          # non-plan name
printf 'wip\n'         > "$WORK/docs/handoff.md"           # must be SKIPPED
out="$(run --name feat-docs --handoff "$HANDOFF")"
WT="$WORK/worktrees/feat-docs"
[ -f "$WT/docs/plans/nested.md" ] && [ -f "$WT/docs/odd-name.md" ] \
  && ok "docs carry copies nested + oddly-named files recursively" \
  || bad "docs carry missed nested/oddly-named files"
# the carried docs/handoff.md must be the script-generated brief, not the source
# docs/handoff.md ('wip') — i.e. the source docs/handoff.md was skipped.
grep -q "Spinoff: smoke" "$WT/docs/handoff.md" 2>/dev/null && ! grep -qx "wip" "$WT/docs/handoff.md" 2>/dev/null \
  && ok "source docs/handoff.md not carried over the generated handoff" \
  || bad "docs/handoff.md was clobbered by the source copy"
echo "$out" | grep -qE "carried docs: [1-9]" \
  && ok "docs count reported non-zero" \
  || bad "docs count wrong: $(echo "$out" | grep -i 'carried docs' || echo '<none>')"
rm -rf "$WORK/docs"   # keep later fixtures clean

# 14. Dotfile carry + secret guard: an untracked .env (repo does NOT ignore it)
#     is carried, kept out of git via the exclude, and flagged in the handoff.
printf 'SECRET=1\n' > "$WORK/.env"
out="$(run --name feat-dotenv --handoff "$HANDOFF")"
WT="$WORK/worktrees/feat-dotenv"
[ -f "$WT/.env" ] \
  && ok "dotfile carry copies root .env into the worktree" \
  || bad "dotfile carry did not copy .env"
# exclude guard: .env must NOT show up as an untracked file in the worktree.
if git -C "$WT" status --porcelain 2>/dev/null | grep -q '\.env$'; then
  bad "carried .env is NOT excluded from git (exclude guard failed)"
else
  ok "carried .env kept out of git via info/exclude"
fi
grep -q "Security note" "$WT/docs/handoff.md" 2>/dev/null \
  && ok "handoff carries the security footnote when a dotfile was carried" \
  || bad "security footnote missing after dotfile carry"
echo "$out" | grep -qE "carried dotfiles: [1-9]" \
  && ok "dotfiles count reported non-zero" \
  || bad "dotfiles count wrong: $(echo "$out" | grep -i 'carried dotfiles' || echo '<none>')"
# exclude entry is ROOT-ANCHORED (/name), so it can't hide same-named files nested
# elsewhere in the repo or a sibling worktree.
excl="$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null)"
grep -qxF '/.env' "$excl" 2>/dev/null \
  && ok "exclude entry is root-anchored (/.env, not bare .env)" \
  || bad "exclude entry not root-anchored: $(grep -n env "$excl" 2>/dev/null || echo '<none>')"
rm -f "$WORK/.env"

# 14b. Multi-dotfile carry via the .env.* branch: .env + .env.local both carried,
#      both excluded (array path — a whitespace/glob name can't split the guard).
printf 'A=1\n' > "$WORK/.env"; printf 'B=2\n' > "$WORK/.env.local"
run --name feat-multidot --handoff "$HANDOFF" >/dev/null 2>&1
WT="$WORK/worktrees/feat-multidot"
[ -f "$WT/.env" ] && [ -f "$WT/.env.local" ] \
  && ok "dotfile carry copies both .env and .env.local (.env.* branch)" \
  || bad "multi-dotfile carry missed a file"
if git -C "$WT" status --porcelain 2>/dev/null | grep -qE '\.env(\.local)?$'; then
  bad "a carried dotfile is NOT excluded (multi-file guard failed)"
else
  ok "both carried dotfiles kept out of git"
fi
rm -f "$WORK/.env" "$WORK/.env.local"

# 15. No dotfiles → no footnote, dotfiles count zero (conditional footnote).
out="$(run --name feat-nodot --handoff "$HANDOFF")"
grep -q "Security note" "$WORK/worktrees/feat-nodot/docs/handoff.md" 2>/dev/null \
  && bad "security footnote appeared with no dotfile carried" \
  || ok "no security footnote when no dotfile carried"
echo "$out" | grep -qE "carried dotfiles: 0" \
  && ok "dotfiles count is 0 when none carried" \
  || bad "dotfiles count not zero: $(echo "$out" | grep -i 'carried dotfiles' || echo '<none>')"

# 16. Kickoff brevity: the KICKOFF string is short enough for one TUI paste and
#     the resubmit-guard match is a substring of its first line. (Static check —
#     a real cmux send is out of scope for the dependency-free smoke.)
kickoff_line="$(grep -m1 '^KICKOFF="' "$SPINOFF" | sed 's/^KICKOFF="//; s/"$//')"
klen=${#kickoff_line}
[ "$klen" -gt 0 ] && [ "$klen" -le 600 ] \
  && ok "KICKOFF is a short pointer ($klen chars, <=600)" \
  || bad "KICKOFF length out of range: $klen chars"
case "$kickoff_line" in
  "Read docs/handoff.md"*) ok "resubmit-guard substring matches KICKOFF first line" ;;
  *) bad "KICKOFF no longer starts with the resubmit-guard substring" ;;
esac

echo "-------------------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
