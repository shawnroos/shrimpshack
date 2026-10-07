#!/bin/sh
[ -f "${0%/*}/fake.env" ] && . "${0%/*}/fake.env"
{ printf 'bt'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FAKE_CALLS:-/dev/null}"
[ -n "${FAKE_BT_NOAUTH:-}" ] && { cat "${FAKE_FIXTURES}/bt-no-credential-real.json"; exit 2; }
[ -n "${FAKE_BT_MISSING:-}" ] && { printf '{"error":{"message":"experiment not found: %s"}}\n' "$3"; exit 1; }
case "$1 $2" in
  "experiments view") printf '{"id":"e-123","name":"%s","project_id":"p-1"}\n' "$3" ;;
  *) echo "fake bt: unhandled $*" >&2; exit 2 ;;
esac
