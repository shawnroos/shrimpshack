# shellcheck shell=bash
# Synthetic git fixtures for the code-preservation tests. Sourced after WORK, PY and AUTO_ROOT are set.

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${WORK}/fixture-gitconfig"
printf '[user]\n\tname = fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[advice]\n\tdetachedHead = false\n' > "$GIT_CONFIG_GLOBAL"
DRIVER="${AUTO_ROOT}/tests/helpers/preserve_driver.py"

# The system git, so a user wrapper on PATH never runs inside the fixtures.
GIT_BIN="$(for c in /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do [ -x "$c" ] && { echo "$c"; break; }; done)"
g() { "${GIT_BIN:-git}" "$@"; }

pp() { "$PY" "$DRIVER" "$AUTO_ROOT" "$@" 2>&1; }

# field <json> <key> -> value (lists joined by ','; missing -> empty)
field() {
  "$PY" -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError:
    print("NOT-JSON:" + sys.argv[1][:300]); raise SystemExit
v = d.get(sys.argv[2])
print(",".join(map(str, v)) if isinstance(v, list) else ("" if v is None else v))' "$1" "$2"
}

mkrepo() {
  mkdir -p "$1"
  g -C "$1" init -q
  printf 'one\n' > "$1/a.txt"
  g -C "$1" add a.txt
  g -C "$1" commit -qm base
}

# A repo holding every AE3 shape: a local-only commit, a binary change, staged/unstaged
# divergence, an untracked file, deletions, an executable, symlinks and unusual names.
mkrich() {
  local d="$1"
  mkrepo "$d"
  printf '\000\001binary-v1\377' > "$d/img.bin"
  printf '#!/bin/sh\necho hi\n' > "$d/run.sh"; chmod +x "$d/run.sh"
  ln -s a.txt "$d/link"
  ln -s ../../outside/target "$d/dangling"
  printf 'gone\n' > "$d/gone.txt"
  printf 'staged gone\n' > "$d/staged-gone.txt"
  printf 'tab\n' > "$d/$(printf 'we ird\tname.txt')"
  printf 'nl\n' > "$d/$(printf 'line\nbreak.txt')"
  printf 'dash\n' > "$d/-dash.txt"
  printf 'nfd\n' > "$d/$(printf 'cafe\314\201.txt')"
  mkdir -p "$d/deep/er"; printf 'deep\n' > "$d/deep/er/f.txt"
  g -C "$d" add -A
  g -C "$d" commit -qm "local only"
  printf '\000\002binary-v2\376' > "$d/img.bin"
  printf 'staged\n' > "$d/a.txt"; g -C "$d" add a.txt
  printf 'unstaged\n' > "$d/a.txt"
  rm "$d/gone.txt"
  g -C "$d" rm -q staged-gone.txt
  printf 'untracked\n' > "$d/new.txt"
  mkdir -p "$d/newdir"; printf 'u2\n' > "$d/newdir/u.txt"
}

# A repo mid-merge with conflict stages 1, 2 and 3 on c.txt.
mkconflict() {
  local d="$1"
  mkrepo "$d"
  printf 'base\n' > "$d/c.txt"; g -C "$d" add c.txt; g -C "$d" commit -qm c-base
  g -C "$d" checkout -q -b other
  printf 'theirs\n' > "$d/c.txt"; g -C "$d" commit -qam theirs
  g -C "$d" checkout -q main
  printf 'ours\n' > "$d/c.txt"; g -C "$d" commit -qam ours
  g -C "$d" merge -q other >/dev/null 2>&1 || true
}

# Digest of every file under a git dir (names and bytes): equal before and after means untouched.
gitdir_digest() {
  local gd
  gd="$(g -C "$1" rev-parse --path-format=absolute --git-common-dir)"
  (cd "$gd" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) | shasum -a 256 | cut -c1-64
}

# Digest of the worktree (names, modes, bytes, symlink targets), excluding .git.
tree_digest() {
  "$PY" - "$1" <<'PYEOF'
import hashlib, os, stat, sys
root = os.fsencode(sys.argv[1])
h = hashlib.sha256()
for dirpath, dirs, files in os.walk(root):
    dirs[:] = sorted(d for d in dirs if d != b".git")
    for name in sorted(files + [d for d in dirs if os.path.islink(os.path.join(dirpath, d))]):
        if dirpath == root and name == b".git":
            continue
        p = os.path.join(dirpath, name)
        st = os.lstat(p)
        h.update(os.path.relpath(p, root) + b"\0" + str(st.st_mode & 0o100111).encode())
        h.update(os.readlink(p) if stat.S_ISLNK(st.st_mode) else open(p, "rb").read())
print(h.hexdigest())
PYEOF
}

# Index as git reports it, with NUL bytes made visible.
index_listing() { g -C "$1" ls-files -s -z | tr '\0' '\n'; }
