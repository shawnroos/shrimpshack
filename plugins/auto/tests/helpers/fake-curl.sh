#!/bin/sh
[ -f "${0%/*}/fake.env" ] && . "${0%/*}/fake.env"
headers="$(cat)"
body=""
prev=""
for a in "$@"; do
  [ "$prev" = "--data-binary" ] && body="$a"
  prev="$a"
done
{ printf 'curl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FAKE_CALLS:-/dev/null}"
printf 'curl-parent %s\n' "$(ps -o args= -p "$PPID" 2>/dev/null)" >> "${FAKE_CALLS:-/dev/null}"
printf 'curl-env %s\n' "$(env | cut -d= -f1 | sort | tr '\n' ' ')" >> "${FAKE_CALLS:-/dev/null}"
case "$headers" in
  "Authorization: ${LINEAR_API_KEY:-unset-key}") echo "curl-auth-on-stdin" >> "${FAKE_CALLS:-/dev/null}" ;;
esac
if [ -n "${FAKE_CURL_LEAK:-}" ]; then
  echo "401 for key ${LINEAR_API_KEY:-}" >&2
  exit 22
fi
case "$body" in
  *'$number:Int!'*) cat "$FAKE_FIXTURES/linear-int-refusal.json"; exit 0 ;;
esac
case "$body" in
  *'team:{key:{eq:$team}}'*'number:{eq:$number}'*) cat "${FAKE_LINEAR_HIT:-$FAKE_FIXTURES/linear-hit.json}" ;;
  *) cat "$FAKE_FIXTURES/linear-other-team-page.json" ;;
esac
