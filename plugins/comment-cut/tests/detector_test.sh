# detector_test.sh — the checker's own contract.
#
# Two things matter here and they pull against each other: the detector must
# stay advisory on its default path (exit 0 always, so it can never block a
# commit), and it must give the gate a machine-readable signal. --porcelain is
# that second read-out; these assertions are what keep the two apart.

_d="$(mktemp -d "${TMPDIR:-/tmp}/cc-detector.XXXXXX")"
trap 'rm -rf "$_d"' RETURN

cat > "$_d/bad.ts" <<'EOF'
// ===== HELPERS =====
const a = 1;
// const cached = buildThing();
EOF

cat > "$_d/clean.ts" <<'EOF'
const MUSH = 0.6; // measured floor of the destroyed case; don't lower
EOF

# --- the advisory default must never change ---
python3 "$CHECK" "$_d/bad.ts" >/dev/null 2>&1
check_eq "default exit is 0 even with findings" "0" "$?"

python3 "$CHECK" "$_d/clean.ts" >/dev/null 2>&1
check_eq "default exit is 0 with no findings" "0" "$?"

# --- --porcelain is the gate's signal ---
python3 "$CHECK" --porcelain "$_d/bad.ts" >/dev/null 2>&1
check_eq "porcelain exits 1 on findings" "1" "$?"

python3 "$CHECK" --porcelain "$_d/clean.ts" >/dev/null 2>&1
check_eq "porcelain exits 0 with no findings" "0" "$?"

_out="$(python3 "$CHECK" --porcelain "$_d/bad.ts" 2>/dev/null)"
check "porcelain emits file:line:kind" \
  "printf '%s' \"\$_out\" | grep -qE '^.*bad\.ts:[0-9]+:(banner|commented-out)$'"
# Match the porcelain shape, not merely a colon — on the human read-out the
# summary line also contains one, so a loose count passes before the flag exists.
check_eq "porcelain emits one line per finding" "2" \
  "$(printf '%s\n' "$_out" | grep -cE '^.+:[0-9]+:[a-z-]+$')"

# The keeper must stay silent in BOTH read-outs. A detector that only proves it
# fires can ship green while shredding load-bearing comments.
check_eq "porcelain is silent on a keeper" "" "$(python3 "$CHECK" --porcelain "$_d/clean.ts" 2>/dev/null)"

# --- the built-in both-directions suite ---
python3 "$CHECK" --self-test >/dev/null 2>&1
check_eq "self-test exits 0" "0" "$?"

_st="$(python3 "$CHECK" --self-test 2>/dev/null)"
check "self-test proves detection fires" "printf '%s' \"\$_st\" | grep -q 'detect'"
check "self-test proves keepers stay silent" "printf '%s' \"\$_st\" | grep -q 'keep'"
check "self-test reports no FAIL rows" "! printf '%s' \"\$_st\" | grep -q 'FAIL'"
