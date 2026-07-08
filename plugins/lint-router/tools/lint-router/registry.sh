#!/usr/bin/env bash
# Thin shim → registry.py (pins python3; mirrors auto's ledger.sh). All JSON +
# predicate logic lives in registry.py — this just locates it and forwards argv.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="/usr/bin/python3"; command -v "$PY" >/dev/null 2>&1 || PY="$(command -v python3)"
exec "$PY" "$DIR/registry.py" "$@"
