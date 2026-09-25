#!/usr/bin/env bash
# One unattended board sync, for an agent that was told the board is behind.
#
#   board-sync.sh
#
# The sync itself lives in lib/board-sync.sh. It is here as its own file rather
# than a run-guard inside that library because the library is sourced by a shell
# whose $0 is whatever the caller passed: a guard on "$0" fired on the sync's own
# verb calls and re-entered the sync on every one of them.
set -u
. "${BASH_SOURCE[0]%/*}/../lib/board-sync.sh"
herdr_linear::board_sync
