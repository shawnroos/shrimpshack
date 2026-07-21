#!/usr/bin/env bash
# multi-slice-review — deterministic pre-pass (U4).
#
# Emits fixed signals from `git diff <base>` for the rubric to consume:
#   F  = files changed
#   D  = distinct subsystems (top-1/2 path segments; root files → ".")
#   L  = lines changed (added + deleted)
#   RS = sorted, comma-joined risk-surface set (empty if none)
#
# Prove by execution, not string-matching: the base must be given and resolvable,
# and the diff must be non-empty — otherwise fail loudly rather than emit a
# zero-signal blob that reads as "small change" (env-trap discipline, §4.3).

set -euo pipefail

die() { echo "prepass: $*" >&2; exit 2; }

BASE="${1:-}"
[ -n "$BASE" ] || die "no base ref given (usage: prepass.sh <base-ref>). Refusing to silently diff HEAD."
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 || die "base ref '$BASE' is not a resolvable commit."

# --no-color (git colorizes even to a pipe under color.ui=always, which would make
# the RS grep below match nothing), rename-aware (-M) so a moved file counts once.
numstat="$(git diff --no-color -M --numstat "$BASE" -- 2>/dev/null || true)"
[ -n "$numstat" ] || die "empty diff against '$BASE' — nothing to review."

# Resolve a numstat path field to its effective (new) path, handling rename forms
# 'old => new' and 'dir/{old => new}/rest'.
resolve_path() {
    local p="$1"
    if [[ "$p" == *"=>"* ]]; then
        p="$(printf '%s' "$p" | sed -E 's/\{[^}]*=> ([^}]*)\}/\1/; s/.*=> //; s#//#/#g')"
    fi
    printf '%s' "$p"
}

# top-1/2 path segments; a root file (no dir) → "."
subsystem() {
    local p="$1" dir
    dir="$(dirname "$p")"
    if [ "$dir" = "." ]; then printf '.'; return; fi
    printf '%s' "$dir" | awk -F/ '{ if (NF>=2) print $1"/"$2; else print $1 }'
}

F=0
L=0
declare -A seen_sub=()
while IFS=$'\t' read -r added deleted path; do
    [ -n "${path:-}" ] || continue
    F=$((F + 1))
    # binary files show '-' for counts; treat as 0
    [[ "$added" =~ ^[0-9]+$ ]] || added=0
    [[ "$deleted" =~ ^[0-9]+$ ]] || deleted=0
    L=$((L + added + deleted))
    sub="$(subsystem "$(resolve_path "$path")")"
    seen_sub["$sub"]=1
done <<< "$numstat"
D=${#seen_sub[@]}

# Risk surfaces — matched over added/removed content lines only (exclude diff headers).
content="$(git diff --no-color -M "$BASE" -- | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true)"
declare -a RS=()
has() { printf '%s' "$content" | grep -qiE "$1"; }
# Destructive: fail-CLOSED — broad on purpose (a missed destructive form is a
# fail-open on the security gate). Covers long rm flags, DROP DATABASE/SCHEMA,
# TRUNCATE, and common ORM deletes in addition to the basics.
has '(\bDELETE[[:space:]]+FROM\b|\bDROP[[:space:]]+(TABLE|DATABASE|SCHEMA)\b|\bTRUNCATE\b|\brm[[:space:]]+-[a-z]*[rf]|\brm[[:space:]]+--(recursive|force)|\bunlink\b|shutil\.rmtree|os\.remove|fs\.unlink|\.delete\(|\.deleteMany\b|\.destroy_all\b)' && RS+=("destructive")
has '(password|secret|api[_-]?key|\btoken\b|credential|authorization|bearer)' && RS+=("credentials")
has '(\bthreading\b|\bmutex\b|\bLock\(|goroutine|\bsync\.|\batomic\b|Promise\.all|asyncio|\basync\b|\bawait\b)' && RS+=("concurrency")
has '(requests\.|urllib|\bsocket\b|fetch\(|https?://|readFile|writeFile|\bfs\.|\bopen\()' && RS+=("io")
has '(JSON\.parse|\beval\(|\bexec\(|subprocess|req\.body|request\.body|params\[)' && RS+=("untrusted")
printf '%s' "$content" | grep -qE '^[+-].*(def |function |export function|export const |public )' && RS+=("api")

RS_SORTED=""
if [ "${#RS[@]}" -gt 0 ]; then
    RS_SORTED="$(printf '%s\n' "${RS[@]}" | sort -u | paste -sd, -)"
fi

printf 'F=%s\n' "$F"
printf 'D=%s\n' "$D"
printf 'L=%s\n' "$L"
printf 'RS=%s\n' "$RS_SORTED"
