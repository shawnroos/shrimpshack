#!/usr/bin/env bash
# The herdr startup hook: ask an unbound session to bind (KTD6).
#
# herdr runs this once per server start, with no person watching, in every
# server the person starts while the plugin is linked. So it only opens the
# question, at most once per session name, and never proposes or records an
# answer. A popup opened before any client attaches is shown when one does
# (docs/session-spikes.md). Every path exits 0: a start must never fail on this.
set -u
LIB="${BASH_SOURCE[0]%/*}/../lib"
for f in sanitize.sh session.sh binding.sh session-binding.sh; do
    . "$LIB/$f" 2>/dev/null || exit 0
done

[ -n "${HERDR_PLUGIN_ID:-}" ] || exit 0
[ -e "${HERDR_PLUGIN_CONFIG_DIR:-/nonexistent}/no-ask" ] && exit 0
session="$(herdr_linear::session_name 2>/dev/null)" || exit 0
herdr_linear::session_binding_should_ask "$session" 2>/dev/null || exit 0
"${HERDR_BIN_PATH:-herdr}" plugin pane open --plugin "$HERDR_PLUGIN_ID" --entrypoint bind >/dev/null 2>&1 || exit 0
herdr_linear::session_binding_mark_asked "$session" >/dev/null 2>&1
exit 0
