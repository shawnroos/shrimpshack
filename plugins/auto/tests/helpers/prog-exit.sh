# Exits 97 and 98 come from tests/fixtures/prog_offered.py and mean the verb never ran, so a case that asserts only
# non-zero would pass on them with the verb's own refusal gone.
prog_exit_check() {
  case "$CODE" in
    97) [ -n "${OFFER_REFUSAL:-}" ] || fail "the offer refused, so the verb never ran: $* => $OUT" ;;
    98) fail "prog_offered.py failed, so the verb never ran: $* => $OUT" ;;
  esac
  return "$CODE"
}

offer_refused() {
  local text="$1"
  shift
  OFFER_REFUSAL=1 prog "$@"
  if [ "$CODE" = 97 ] && case "$OUT" in *"$text"*) true ;; *) false ;; esac; then
    pass
  else
    fail "expected the offer to refuse with [$text], got exit $CODE: $OUT"
  fi
}
