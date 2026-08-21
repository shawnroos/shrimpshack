#!/usr/bin/env bash
# Scoped comment-bloat detector. Advisory only: it reports the mechanically-detectable
# classes and stays silent on everything else, because it cannot judge load-bearing.
# A clean run is NOT evidence the bar was met.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/check.py" "$@"
