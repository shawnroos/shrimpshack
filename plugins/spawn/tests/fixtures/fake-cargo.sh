#!/usr/bin/env bash
# fake-cargo.sh — stand-in for `cargo` on the setup acquire path (U2).
#
# Upstream ships no prebuilt binaries, so setup has to build from source
# (KTD16's companion fact). A real `cargo build --release` of the gateway takes
# minutes and needs a toolchain, which would make this suite untestable on a
# fresh box and unusably slow everywhere else. Pointing lib/setup.sh at this
# script through SPAWN_CARGO_BIN keeps the whole acquire path exercised end to
# end — fetch, extract, build, promote — with the build reduced to writing the
# one artifact the rest of the path consumes.
#
# It writes the binary at target/release/gateway RELATIVE TO ITS OWN CWD, which
# is what makes it an honest stand-in: if setup ever stopped running the build
# inside the staging directory, the artifact would land somewhere else and
# promotion would fail, exactly as a real cargo would fail.
#
# Environment:
#   FAKE_CARGO_RECORD_DIR  where the argv/cwd records land
#                          (default: $TMPDIR/fake-cargo-record)
#   FAKE_CARGO_MODE        ok | fail | pause   (default: ok)
#                          fail exits 101 (cargo's build-failure status) with
#                               stderr and writes NO artifact
#                          pause writes $REC_DIR/started, then blocks until
#                               $FAKE_CARGO_RELEASE exists before behaving as
#                               ok. This is the instrument for the KTD4
#                               assertion: it holds the build open so a
#                               concurrent `spawnctl.sh status` can be run
#                               while the staging directory is on disk.
#   FAKE_CARGO_RELEASE     the control file `pause` waits for
#                          (default: $REC_DIR/release)
#   FAKE_CARGO_PAUSE_LIMIT bound on the wait, in tenths of a second
#                          (default 600 = 60s). Bounded because a fixture that
#                          can hang forever turns a broken test into a wedged
#                          suite with no output.

set -uo pipefail

MODE="${FAKE_CARGO_MODE:-ok}"
REC_DIR="${FAKE_CARGO_RECORD_DIR:-${TMPDIR:-/tmp}/fake-cargo-record}"
RELEASE_FILE="${FAKE_CARGO_RELEASE:-$REC_DIR/release}"
PAUSE_LIMIT="${FAKE_CARGO_PAUSE_LIMIT:-600}"

mkdir -p "$REC_DIR"

{
  echo "--- invocation ---"
  for a in "$@"; do printf '%s\n' "$a"; done
} >> "$REC_DIR/argv"
printf '%s\n' "$PWD" >> "$REC_DIR/cwd"

if [ "$MODE" = "fail" ]; then
  printf 'error: could not compile `gateway` (fixture: FAKE_CARGO_MODE=fail)\n' >&2
  exit 101
fi

if [ "$MODE" = "pause" ]; then
  printf '%s\n' "$PWD" >> "$REC_DIR/started"
  i=0
  while [ ! -e "$RELEASE_FILE" ]; do
    i=$((i + 1))
    if [ "$i" -gt "$PAUSE_LIMIT" ]; then
      printf 'fake-cargo: pause was never released\n' >&2
      exit 101
    fi
    sleep 0.1
  done
fi

mkdir -p "$PWD/target/release"
cat > "$PWD/target/release/gateway" <<'STUB'
#!/usr/bin/env bash
# Stub gateway binary written by fake-cargo.sh. It answers --version and --help
# with exit 0 because that is the pair lib/setup.sh probes to decide whether an
# existing install is runnable; anything else is a no-op success.
case "${1:-}" in
  --version) printf 'gateway 9.9.9 (fixture build)\n' ;;
  --help)    printf 'usage: gateway --config <path>\n' ;;
  *)         printf 'fixture gateway invoked: %s\n' "$*" ;;
esac
exit 0
STUB
chmod +x "$PWD/target/release/gateway"
exit 0
