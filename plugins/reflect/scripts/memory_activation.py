#!/usr/bin/env python3
"""memory_activation.py — deterministic accessibility scoring for memories.

The auto-loaded index (MEMORY.md) is a *projection*: the highest-activation
memories that fit the load budget. Activation models reachability the way human
memory does — it decays with disuse and is restored by use — but as plain,
inspectable arithmetic, never an ML score. This module is the single source of
that arithmetic; the index renderer and the recall floor both consume it.

Activation inputs (per memory):
  - last_used:  ISO date in frontmatter (`last_used: YYYY-MM-DD`); ABSENT means
                "unknown", seeded at a neutral age — never treated as maximally
                stale. A never-cited-but-valuable memory must not sink purely
                from missing telemetry.
  - mtime:      file modification time (last reinforcement).
  - use_count:  how many times the memory appears in MEMORY_USE.log.
  - pin:        `pin: true` in frontmatter -> always-hot (infinite activation).

Score = w_recency * decay(age_of_last_used_or_neutral)
      + w_mtime   * decay(age_of_mtime)
      + w_freq    * freq(use_count)
A pinned memory short-circuits to +inf.

decay() is a half-life curve in [0,1]: 1.0 at age 0, 0.5 at one half-life. The
half-life and weights are tunable (the Phase B spike sweeps them); the defaults
below are the starting point, overridable via env or the params dict so the
spike harness can sweep without editing code.

Pure functions only — no I/O except the small frontmatter/log readers, which are
fail-open (a missing or malformed file yields the neutral/zero contribution, not
an exception).
"""
import math
import os
import re
from datetime import date, datetime

# --- Tunable parameters (Phase B spike sweeps these; defaults are the start) ---
DEFAULT_PARAMS = {
    "recency_half_life_days": 45.0,   # last_used decay half-life
    "mtime_half_life_days": 60.0,     # reinforcement (mtime) decay half-life
    "w_recency": 1.0,
    "w_mtime": 0.3,
    "w_freq": 0.4,
    "neutral_age_days": 45.0,         # age assigned to an ABSENT last_used (one
                                      # recency half-life -> a mid-pack seed, not
                                      # the bottom; this is the R7 guarantee)
    "freq_cap": 10,                   # diminishing returns past this many uses
}

_DATE_RE = re.compile(r"^\s*last_used\s*:\s*(\d{4}-\d{2}-\d{2})", re.M)
_PIN_RE = re.compile(r"^\s*pin\s*:\s*true\s*$", re.M | re.I)


def _params(overrides=None):
    p = dict(DEFAULT_PARAMS)
    # env overrides (MEMORY_ACT_<KEY uppercased>), then explicit dict overrides
    for k in p:
        env = os.environ.get("MEMORY_ACT_" + k.upper())
        if env not in (None, ""):
            try:
                p[k] = type(p[k])(env)
            except (TypeError, ValueError):
                pass
    if overrides:
        p.update(overrides)
    return p


def decay(age_days, half_life_days):
    """Half-life decay in [0,1]: 1.0 at age 0, 0.5 at one half-life. Negative age
    (a future timestamp from clock skew) is clamped to 0 -> 1.0."""
    if half_life_days <= 0:
        return 1.0
    a = max(0.0, float(age_days))
    return 0.5 ** (a / half_life_days)


def recall_floor(activation, base=0.45, span=0.15, ref=1.3):
    """The minimum vector-search score a memory must clear to surface in recall,
    as a function of its activation (U6 — the "more intention to reach" proxy).

    A fresh / high-activation memory clears a LOW floor (`base`); a faded one must
    clear up to `base + span`. Pinned (activation == inf) clears `base`. `ref` is
    the activation treated as fully fresh. Higher activation -> lower floor."""
    norm = min(1.0, activation / ref) if ref > 0 else 1.0
    return base + span * (1.0 - norm)


def freq_score(use_count, cap):
    """Diminishing-returns frequency contribution in [0,1]. 0 uses -> 0;
    saturates at `cap` uses. log so the 1st use matters most."""
    n = max(0, int(use_count))
    if n <= 0:
        return 0.0
    c = max(1, int(cap))
    return min(1.0, math.log1p(n) / math.log1p(c))


def activation(today, last_used, mtime_date, use_count, pinned, params=None):
    """Compute a memory's activation score.

    today / last_used / mtime_date are `datetime.date`. last_used may be None
    (absent) -> seeded at neutral_age. pinned True -> +inf. Higher is hotter.
    """
    if pinned:
        return float("inf")
    p = _params(params)

    if last_used is None:
        recency_age = p["neutral_age_days"]
    else:
        recency_age = (today - last_used).days
    mtime_age = (today - mtime_date).days if mtime_date is not None else p["neutral_age_days"]

    return (
        p["w_recency"] * decay(recency_age, p["recency_half_life_days"])
        + p["w_mtime"] * decay(mtime_age, p["mtime_half_life_days"])
        + p["w_freq"] * freq_score(use_count, p["freq_cap"])
    )


# --- Small fail-open readers (I/O lives here, not in the pure scorers) ---

def parse_last_used(path):
    """Return the `last_used` date from a body file's frontmatter, or None."""
    try:
        text = open(path, encoding="utf-8").read(4096)
    except Exception:
        return None
    m = _DATE_RE.search(text)
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1), "%Y-%m-%d").date()
    except ValueError:
        return None


def parse_pinned(path):
    """True if the body file's frontmatter has `pin: true`."""
    try:
        text = open(path, encoding="utf-8").read(4096)
    except Exception:
        return False
    return bool(_PIN_RE.search(text))


def use_counts(use_log_path):
    """Map of memory-name -> count from MEMORY_USE.log. Log lines look like
    `<date> <memory-name> [trigger]`; the 2nd whitespace field is the name.
    Missing/unreadable log -> empty map (every memory gets 0 uses)."""
    counts = {}
    try:
        lines = open(use_log_path, encoding="utf-8").read().splitlines()
    except Exception:
        return counts
    for ln in lines:
        parts = ln.split()
        if len(parts) >= 2:
            name = parts[1]
            counts[name] = counts.get(name, 0) + 1
    return counts


def score_dir(memory_dir, today=None, params=None):
    """Score every body .md in memory_dir. Returns a list of
    (filename, score) sorted by score descending then filename, ready for the
    renderer to truncate at the budget. MEMORY.md and dotfiles are excluded;
    name matching for use_counts strips the .md so a frontmatter `name:` slug or
    the filename stem both line up with the log's 2nd field."""
    today = today or date.today()
    p = _params(params)
    counts = use_counts(os.path.join(memory_dir, "MEMORY_USE.log"))
    scored = []
    for fn in os.listdir(memory_dir):
        if not fn.endswith(".md") or fn == "MEMORY.md" or fn.startswith("."):
            continue
        path = os.path.join(memory_dir, fn)
        try:
            mtime_date = datetime.fromtimestamp(os.path.getmtime(path)).date()
        except Exception:
            mtime_date = None
        stem = fn[:-3]
        # log may record either the frontmatter name slug or the filename stem;
        # count both spellings (underscore filename vs kebab slug) when present.
        uc = counts.get(stem, 0) or counts.get(stem.replace("_", "-"), 0)
        s = activation(
            today,
            parse_last_used(path),
            mtime_date,
            uc,
            parse_pinned(path),
            p,
        )
        scored.append((fn, s))
    scored.sort(key=lambda t: (-t[1] if t[1] != float("inf") else float("-inf"), t[0]))
    return scored


if __name__ == "__main__":
    import sys
    d = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(
        os.path.abspath(__file__))
    for fn, s in score_dir(d):
        print(f"{s:>8.4f}  {fn}" if s != float("inf") else f"{'  PINNED':>8}  {fn}")
