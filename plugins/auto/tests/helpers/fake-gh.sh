#!/bin/sh
[ -f "${0%/*}/fake.env" ] && . "${0%/*}/fake.env"
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FAKE_CALLS:-/dev/null}"
printf 'gh-env %s\n' "$(env | cut -d= -f1 | sort | tr '\n' ' ')" >> "${FAKE_CALLS:-/dev/null}"
[ -n "${FAKE_GH_SLEEP:-}" ] && sleep "$FAKE_GH_SLEEP"
[ -n "${FAKE_GH_EXIT:-}" ] && { printf 'HTTP 401: Requires authentication (https://api.github.com/graphql)\nTry authenticating with:  gh auth login -h github.com\n' >&2; exit "$FAKE_GH_EXIT"; }
[ -n "${FAKE_GH_EMPTY:-}" ] && exit 0
case "$1 $2" in
  "pr view") cat "$FAKE_GH_VIEW" ;;
  "api graphql") cat "$FAKE_GH_GRAPHQL" ;;
  *) echo "fake gh: unhandled $*" >&2; exit 2 ;;
esac
