#!/usr/bin/env python3
"""corpus_test.py — tests for the shared recursive store enumeration (U10/KTD16).

The unit's two claims, and what proves each:

  1. The `_scope/<slug>/` subtree is part of the corpus — for enumeration AND for
     activation scoring. Proved by asserting scoped bodies come back from
     `iter_bodies` AND come back with a score from `score_dir`. Mutating
     `score_dir` back to a flat `os.listdir` must turn these red.
  2. A scope slug is one whole path segment, never a parse. Proved with slugs
     carrying `-`, `.`, spaces and regex metacharacters. Mutating the parse to
     split on `-`/`.` must turn these red.

Everything runs against fixtures in a temp dir; the live store is never touched.
Run: `python3 tests/corpus_test.py`.
"""
import os
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(REPO, "scripts")
RENDER = os.path.join(SCRIPTS, "memory-index-render.py")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "scoped-memory"))
import corpus                      # noqa: E402
import memory_activation as ma     # noqa: E402

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


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def body(name, last_used="2026-06-20"):
    return (f"---\nname: {name}\nlast_used: {last_used}\n---\n"
            f"description: hook for {name}\n\nbody text for {name}\n")


# ----------------------------------------------------------- 1. mixed corpus
print("== enumeration: flat + scoped ==")
with tempfile.TemporaryDirectory() as d:
    write(os.path.join(d, "feedback_flat_one.md"), body("feedback_flat_one"))
    write(os.path.join(d, "reference_flat_two.md"), body("reference_flat_two"))
    write(os.path.join(d, "_scope", "-Users-x-projects-alpha", "project_a.md"),
          body("project_a"))
    write(os.path.join(d, "_scope", "-Users-x-projects-alpha", "project_b.md"),
          body("project_b"))
    write(os.path.join(d, "_scope", "-Users-x-projects-beta", "feedback_c.md"),
          body("feedback_c"))
    # A body sitting directly in _scope with NO slug directory. This shape exists
    # in the live store; leaving it untested would leave live behavior untested.
    write(os.path.join(d, "_scope", "reference_no_slug.md"), body("reference_no_slug"))

    got = dict(corpus.iter_bodies(d))
    rels = list(corpus.iter_bodies(d))

    check("every flat body is yielded",
          {"feedback_flat_one.md", "reference_flat_two.md"} <= set(got))
    check("every scoped body is yielded",
          {os.path.join("_scope", "-Users-x-projects-alpha", "project_a.md"),
           os.path.join("_scope", "-Users-x-projects-alpha", "project_b.md"),
           os.path.join("_scope", "-Users-x-projects-beta", "feedback_c.md")} <= set(got))
    check("each body is yielded exactly once", len(rels) == len(got) == 6)
    check("flat bodies carry no scope slug",
          got["feedback_flat_one.md"] is None and got["reference_flat_two.md"] is None)
    check("scoped bodies carry their slug",
          got[os.path.join("_scope", "-Users-x-projects-alpha", "project_a.md")]
          == "-Users-x-projects-alpha"
          and got[os.path.join("_scope", "-Users-x-projects-beta", "feedback_c.md")]
          == "-Users-x-projects-beta")
    check("a body directly under _scope with no slug dir reads as global",
          got[os.path.join("_scope", "reference_no_slug.md")] is None)
    check("enumeration order is deterministic",
          [r for r, _ in corpus.iter_bodies(d)] == [r for r, _ in corpus.iter_bodies(d)])

# ------------------------------------------------------------- 2. exclusions
print()
print("== exclusions ==")
with tempfile.TemporaryDirectory() as d:
    write(os.path.join(d, "feedback_real.md"), body("feedback_real"))
    write(os.path.join(d, "MEMORY.md"), "# Memory Index\n- [x](feedback_real.md) — h\n")
    write(os.path.join(d, "MEMORY_USE.log"), "2026-06-01 feedback_real applied\n")
    write(os.path.join(d, "RECALL.log"), "2026-06-01 feedback_real qmd\n")
    write(os.path.join(d, "MEMORY.md.pre-render.bak"), "# old\n")
    write(os.path.join(d, ".DS_Store"), "junk")
    write(os.path.join(d, ".hidden_note.md"), body("hidden"))
    write(os.path.join(d, corpus.TRIGGER_MANIFEST), '{"triggers": []}\n')
    write(os.path.join(d, "notes.txt"), "not a memory\n")
    write(os.path.join(d, ".git", "config"), "[core]\n")
    write(os.path.join(d, ".trash", "feedback_deleted.md"), body("feedback_deleted"))
    write(os.path.join(d, "_scope", "-Users-x-projects-alpha", "project_a.md"),
          body("project_a"))
    write(os.path.join(d, "_scope", "-Users-x-projects-alpha", "project_a.md.bak"),
          body("project_a"))

    got = set(corpus.body_paths(d))
    check("only the two real bodies are yielded",
          got == {"feedback_real.md",
                  os.path.join("_scope", "-Users-x-projects-alpha", "project_a.md")})
    for excluded in ("MEMORY.md", "MEMORY_USE.log", "RECALL.log",
                     "MEMORY.md.pre-render.bak", ".DS_Store", ".hidden_note.md",
                     corpus.TRIGGER_MANIFEST, "notes.txt"):
        check(f"excluded: {excluded}", excluded not in got)
    check("dot-directories are pruned (.trash body not yielded)",
          not any(".trash" in g for g in got))
    check("a .bak beside a scoped body is excluded",
          not any(g.endswith(".bak") for g in got))

# ------------------------------------------------------- 3. awkward slugs
print()
print("== slug parsing ==")
AWKWARD = [
    "-Users-shawnroos-projects-Slate-web-app-worktrees-feature-ai-service-hub",
    "-Users-x-projects-my.repo.name",
    "-Users-x-projects-a+b(c)[d]",
    "-Users-x-projects-name with spaces",
    "-Users-x-projects-under_score",
]
with tempfile.TemporaryDirectory() as d:
    write(os.path.join(d, "feedback_flat.md"), body("feedback_flat"))
    for slug in AWKWARD:
        write(os.path.join(d, "_scope", slug, "project_x.md"), body("project_x"))
    got = dict(corpus.iter_bodies(d))
    for slug in AWKWARD:
        rel = os.path.join("_scope", slug, "project_x.md")
        check(f"slug survives intact: {slug}", got.get(rel) == slug)

check("scope_of_relpath returns None for a flat body",
      corpus.scope_of_relpath("feedback_x.md") is None)
check("scope_of_relpath returns None for a non-_scope subdir",
      corpus.scope_of_relpath(os.path.join("archive", "slug", "x.md")) is None)

# ------------------------------------- 4. score_dir sees the scoped subtree
print()
print("== score_dir over the recursive corpus ==")
with tempfile.TemporaryDirectory() as d:
    write(os.path.join(d, "feedback_flat.md"), body("feedback_flat"))
    write(os.path.join(d, "_scope", "-Users-x-projects-alpha", "project_scoped.md"),
          body("project_scoped"))
    write(os.path.join(d, "_scope", "-Users-x-projects-alpha", "project_used.md"),
          body("project_used"))
    write(os.path.join(d, "_scope", "-Users-x-projects-alpha", "project_unused.md"),
          body("project_unused"))
    # The use log records a BARE NAME, never a path — a scoped body's uses only
    # count if score_dir keys on the basename.
    write(os.path.join(d, "MEMORY_USE.log"),
          "".join("2026-06-%02d project_used applied\n" % i for i in range(1, 10)))

    ranked = dict(ma.score_dir(d))
    scoped_rel = os.path.join("_scope", "-Users-x-projects-alpha", "project_scoped.md")
    used_rel = os.path.join("_scope", "-Users-x-projects-alpha", "project_used.md")
    unused_rel = os.path.join("_scope", "-Users-x-projects-alpha", "project_unused.md")

    check("score_dir keys scoped bodies by store-relative path", scoped_rel in ranked)
    check("scoped bodies receive an activation score",
          isinstance(ranked.get(scoped_rel), float))
    check("flat bodies still scored", "feedback_flat.md" in ranked)
    check("all four bodies scored", len(ranked) == 4)
    check("a scoped body's MEMORY_USE.log entries raise its activation",
          ranked[used_rel] > ranked[unused_rel])

    # A pinned scoped memory must reach infinite activation like any other.
    write(os.path.join(d, "_scope", "-Users-x-projects-alpha", "project_pin.md"),
          "---\npin: true\nlast_used: 2020-01-01\n---\npinned scoped\n")
    ranked = dict(ma.score_dir(d))
    check("a pinned scoped memory scores +inf",
          ranked[os.path.join("_scope", "-Users-x-projects-alpha",
                              "project_pin.md")] == float("inf"))

# ---------------------------------- 5. renderer emits usable scoped targets
print()
print("== renderer over the recursive corpus ==")


def render(d, index=None, **env):
    index = index or os.path.join(d, "MEMORY.md")
    e = dict(os.environ, MEMORY_DIR=d, **{k: str(v) for k, v in env.items()})
    return subprocess.run([sys.executable, RENDER, index], env=e,
                          capture_output=True, text=True)


def index_targets(path):
    out = []
    for ln in open(path, encoding="utf-8"):
        if ln.startswith("- ["):
            a, b = ln.find("("), ln.find(")")
            if a > 0 and b > a:
                out.append(ln[a + 1:b])
    return out


with tempfile.TemporaryDirectory() as d:
    write(os.path.join(d, "feedback_flat.md"), body("feedback_flat"))
    write(os.path.join(d, "_scope", "-Users-x-projects-alpha", "project_scoped.md"),
          body("project_scoped"))
    write(os.path.join(d, "MEMORY.md"), "# Memory Index\n\n")
    render(d, MAX_BYTES=17408, MAX_LINES=200)

    idx = os.path.join(d, "MEMORY.md")
    targets = index_targets(idx)
    scoped_rel = "_scope/-Users-x-projects-alpha/project_scoped.md"
    text = open(idx, encoding="utf-8").read()

    check("a scoped memory reaches the hot index", scoped_rel in targets)
    check("its link target is the store-relative path, resolvable from the index",
          os.path.exists(os.path.join(d, scoped_rel)))
    # `project_scoped.md` -> type prefix stripped -> "scoped". The point of the
    # assertion is that no part of the `_scope/<slug>/` path leaks into the title.
    check("its title comes from the file, not the scope directory",
          f"- [scoped]({scoped_rel})" in text
          and not any("Users-x" in ln.split("](")[0]
                      for ln in text.splitlines() if ln.startswith("- [")))
    check("its hook is read from the scoped body's frontmatter",
          "hook for project_scoped" in text)

    m1 = open(idx, "rb").read()
    render(d, MAX_BYTES=17408, MAX_LINES=200)
    check("render is still idempotent with scoped bodies present",
          open(idx, "rb").read() == m1)

    # A curated hook on a scoped entry survives a re-render (existing_hooks keys
    # on the link target, which is now a path).
    write(idx, m1.decode("utf-8").replace("hook for project_scoped", "CURATED HOOK"))
    render(d, MAX_BYTES=17408, MAX_LINES=200)
    check("a curated hook on a scoped entry survives re-render",
          "CURATED HOOK" in open(idx, encoding="utf-8").read())

# --------------------------------------------- 6. live-shaped render timing
print()
print("== live-shaped fixture (866 bodies, nested scope dirs) ==")
with tempfile.TemporaryDirectory() as d:
    N_FLAT, N_SCOPED = 579, 287
    SLUGS = ["-Users-x-projects-repo%02d" % i for i in range(13)]
    for i in range(N_FLAT):
        write(os.path.join(d, "feedback_flat_%04d.md" % i),
              body("feedback_flat_%04d" % i, "2026-%02d-%02d" % (1 + i % 6, 1 + i % 28)))
    for i in range(N_SCOPED):
        write(os.path.join(d, "_scope", SLUGS[i % len(SLUGS)],
                           "project_scoped_%04d.md" % i),
              body("project_scoped_%04d" % i, "2026-%02d-%02d" % (1 + i % 6, 1 + i % 28)))
    write(os.path.join(d, "MEMORY_USE.log"),
          "".join("2026-06-01 feedback_flat_%04d applied\n" % i for i in range(0, N_FLAT, 3)))
    write(os.path.join(d, "MEMORY.md"), "# Memory Index\n\n")

    check("fixture enumerates all 866 bodies", len(corpus.body_paths(d)) == 866)

    t0 = time.time()
    r = render(d, MAX_BYTES=17408, MAX_LINES=200)
    elapsed = time.time() - t0
    check("live-shaped render succeeds", r.returncode == 0)
    # SessionStart budget. The bound is deliberately loose — this assertion is a
    # regression tripwire against an accidental per-body re-read, not a benchmark.
    check(f"live-shaped render within SessionStart budget ({elapsed * 1000:.0f}ms < 5000ms)",
          elapsed < 5.0)
    print(f"  info - 866-body render wall time: {elapsed * 1000:.0f}ms  ({r.stdout.strip()})")

    targets = index_targets(os.path.join(d, "MEMORY.md"))
    check("scoped bodies are eligible for the hot tier in a live-shaped store",
          any(t.startswith("_scope/") for t in targets))

print()
print(f"corpus_test: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
