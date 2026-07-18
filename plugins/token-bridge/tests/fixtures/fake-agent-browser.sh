#!/usr/bin/env bash
# fake-agent-browser.sh — stand-in for `agent-browser` in wcs-paper harvest unit
# tests. harvest.py invokes whatever $WCS_PAPER_AGENT_BROWSER points at, so pointing
# it here lets the whole harvest path run with NO live server or real browser.
#
# Behaviour is driven by env vars:
#   FAKE_MODE       unreachable | notfound | ok   (default: ok)
#   FAKE_EVAL_FILE  path to a JSON file emitted for the `eval` subcommand in ok mode
#                   (default: the sibling harvest-tree.json)
#
# It figures out the subcommand (open / eval / click / wait / ...) by skipping the
# leading global flags (--profile <name>, --json, other --flags), exactly as
# harvest.py builds its arg lists.

set -euo pipefail

MODE="${FAKE_MODE:-ok}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_FILE="${FAKE_EVAL_FILE:-$HERE/harvest-tree.json}"

# Locate the subcommand: first bareword after skipping --profile <val> / --flags.
sub=""
skip_next=0
for a in "$@"; do
  if [[ "$skip_next" -eq 1 ]]; then
    skip_next=0
    continue
  fi
  case "$a" in
    --profile) skip_next=1; continue ;;
    --*) continue ;;
    *) sub="$a"; break ;;
  esac
done

case "$sub" in
  open)
    if [[ "$MODE" == "unreachable" ]]; then
      echo "net::ERR_CONNECTION_REFUSED at http://localhost:4200" >&2
      exit 1
    fi
    exit 0
    ;;
  eval)
    if [[ "$MODE" == "notfound" ]]; then
      # Simulate the selector matching nothing: eval yields a null result.
      echo "null"
      exit 0
    fi
    cat "$EVAL_FILE"
    exit 0
    ;;
  *)
    # Trigger steps (click / wait / etc.) — succeed quietly.
    exit 0
    ;;
esac
