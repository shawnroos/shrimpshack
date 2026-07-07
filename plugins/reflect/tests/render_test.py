#!/usr/bin/env python3
"""render_test.py — tests for memory-index-render.py (U5).

Verifies the projection model: hot/cold split under budget, no body ever deleted,
idempotency, pinned-always-hot (AE6), and re-access re-promotion (AE2). Builds an
isolated fixture; never touches live memory. Run: `python3 tests/render_test.py`.
"""
import os
import subprocess
import sys
import tempfile

REPO = os.path.join(os.path.dirname(__file__), "..")
RENDER = os.path.join(REPO, "scripts", "memory-index-render.py")
PASS = 0
FAIL = 0


def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   - {name}")
    else:
        FAIL += 1
        print(f"  FAIL - {name}", file=sys.stderr)


def render(d, **env):
    e = dict(os.environ, MEMORY_DIR=d, **{k: str(v) for k, v in env.items()})
    subprocess.run([sys.executable, RENDER, os.path.join(d, "MEMORY.md")],
                   env=e, capture_output=True, text=True)


def index_targets(d):
    out = set()
    for ln in open(os.path.join(d, "MEMORY.md")):
        if ln.startswith("- ["):
            a, b = ln.find("("), ln.find(")")
            if a > 0 and b > a:
                out.add(ln[a + 1:b])
    return out


with tempfile.TemporaryDirectory() as d:
    # 30 memories with descending recency; a tight budget forces a hot/cold split.
    for i in range(30):
        day = 28 - (i % 28)
        open(os.path.join(d, f"feedback_m{i:02d}.md"), "w").write(
            f"---\nlast_used: 2026-06-{day:02d}\n---\nbody {i} with enough words to make a real hook line here\n")
    open(os.path.join(d, "project_pinned.md"), "w").write(
        "---\npin: true\nlast_used: 2020-01-01\n---\nold but pinned forever\n")
    open(os.path.join(d, "MEMORY.md"), "w").write("# Memory Index\n")

    n_bodies = len([f for f in os.listdir(d) if f.endswith(".md") and f != "MEMORY.md"])
    render(d, MAX_BYTES=1200, MAX_LINES=200)

    hot = index_targets(d)
    bodies_after = len([f for f in os.listdir(d) if f.endswith(".md") and f != "MEMORY.md"])
    nbytes = len(open(os.path.join(d, "MEMORY.md"), "rb").read())

    check("hot tier is a strict subset (some memories went cold)", 0 < len(hot) < n_bodies)
    check("no body file deleted by the render", bodies_after == n_bodies)
    check("rendered index respects the byte budget", nbytes < 1200)
    check("pinned memory is always hot despite old last_used (AE6)", "project_pinned.md" in hot)

    # idempotency
    m1 = open(os.path.join(d, "MEMORY.md"), "rb").read()
    render(d, MAX_BYTES=1200, MAX_LINES=200)
    m2 = open(os.path.join(d, "MEMORY.md"), "rb").read()
    check("render is idempotent (byte-stable on re-run)", m1 == m2)

    # AE2: a cold memory bumped to today re-enters the hot tier
    cold = sorted(set(f for f in os.listdir(d)
                      if f.endswith(".md") and f != "MEMORY.md") - hot)
    target = cold[0]
    check("AE2 precondition: picked a memory that was cold", target not in hot)
    p = os.path.join(d, target)
    import re
    t = re.sub(r"last_used:.*", "last_used: 2026-06-28", open(p).read())
    open(p, "w").write(t)
    render(d, MAX_BYTES=1200, MAX_LINES=200)
    check("AE2: re-accessed (bumped) cold memory re-enters hot tier", target in index_targets(d))

    # empty-dir guard
    with tempfile.TemporaryDirectory() as empty:
        open(os.path.join(empty, "MEMORY.md"), "w").write("# Memory Index\n- [a](a.md) — h\n")
        r = subprocess.run([sys.executable, RENDER, os.path.join(empty, "MEMORY.md")],
                           env=dict(os.environ, MEMORY_DIR=empty),
                           capture_output=True, text=True)
        check("render aborts on empty memory dir (no gutting)", r.returncode != 0)

print()
print(f"render_test: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
