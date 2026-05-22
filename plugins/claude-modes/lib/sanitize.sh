#!/usr/bin/env bash
# claude-modes: shared terminal-display sanitizer.
#
# CANONICAL home for claude_modes::sanitize_for_display — the single function
# every command/hook uses to neutralize attacker-controlled strings before
# they reach a human terminal (the trust-gate prompt, /mode:status output,
# /mode:registry output, the PostToolUse adopt prompt, etc.).
#
# Why this exists (terminal-escape class, escalated after the value recurred
# across review rounds 2-4 at new sinks each time): a hostile repo can plant
# attacker-controlled bytes in a committed .mode body, _repo.yaml plugin keys,
# a branch name, a filename, or a clone path. Printed raw to a terminal, ESC /
# OSC / CSI sequences (e.g. OSC-2 title rewrite) and Cf bidi overrides (U+202E)
# can rewrite or reverse what the user sees — spoofing a consent prompt or a
# status line. The defense matrix is documented in
# docs/solutions/terminal-escape-audit.md; the lint guard at
# tests/integration/terminal-sink-lint.test.sh enforces that every new sink
# either validates its input or routes it through this function.
#
# Scope (deliberate): strips Unicode Cc (control, incl. C0 ESC/CR/NL) and Cf
# (format, incl. bidi/zero-width). Does NOT do NFKC / homoglyph / confusable
# defense — that's a separate, deferred concern (V2.0 stops obvious injection
# spoofing, not all visually-confusable Unicode).
#
# Note: prefer VALIDATION over sanitization where the value is charset-
# constrainable (mode names, slugs) — a validated value can't carry escapes by
# construction. Use this sanitizer only for free-form values (filenames,
# paths, branch names, plugin keys) that legitimately contain arbitrary chars.

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# claude_modes::sanitize_for_display <string>
# Prints the string with Cc + Cf characters removed. Best-effort: on any
# python3 failure prints nothing (fail-safe — an empty display is never a
# spoof). Uses the safe sys.argv pattern (no shell interpolation into source).
claude_modes::sanitize_for_display() {
  "$CLAUDE_MODES_PYTHON3" - "$1" <<'PYEOF' 2>/dev/null
import sys, unicodedata
s = sys.argv[1]
sys.stdout.write("".join(c for c in s if unicodedata.category(c) not in ("Cc", "Cf")))
PYEOF
}
