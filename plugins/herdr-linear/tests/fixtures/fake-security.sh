#!/usr/bin/env bash
# fake-security.sh — stateful stand-in for /usr/bin/security in herdr-linear
# tests (U3).
#
# lib/secrets.sh is the plugin's only toucher of the Keychain. Pointing it at
# this script through HERDR_LINEAR_SECURITY_BIN (the HERDR_LINEAR_SLATE_ROOT
# seam precedent in contain.sh) lets the whole credential path run with no real
# Keychain, no unlock prompt, and no Linear key on this machine's login
# keychain.
#
# WHY IT RECORDS ARGV
# R27's whole claim is that the credential never appears in a process argument:
# `security add-generic-password -w <value>` puts it there, readable from the
# process table by any same-user process, so the write path feeds the value on
# STDIN to a trailing bare `-w` instead. A claim like that is worth exactly what
# asserts it, so this fixture writes down every argument it was invoked with —
# for EVERY subcommand, not just add — and secrets.bats asserts no fragment of
# the value is ever in that record.
#
# Records APPEND, never truncate: a write is immediately followed by a read-back
# and the assertions run across both invocations.
#
# FIDELITY THAT MATTERS (a fixture that smoothed any of these over would make
# the defence it is testing vacuous):
#   * a bare trailing `-w` reads the password from stdin, and it wants it TWICE
#     (value, then confirmation);
#   * fed only once, the real binary stores an EMPTY password and still exits 0
#     — exit status is worthless, read-back is the only proof of a write;
#   * `find-generic-password -w` prints only the password on stdout; `-g` prints
#     it to STDERR, which is why secrets.sh must never use it — so this fixture
#     implements `-g` faithfully rather than ignoring it;
#   * `delete-generic-password` removes ONE matching item per invocation, which
#     is the entire reason the delete path loops;
#   * exit 44 = no such item; exit 45 = item already exists (an add without -U).
#
# Environment:
#   FAKE_SECURITY_STORE_DIR   where items land   (default: $TMPDIR/fake-security-store)
#   FAKE_SECURITY_RECORD_DIR  where argv/stdin records land
#                             (default: $TMPDIR/fake-security-record)
#   FAKE_SECURITY_MODE        ok | silent_empty | duplicate | leak_argv
#                             ok           faithful (see above)
#                             silent_empty stores empty EVEN when fed twice —
#                                          the trap, forced, so the read-back
#                                          compare in secrets.sh is exercised
#                                          without relying on a mis-fed pipe
#                             duplicate    every add creates a NEW item instead
#                                          of updating, so the delete loop meets
#                                          the duplicates it exists for
#                             leak_argv    the PLANTED DEFECT: appends the
#                                          stdin-read secret to the argv record.
#                                          secrets.bats' self-test uses it to
#                                          see the "no secret in argv" assertion
#                                          go red (a detector never seen failing
#                                          is vacuous)

set -uo pipefail

MODE="${FAKE_SECURITY_MODE:-ok}"
STORE="${FAKE_SECURITY_STORE_DIR:-${TMPDIR:-/tmp}/fake-security-store}"
REC_DIR="${FAKE_SECURITY_RECORD_DIR:-${TMPDIR:-/tmp}/fake-security-record}"

mkdir -p "$STORE" "$REC_DIR"

# --- record the invocation (append-only, every subcommand) ------------------
{
  echo "--- invocation ---"
  for a in "$@"; do printf '%s\n' "$a"; done
} >> "$REC_DIR/argv"

SUBCMD="${1:-}"
shift || true

account=""
service=""
w_seen=0
w_value=""
g_seen=0

# The real binary's `-w` is positional-sensitive: `-w <value>` takes the next
# argument, a TRAILING bare `-w` reads stdin. Anything placed after a bare `-w`
# is swallowed as that value, which is why secrets.sh always puts it last.
while [ "$#" -gt 0 ]; do
  case "$1" in
    -a) account="${2:-}"; shift 2 || shift ;;
    -s) service="${2:-}"; shift 2 || shift ;;
    -g) g_seen=1; shift ;;
    -U) shift ;;
    -T|-A) shift ;;
    -w)
      w_seen=1
      if [ "$#" -gt 1 ]; then w_value="${2:-}"; shift 2; else shift; fi
      ;;
    *) shift ;;
  esac
done

# Item identity is service+account, hashed so a service or account holding a
# slash cannot escape the store directory.
key="$(printf '%s\n%s\n' "$service" "$account" | shasum | cut -d' ' -f1)"

items() {
  local f
  for f in "$STORE/$key".*; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

case "$SUBCMD" in
  add-generic-password)
    secret="$w_value"
    if [ "$w_seen" -eq 1 ] && [ -z "$w_value" ]; then
      # Bare trailing -w: read from stdin. The real binary wants the value and
      # a confirmation; fed only once it stores EMPTY and exits 0.
      line1=""; line2=""
      IFS= read -r line1 || true
      IFS= read -r line2 || true
      if [ -z "$line2" ] || [ "$line1" != "$line2" ]; then
        secret=""
      else
        secret="$line1"
      fi
    fi

    if [ "$MODE" = "leak_argv" ]; then
      # The plant. A real leak would be `-w "$secret"` landing in the argv line
      # above; this reproduces the OBSERVABLE consequence — the value present in
      # the argv record — without needing a broken caller.
      printf 'LEAKED -w %s\n' "$secret" >> "$REC_DIR/argv"
    fi
    [ "$MODE" = "silent_empty" ] && secret=""

    existing="$(items | head -n 1)"
    if [ "$MODE" = "duplicate" ] || [ -z "$existing" ]; then
      n=1
      while [ -e "$STORE/$key.$n" ]; do n=$((n + 1)); done
      printf '%s' "$secret" > "$STORE/$key.$n"
    else
      # -U semantics. Without -U the real binary refuses an existing item with
      # exit 45; secrets.sh always passes -U, and the argv record proves it.
      printf '%s' "$secret" > "$existing"
    fi
    exit 0
    ;;

  find-generic-password)
    found="$(items | head -n 1)"
    [ -z "$found" ] && exit 44
    if [ "$g_seen" -eq 1 ]; then
      # Faithful and forbidden: -g prints the password to STDERR. secrets.sh
      # never uses it, and secrets.bats asserts that against the source.
      printf 'password: "%s"\n' "$(cat "$found")" >&2
      printf 'keychain: "fake"\n'
      exit 0
    fi
    if [ "$w_seen" -eq 1 ]; then
      printf '%s\n' "$(cat "$found")"
    else
      # Attribute dump — no password. This is what the existence probe reads.
      printf 'keychain: "fake"\nclass: "genp"\n    "acct"<blob>="%s"\n    "svce"<blob>="%s"\n' \
        "$account" "$service"
    fi
    exit 0
    ;;

  delete-generic-password)
    found="$(items | head -n 1)"
    [ -z "$found" ] && exit 44
    # ONE item per invocation, like the real binary. A fixture that cleared
    # every match at once would let a loop-free delete pass the duplicates test.
    rm -f "$found"
    printf 'password has been deleted.\n'
    exit 0
    ;;

  *)
    printf 'fake-security: unsupported subcommand: %s\n' "$SUBCMD" >&2
    exit 2
    ;;
esac
