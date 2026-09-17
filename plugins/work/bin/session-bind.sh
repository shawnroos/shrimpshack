#!/usr/bin/env bash
# The bind popup, typed into by a person (KTD6).
#
#   session-bind.sh        ask which scope this herdr session binds to
#   session-bind.sh open   open this script as herdr's bind popup (the bind action)
#
# This and /work:bind are the only places a session binding is confirmed.
set -u
LIB="${BASH_SOURCE[0]%/*}/../lib"
for f in sanitize.sh secrets.sh linear.sh session.sh binding.sh scope-linear.sh session-binding.sh; do
    . "$LIB/$f" || exit 1
done

if [ "${1:-}" = open ]; then
    [ -n "${HERDR_PLUGIN_ID:-}" ] || { echo "not run by herdr: no plugin id" >&2; exit 1; }
    exec "${HERDR_BIN_PATH:-herdr}" plugin pane open --plugin "$HERDR_PLUGIN_ID" --entrypoint bind >/dev/null
fi

done_after() {
    printf '%s\n' "$1"
    sleep "${HL_POPUP_PAUSE:-2}"
    exit 0
}

session="$(herdr_linear::session_name)" || done_after "This is not a herdr session, so there is nothing to bind."
printf 'herdr session: %s\n' "$session"
current="$(herdr_linear::session_scope 2>/dev/null | cut -f1,3 | tr '\t' ' ' | herdr_linear::sanitize_stream)"
printf 'bound to: %s\n\n' "${current:-nothing}"

printf 'Bind this session to:\n  1  the organization\n  2  a team\n  3  a project\n  4  an initiative\nChoose a number, or press Enter to leave it for now: '
IFS= read -r choice || choice=""
case "$choice" in
    1) kind=organization ;;
    2) kind=team ;;
    3) kind=project ;;
    4) kind=initiative ;;
    *) done_after "Nothing was changed. Run /work:bind or the bind action when you want to bind it." ;;
esac

candidates="$(herdr_linear::scope_candidates "$kind")" || done_after "Linear could not be read, so nothing was changed."
[ -n "$candidates" ] || done_after "Linear has no $kind to bind to. Nothing was changed."
printf '%s\n' "$candidates" | cut -f3 | herdr_linear::sanitize_stream | nl -w3 -s'  '
printf 'Choose a number: '
IFS= read -r pick || pick=""
case "$pick" in ''|*[!0-9]*) done_after "Nothing was changed." ;; esac
line="$(printf '%s\n' "$candidates" | sed -n "${pick}p")"
[ -n "$line" ] || done_after "There is no choice $pick. Nothing was changed."
IFS=$'\t' read -r _ scope_id scope_name <<<"$line"

outside="$(herdr_linear::session_rebind_preview "$kind" "$scope_id" 2>/dev/null | herdr_linear::sanitize_stream)"
if [ -n "$outside" ]; then
    printf '\nBound to this scope, these would be reported as outside the session (nothing is moved):\n%s\n' \
        "$(printf '%s\n' "$outside" | awk -F'\t' '{print "  " $1 ": " $2 " " $3 " (" $4 ")"}')"
fi

printf '\nBind session %s to %s %s? [y/N] ' "$session" "$kind" "$(printf '%s' "$scope_name" | herdr_linear::sanitize_stream)"
IFS= read -r answer || answer=""
nonce="$(herdr_linear::session_binding_propose "$session" "$kind" "$scope_id" "$scope_name")" \
    || done_after "The binding could not be recorded. Nothing was changed."
case "$answer" in
    y|Y|yes|Yes)
        herdr_linear::session_binding_confirm "$session" "$nonce" \
            || done_after "The binding could not be recorded."
        done_after "Session $session is bound to $kind $(printf '%s' "$scope_name" | herdr_linear::sanitize_stream)." ;;
    *)
        herdr_linear::session_binding_decline "$session" "$nonce" >/dev/null 2>&1
        done_after "Not bound. This session will not ask again; run /work:bind or the bind action to bind it later." ;;
esac
