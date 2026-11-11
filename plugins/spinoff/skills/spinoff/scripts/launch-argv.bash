# Shared by spinoff.bats and rex.bats: run the exact string a backend was handed, through
# a real shell, against a fake claude, and read back the argv claude received. Reading
# argv (not grepping the string) is what proves the JSON survived each backend's quoting.

# $1 = the shell command string a backend would run. Prints claude's argv, one per line.
launch_argv() {
  local bin="$BATS_TEST_TMPDIR/fake-claude-bin" out="$BATS_TEST_TMPDIR/claude-argv"
  mkdir -p "$bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$CLAUDE_ARGV_OUT"\n' > "$bin/claude"
  chmod +x "$bin/claude"
  rm -f "$out"
  CLAUDE_ARGV_OUT="$out" PATH="$bin:/usr/bin:/bin" sh -c "$1" || return 1
  cat "$out"
}

# $1 = claude's argv, one per line. Passes when --settings appears exactly once and its
# value is exactly the launch settings JSON (Remote Control off).
assert_remote_control_off() {
  local argv="$1"
  [ "$(grep -cxF -- '--settings' <<<"$argv")" -eq 1 ] || { echo "want one --settings, argv was:"; echo "$argv"; return 1; }
  local val
  val="$(awk 'prev == "--settings" { print; exit } { prev = $0 }' <<<"$argv")"
  [ "$val" = '{"remoteControlAtStartup":false}' ] || { echo "--settings value was: $val"; return 1; }
}
