#!/usr/bin/env bash
# multi-slice-review — granularity rubric (U5).
#
# Reads prepass signals (F/D/L/RS as KEY=VALUE) on stdin and emits the sizing:
#   TIER, SLICE_TARGET (a soft target — the agent may exceed it),
#   RISK_LENSES (added by RS; base correctness+adversarial are implicit),
#   LENS_SKIPPED (skip-with-reason for un-added lenses, §3),
#   WAVE_CAP (min(16, cores-2), computed at runtime — never a hardcoded 8),
#   MAX_REVIEWERS (hard total ceiling), PROJECTED_AGENTS (clamped), CLAMP_NOTICE.
#
# The crisp sizing is here; the semantic cut (which files form each invariant)
# is the agent's judgment in the skill, not this script.

set -euo pipefail

MAX_REVIEWERS=64
CORES=""
SLICES_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cores) CORES="$2"; shift 2 ;;
        --slices) SLICES_OVERRIDE="$2"; shift 2 ;;
        *) echo "rubric: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

# Read signals from stdin.
F=0; D=0; L=0; RS=""
while IFS='=' read -r k v; do
    case "$k" in
        F) F="$v" ;; D) D="$v" ;; L) L="$v" ;; RS) RS="$v" ;;
    esac
done

[[ "$F" =~ ^[0-9]+$ ]] || { echo "rubric: missing/invalid F signal" >&2; exit 2; }
[[ "$D" =~ ^[0-9]+$ ]] || { echo "rubric: missing/invalid D signal" >&2; exit 2; }

# --- Tier + slice target (soft) ---
if [ "$D" -ge 5 ] || [ "$F" -ge 30 ]; then
    TIER=large; SLICE_TARGET=6
elif [ "$D" -le 2 ] && [ "$F" -le 8 ]; then
    TIER=small; SLICE_TARGET=3
else
    TIER=medium; SLICE_TARGET=4
fi

# --- Risk lenses from RS (base correctness+adversarial are always in play) ---
declare -a LENSES=()
case ",$RS," in *,destructive,*|*,untrusted,*|*,credentials,*) LENSES+=("security");; esac
case ",$RS," in *,concurrency,*|*,io,*) LENSES+=("reliability");; esac
case ",$RS," in *,api,*) LENSES+=("api-contract");; esac
RISK_LENSES=""
[ "${#LENSES[@]}" -gt 0 ] && RISK_LENSES="$(printf '%s\n' "${LENSES[@]}" | sort -u | paste -sd, -)"

# --- Skip-with-reason for un-added risk lenses (§3) ---
declare -a SKIPPED=()
case ",$RISK_LENSES," in *,security,*) ;; *) SKIPPED+=("security: no destructive/untrusted/credential surface");; esac
case ",$RISK_LENSES," in *,reliability,*) ;; *) SKIPPED+=("reliability: no concurrency/io surface");; esac
case ",$RISK_LENSES," in *,api-contract,*) ;; *) SKIPPED+=("api-contract: no changed signature detected");; esac
LENS_SKIPPED=""
[ "${#SKIPPED[@]}" -gt 0 ] && LENS_SKIPPED="$(printf '%s; ' "${SKIPPED[@]}" | sed 's/; $//')"

# --- Wave cap from cores (min(16, cores-2), floored at 1) ---
if [ -z "$CORES" ]; then
    CORES="$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4 )"
fi
avail=$((CORES - 2)); [ "$avail" -lt 1 ] && avail=1
WAVE_CAP=$avail; [ "$WAVE_CAP" -gt 16 ] && WAVE_CAP=16

# --- Projected total agent count (clamped to MAX_REVIEWERS) ---
slices="${SLICES_OVERRIDE:-$SLICE_TARGET}"
lenses_per_slice=$((2 + ${#LENSES[@]}))
seams=0; [ "$slices" -ge 2 ] && seams=$((slices - 1))
mutation_runs=$slices
projected=$((slices * lenses_per_slice + seams + mutation_runs))
CLAMP_NOTICE=""
if [ "$projected" -gt "$MAX_REVIEWERS" ]; then
    CLAMP_NOTICE="projected $projected reviewers exceeds MAX_REVIEWERS=$MAX_REVIEWERS; capped."
    PROJECTED_AGENTS=$MAX_REVIEWERS
else
    PROJECTED_AGENTS=$projected
fi

printf 'TIER=%s\n' "$TIER"
printf 'SLICE_TARGET=%s\n' "$SLICE_TARGET"
printf 'RISK_LENSES=%s\n' "$RISK_LENSES"
printf 'LENS_SKIPPED=%s\n' "$LENS_SKIPPED"
printf 'WAVE_CAP=%s\n' "$WAVE_CAP"
printf 'MAX_REVIEWERS=%s\n' "$MAX_REVIEWERS"
printf 'PROJECTED_AGENTS=%s\n' "$PROJECTED_AGENTS"
printf 'CLAMP_NOTICE=%s\n' "$CLAMP_NOTICE"
