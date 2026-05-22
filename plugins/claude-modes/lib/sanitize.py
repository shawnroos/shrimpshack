"""Python-side display sanitizer — the language-boundary twin of lib/sanitize.sh.

The terminal-escape class (a hostile cloned repo plants attacker-controlled
bytes in a committed _repo.yaml / branch / filename that reach a human terminal
raw → ESC/OSC/CSI injection or Unicode Cf bidi spoofing) has a bash defense in
lib/sanitize.sh (claude_modes::sanitize_for_display) and a CI lint that scans
*.sh. The lint is structurally bash-only, so Python sinks (cascade-engine.py,
symlink-validate.py) need their own copy of the same defense AND their own lint
(tests/integration/terminal-sink-lint-py.test.sh). This module is the single
source of truth for the Python side — import it, don't re-implement the strip.

Strips Unicode categories Cc (control) and Cf (format, incl. U+202E bidi
override). Does NOT do NFKC / homoglyph defense — V2.0 stops obvious injection,
not all visually-confusable Unicode (same scope boundary as the bash twin).
"""

import unicodedata


def sanitize_for_display(s: str) -> str:
    """Strip Unicode Cc + Cf chars so attacker bytes can't reach a terminal raw.

    Public API (no leading underscore): callers route any externally-controlled
    value through this before interpolating it into a human-facing stderr/stdout
    message. Mirrors claude_modes::sanitize_for_display in lib/sanitize.sh.
    """
    return "".join(c for c in s if unicodedata.category(c) not in ("Cc", "Cf"))
