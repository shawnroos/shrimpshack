# Sourced by tests: a PATH-first fake per terminal host that replays recorded output.
# Fixtures: tests/fixtures/hosts/<host>/<scenario>/{match,rc,stdout,stderr}.
# `match` is an argv prefix, "contains:<text>" for osascript scripts, or "force-only" for a
# refusal that only HOST_FAKE_FORCE=<scenario> selects (the same args also succeed in real life).
# HOST_FAKE_OVERLAY="<scenario> ..." makes those scenarios win over a longer match, so one test can
# stage the same command (rex session ls --json) as empty, then as one session. A scenario with an
# `overlay-only` file never matches unless it is named there.
# Needs AUTO_ROOT; CALLS (optional) receives one "<binary> <args>" line per call.

HOST_FAKE_ROOT="${AUTO_ROOT}/tests/fixtures/hosts"
# host:binary — rex is not installed on every machine, and Ghostty is driven through osascript.
HOST_FAKE_REGISTRY="herdr:herdr rex:rex ghostty:osascript stub:stubhost"

host_fake_binary() {
  local pair
  for pair in $HOST_FAKE_REGISTRY; do
    [ "${pair%%:*}" = "$1" ] && { printf '%s\n' "${pair#*:}"; return 0; }
  done
  return 1
}

# host_fake_install <host> <bindir>: writes <bindir>/<binary>; the caller puts bindir first on PATH.
host_fake_install() {
  local host="$1" bindir="$2" bin
  bin="$(host_fake_binary "$host")" || return 1
  mkdir -p "$bindir"
  {
    printf '#!/bin/bash\nroot=%q/%q\n' "$HOST_FAKE_ROOT" "$host"
    cat <<'BODY'
args="$*"
[ -n "${CALLS:-}" ] && printf '%s %s\n' "$(basename "$0")" "$args" >> "$CALLS"
best=""
bestlen=-1
for d in "$root"/*/; do
  [ -f "${d}match" ] || continue
  m="$(head -1 "${d}match")"
  # An overlay-only scenario shares its match with a real capture, so it answers only when named.
  case " ${HOST_FAKE_OVERLAY:-} " in *" $(basename "$d") "*) ;; *) [ -f "${d}overlay-only" ] && continue ;; esac
  case "$m" in
    force-only) continue ;;
    contains:*) case "$args" in *"${m#contains:}"*) len=${#m} ;; *) continue ;; esac ;;
    *) case "$args" in "$m"|"$m "*) len=${#m} ;; *) continue ;; esac ;;
  esac
  case " ${HOST_FAKE_OVERLAY:-} " in *" $(basename "$d") "*) len=$((len + 10000)) ;; esac
  [ "$len" -gt "$bestlen" ] && { best="$d"; bestlen=$len; }
done
[ -n "${HOST_FAKE_FORCE:-}" ] && best="$root/$HOST_FAKE_FORCE/"
if [ -z "$best" ] || [ ! -d "$best" ]; then
  echo "host-fake: no fixture for: $args" >&2
  exit 99
fi
cat "${best}stdout"
cat "${best}stderr" >&2
exit "$(cat "${best}rc")"
BODY
  } > "${bindir}/${bin}"
  chmod +x "${bindir}/${bin}"
}

host_fake_scenarios() { local d; for d in "${HOST_FAKE_ROOT}/$1"/*/; do [ -d "$d" ] && basename "$d"; done; }
