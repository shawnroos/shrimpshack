#!/usr/bin/env bash
# fake-curl.sh — stand-in for `curl` on the setup acquire path (U2).
#
# KTD16 resolves the gateway release through the public GitHub API and fetches
# the source tarball over HTTPS. Pointing lib/setup.sh at this script through
# SPAWN_CURL_BIN lets that whole path run with no network: no rate limit, no
# dependence on what upstream published today, and — the assertion that matters
# — a RECORD of every URL the script asked for, so "the skip path makes exactly
# one network call" is provable rather than asserted.
#
# It answers three request shapes, matched on a substring of the URL:
#   */releases/latest   the release object, carrying tag_name
#   */commits/<ref>     the commit object, carrying sha
#   *.tar.gz            the source archive: copied to the -o path
# Anything else is a 404-shaped failure (exit 22, curl's --fail status), because
# a fixture that cheerfully answers a URL the script should never request is how
# a wrong-endpoint bug reads as green.
#
# Records APPEND, never truncate: the acquire path calls curl up to three times
# in one invocation, and the tests assert across the whole sequence AND on the
# COUNT of calls.
#
# Environment:
#   FAKE_CURL_RECORD_DIR   where the url/argv records land
#                          (default: $TMPDIR/fake-curl-record)
#   FAKE_CURL_TAG          tag_name served by the release lookup (default v9.9.9)
#   FAKE_CURL_SHA          sha served by the commit lookup
#   FAKE_CURL_TARBALL      path to the file served as the source archive; the
#                          test builds a real .tar.gz in its own $WORK, so
#                          --strip-components is exercised for real rather than
#                          stubbed
#   FAKE_CURL_MODE         ok | fail_release | fail_commit | fail_download |
#                          bad_release_json   (default: ok)
#                          fail_* exits 22 on that one request shape and serves
#                          the others normally, so each failure can be isolated.
#                          bad_release_json serves a body with no tag_name — the
#                          shape an upstream API change actually produces.

set -uo pipefail

MODE="${FAKE_CURL_MODE:-ok}"
REC_DIR="${FAKE_CURL_RECORD_DIR:-${TMPDIR:-/tmp}/fake-curl-record}"
TAG="${FAKE_CURL_TAG:-v9.9.9}"
SHA="${FAKE_CURL_SHA:-0123456789abcdef0123456789abcdef01234567}"
TARBALL="${FAKE_CURL_TARBALL:-}"

mkdir -p "$REC_DIR"

# --- parse the argv shapes lib/setup.sh uses -------------------------------
# The URL is the last argument that does not begin with a dash and is not the
# value of -o. Everything else is recorded but not interpreted.
url=""
outfile=""
prev=""
for a in "$@"; do
  case "$prev" in
    -o|--output) outfile="$a"; prev=""; continue ;;
  esac
  case "$a" in
    -*) prev="$a" ;;
    *)  case "$prev" in
          --max-time|--connect-timeout|-H|--header) : ;;
          *) url="$a" ;;
        esac
        prev="" ;;
  esac
done

{
  echo "--- invocation ---"
  for a in "$@"; do printf '%s\n' "$a"; done
} >> "$REC_DIR/argv"
printf '%s\n' "$url" >> "$REC_DIR/urls"

case "$url" in
  */releases/latest)
    [ "$MODE" = "fail_release" ] && exit 22
    if [ "$MODE" = "bad_release_json" ]; then
      printf '{"message":"Not Found"}\n'
      exit 0
    fi
    printf '{"tag_name":"%s","name":"%s","draft":false,"prerelease":false}\n' "$TAG" "$TAG"
    exit 0
    ;;
  *.tar.gz)
    [ "$MODE" = "fail_download" ] && exit 22
    [ -n "$TARBALL" ] && [ -f "$TARBALL" ] || {
      printf 'fake-curl: FAKE_CURL_TARBALL is unset or missing\n' >&2
      exit 22
    }
    if [ -n "$outfile" ]; then
      cat "$TARBALL" > "$outfile"
    else
      cat "$TARBALL"
    fi
    exit 0
    ;;
  */commits/*)
    [ "$MODE" = "fail_commit" ] && exit 22
    printf '{"sha":"%s","commit":{"message":"fixture"}}\n' "$SHA"
    exit 0
    ;;
  *)
    printf 'fake-curl: no fixture for URL: %s\n' "$url" >&2
    exit 22
    ;;
esac
