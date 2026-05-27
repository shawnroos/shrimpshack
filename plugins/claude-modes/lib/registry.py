"""Canonical reader for ~/.claude/plugins/installed_plugins.json.

THE single source of truth for the installed-plugins registry shape. Before
this module existed, the `{"plugins": dict} -> items` normalization + the
`records = val if list else [val]; any(isinstance(r, dict))` validity filter
were hand-copied into 5 inline Bash heredocs (resolve-catalog-candidate.sh x3,
mode-add.sh, cascade-engine.sh), kept in sync by a "REGISTRY-READER SYNC"
comment convention — a written confession that this abstraction was missing
(and the comment already undercounted the copies). Centralizing here makes the
shape rule physically un-driftable.

Import seam (mirrors lib/sanitize.py's usage in cascade-engine.py /
symlink-validate.py): a Bash heredoc runs as `python3 - <<EOF`, where
`__file__` is "<stdin>", so it cannot self-locate. The caller passes the lib
dir as an argv element and does:

    sys.path.insert(0, <lib_dir_argv>)
    from registry import iter_plugin_entries

The marketplace-membership reader (a `{"plugins": [list]}` shape) and
cascade-engine.py's _extract_enabled_plugins (already a named function) are
DIFFERENT readers doing different work — deliberately NOT collapsed into this.
"""

import json
from typing import Iterator, List, Tuple


def iter_plugin_entries(data: object) -> Iterator[Tuple[str, List[dict]]]:
    """Yield (plugin_key, valid_records) for each entry in the registry.

    Handles both shapes the registry has worn:
      - {"plugins": {"<name>@<market>": <record-or-list>}}  (current)
      - {"<name>@<market>": <record-or-list>}               (legacy top-level)

    `plugin_key` is always a str. `valid_records` is the record coerced to a
    list, guaranteed to contain at least one dict (entries with no dict record
    are skipped — they can't carry the version/marketplace fields callers need).
    """
    plugins = data.get("plugins") if isinstance(data, dict) else None
    if isinstance(plugins, dict):
        items = plugins.items()
    elif isinstance(data, dict):
        items = data.items()
    else:
        items = []
    for key, val in items:
        if not isinstance(key, str):
            continue
        records = val if isinstance(val, list) else [val]
        if not any(isinstance(r, dict) for r in records):
            continue
        yield key, [r for r in records if isinstance(r, dict)]


def load_registry(path: str) -> object:
    """Load + json-parse the registry file. Returns {} on any error (missing
    file, parse failure) so callers can iterate an empty registry safely."""
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}
