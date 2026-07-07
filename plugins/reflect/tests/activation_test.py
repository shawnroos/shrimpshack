#!/usr/bin/env python3
"""activation_test.py — unit tests for memory_activation (U2).

The activation arithmetic is load-bearing: the index render and the recall floor
both ride on it. Covers AE3 (absent last_used -> neutral, not bottom), AE6 (pin
-> always hot), recency ordering, frequency tie-break, decay math, and
determinism. Run directly: `python3 tests/activation_test.py`.
"""
import os
import sys
from datetime import date, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import memory_activation as ma  # noqa: E402

PASS = 0
FAIL = 0
TODAY = date(2026, 6, 28)


def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   - {name}")
    else:
        FAIL += 1
        print(f"  FAIL - {name}", file=sys.stderr)


def act(last_used=None, mtime_age=0, uses=0, pinned=False):
    mtime = TODAY - timedelta(days=mtime_age)
    return ma.activation(TODAY, last_used, mtime, uses, pinned)


# --- decay math ---
check("decay is 1.0 at age 0", abs(ma.decay(0, 45) - 1.0) < 1e-9)
check("decay is 0.5 at one half-life", abs(ma.decay(45, 45) - 0.5) < 1e-9)
check("decay is 0.25 at two half-lives", abs(ma.decay(90, 45) - 0.25) < 1e-9)
check("decay clamps future timestamps to 1.0", abs(ma.decay(-10, 45) - 1.0) < 1e-9)
check("decay handles zero half-life without dividing by zero", ma.decay(10, 0) == 1.0)

# --- frequency ---
check("freq 0 uses -> 0", ma.freq_score(0, 10) == 0.0)
check("freq grows with uses", ma.freq_score(5, 10) > ma.freq_score(1, 10))
check("freq saturates at cap (<=1)", ma.freq_score(1000, 10) <= 1.0)
check("freq first use beats nothing", ma.freq_score(1, 10) > 0.0)

# --- pin: always hot (AE6) ---
check("pinned -> +inf regardless of age", act(last_used=TODAY - timedelta(days=400), pinned=True) == float("inf"))
check("pinned beats any unpinned", act(pinned=True) > act(last_used=TODAY, uses=100))

# --- recency ordering ---
fresh = act(last_used=TODAY)
stale = act(last_used=TODAY - timedelta(days=200))
check("used today ranks strictly higher than used 200d ago", fresh > stale)

# --- absent last_used is a neutral seed, NOT maximal decay (AE3 / R7) ---
absent = act(last_used=None, mtime_age=0)
very_stale = act(last_used=TODAY - timedelta(days=365), mtime_age=0)
check("absent last_used outranks a 365-day-stale last_used (neutral seed)", absent > very_stale)
absent_recent_mtime = act(last_used=None, mtime_age=0)
absent_old_mtime = act(last_used=None, mtime_age=365)
check("absent last_used + recent mtime beats absent + old mtime", absent_recent_mtime > absent_old_mtime)
# neutral seed sits mid-pack: below a fresh memory, above a long-stale one
check("neutral seed is below fresh", absent < fresh)

# --- frequency tie-break: same recency, more uses ranks higher ---
lo = act(last_used=TODAY - timedelta(days=30), uses=1)
hi = act(last_used=TODAY - timedelta(days=30), uses=8)
check("more uses ranks higher at equal recency", hi > lo)

# --- recall_floor (U6): faded memories need a stronger cue ---
fresh_floor = ma.recall_floor(1.3, base=0.45, span=0.15, ref=1.3)
faded_floor = ma.recall_floor(0.6, base=0.45, span=0.15, ref=1.3)
check("recall_floor: fresh memory clears the base floor", abs(fresh_floor - 0.45) < 1e-9)
check("recall_floor: faded memory needs a higher floor than fresh", faded_floor > fresh_floor)
check("recall_floor: pinned (inf activation) clears the base floor", abs(ma.recall_floor(float("inf"), 0.45, 0.15, 1.3) - 0.45) < 1e-9)
check("recall_floor: monotonic — more activation never raises the floor",
      all(ma.recall_floor(a, 0.45, 0.15, 1.3) >= ma.recall_floor(a + 0.1, 0.45, 0.15, 1.3)
          for a in (0.2, 0.5, 0.9, 1.2)))
check("recall_floor: capped span — fully faded clears at most base+span",
      ma.recall_floor(0.0, 0.45, 0.15, 1.3) <= 0.45 + 0.15 + 1e-9)

# --- determinism ---
check("activation is deterministic", act(last_used=TODAY - timedelta(days=10), uses=3) ==
      act(last_used=TODAY - timedelta(days=10), uses=3))

# --- score_dir end to end on a tiny fixture ---
import tempfile  # noqa: E402

with tempfile.TemporaryDirectory() as d:
    def w(name, body):
        open(os.path.join(d, name), "w").write(body)
    w("MEMORY.md", "# Memory Index\n")
    w("a_pinned.md", "---\npin: true\nlast_used: 2020-01-01\n---\nold but pinned\n")
    w("b_fresh.md", "---\nlast_used: 2026-06-28\n---\nfresh\n")
    w("c_absent.md", "no frontmatter at all\n")
    w("d_stale.md", "---\nlast_used: 2024-01-01\n---\nstale\n")
    open(os.path.join(d, "MEMORY_USE.log"), "w").write("2026-06-20 b_fresh [x]\n")
    ranked = ma.score_dir(d, today=TODAY)
    names = [fn for fn, _ in ranked]
    check("score_dir excludes MEMORY.md", "MEMORY.md" not in names)
    check("score_dir ranks pinned first", names[0] == "a_pinned.md")
    check("score_dir ranks stale last", names[-1] == "d_stale.md")
    check("score_dir keeps absent-last_used above stale", names.index("c_absent.md") < names.index("d_stale.md"))

print()
print(f"activation_test: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
