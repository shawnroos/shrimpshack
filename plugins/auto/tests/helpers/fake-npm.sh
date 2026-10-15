#!/bin/sh
[ -f "${0%/*}/fake.env" ] && . "${0%/*}/fake.env"
{ printf 'npm'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FAKE_CALLS:-/dev/null}"
printf 'npm-env %s\n' "$(env | cut -d= -f1 | sort | tr '\n' ' ')" >> "${FAKE_CALLS:-/dev/null}"
printf 'npm-cwd %s\n' "$(pwd -P)" >> "${FAKE_CALLS:-/dev/null}"
if [ -n "${FAKE_NPM_404:-}" ]; then
  printf '{\n  "error": {\n    "code": "E404",\n    "summary": "No match found for version 9.9.9"\n  }\n}\n'
  echo 'npm error code E404' >&2
  exit 1
fi
[ -n "${FAKE_NPM_EXIT:-}" ] && { echo 'npm error code ENOTFOUND' >&2; exit "$FAKE_NPM_EXIT"; }
case "$1" in
  view) cat "$FAKE_NPM_VIEW" ;;
  *) echo "fake npm: unhandled $*" >&2; exit 2 ;;
esac
