#!/usr/bin/env python3
"""retrieval_test.py — the extracted retrieval engine (U9).

Covers the properties that make the extraction real rather than cosmetic: the
engine is callable WITHOUT a hook and returns structured results carrying source
and gate verdict; a wedged qmd fails within budget and leaves no orphaned
processes; the cooldown stamp path is byte-identical between the hook path and
the CLI path under a cleared environment with DIFFERENT `TMPDIR`s (the parity
assertion that replaces a grep-level guard) and lives under neither; a stamp
armed by one path suppresses the other's qmd probe; and the budget-asymmetry
rule holds — a path that gave qmd less time than session-start recall would have
does not get to arm the shared cooldown.

Everything runs against STUB qmd binaries (healthy and wedged) — no live qmd, no
network, and no `timeout` binary (there is none on this machine; the bound is a
background-and-kill watchdog). The user's live memory store is never touched.

Run: `python3 tests/retrieval_test.py`
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE_DIR = os.path.join(HERE, "..", "scripts", "scoped-memory")
HOOK = os.path.join(HERE, "..", "hooks", "seeded-recall.sh")
sys.path.insert(0, ENGINE_DIR)
import retrieval  # noqa: E402

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


def write_exec(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, 0o755)


HEALTHY_STUB = """#!/usr/bin/env bash
echo "$1" >> "$QMD_CALLS"
case "$1" in
  vsearch) printf '[{"file":"retrieval_stub_body.md","title":"Retrieval Stub","score":0.9}]' ;;
  get)     printf 'HEALTHYSTUBTOKEN body content\\n' ;;
  status)  printf 'QMD Status\\nPending: 0 need embedding\\n' ;;
  *)       exit 0 ;;
esac
"""

# Hangs forever and spawns two long-lived grandchildren, recording their PIDs so
# the orphan check can probe survival by PID (macOS pgrep can't match the argv —
# /bin/sh exec-rewrites it — and `ps -f`/`pgrep -fl` would dump env into the
# transcript). The stub then waits, so the engine's wall budget must expire here.
WEDGED_STUB = """#!/usr/bin/env bash
echo "$1" >> "$QMD_CALLS"
sleep 300 & echo $! >> "$QMD_PIDS"
sleep 300 & echo $! >> "$QMD_PIDS"
wait
"""


def bounded(cmd, env, limit, cwd=None):
    """Run a command under a background-and-kill watchdog (no `timeout` binary
    exists here). Returns (stdout, elapsed, timed_out)."""
    t0 = time.time()
    p = subprocess.Popen(cmd, env=env, cwd=cwd, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=limit)
        return out, time.time() - t0, False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=2)
        except Exception:
            pass
        return None, time.time() - t0, True


def alive(pidfile):
    n = 0
    try:
        with open(pidfile) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    os.kill(int(line), 0)
                    n += 1
                except (OSError, ValueError):
                    pass
    except OSError:
        pass
    return n


def reap(pidfile):
    try:
        with open(pidfile) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        os.kill(int(line), signal.SIGTERM)
                    except (OSError, ValueError):
                        pass
    except OSError:
        pass


CALL = ("import json,retrieval;"
        "r=retrieval.recall(%(q)r, budget=%(b)r, cwd=%(cwd)r%(extra)s);"
        "print(json.dumps(dict(r.as_dict(), _budget=r.budget, _stamped=r.stamped)))")


def engine_call(env, query="anything", budget=6.0, cwd=None, extra="", limit=30):
    """Call the engine in a clean subprocess (the CLI role) and parse its result."""
    code = CALL % {"q": query, "b": budget, "cwd": cwd, "extra": extra}
    out, elapsed, timed_out = bounded([sys.executable, "-c", code], env, limit, cwd=cwd)
    if timed_out or not out:
        return None, elapsed, timed_out
    try:
        return json.loads(out.strip().splitlines()[-1]), elapsed, False
    except Exception:
        return None, elapsed, False


with tempfile.TemporaryDirectory() as root:
    home = os.path.join(root, "home")
    binh = os.path.join(root, "bin-healthy")
    binw = os.path.join(root, "bin-wedged")
    memdir = os.path.join(root, "mem")
    tmp_a = os.path.join(root, "tmp-a")
    tmp_b = os.path.join(root, "tmp-b")
    for d in (home, binh, binw, memdir, tmp_a, tmp_b):
        os.makedirs(d, exist_ok=True)
    calls = os.path.join(root, "qmd-calls")
    pids = os.path.join(root, "qmd-pids")
    write_exec(os.path.join(binh, "qmd"), HEALTHY_STUB)
    write_exec(os.path.join(binw, "qmd"), WEDGED_STUB)

    def env_for(binpath, tmpdir, flag_dir=None, **extra):
        e = {"PATH": binpath + ":/usr/bin:/bin", "HOME": home, "TMPDIR": tmpdir,
             "PYTHONPATH": os.path.abspath(ENGINE_DIR),
             "QMD_CALLS": calls, "QMD_PIDS": pids,
             "SEEDED_RECALL_MEMORY_DIR": memdir}
        if flag_dir:
            e["SEEDED_RECALL_FLAG_DIR"] = flag_dir
        e.update(extra)
        return e

    # ------------------------------------------- 1. engine callable without a hook
    open(calls, "w").close()
    fd1 = os.path.join(root, "flags-healthy")
    res, elapsed, _ = engine_call(env_for(binh, tmp_a, fd1), query="widget pipeline")
    check("healthy stub: engine returns ok status with items (no hook involved)",
          res is not None and res["status"] == "ok" and len(res["items"]) == 1)
    check("healthy stub: item carries the fetched body",
          res is not None and "HEALTHYSTUBTOKEN" in res["items"][0]["body"])
    check("healthy stub: item carries its source layer",
          res is not None and res["items"][0]["source"] == "qmd")
    check("healthy stub: item carries a gate verdict",
          res is not None and res["items"][0]["gate"] in ("pass", "repo"))
    check("healthy stub: success writes no failure stamp",
          not os.path.exists(retrieval.cooldown_stamp_path(fd1)))

    # ------------------------------------ 2. wedged stub: fails within its budget
    open(calls, "w").close()
    open(pids, "w").close()
    fd2 = os.path.join(root, "flags-wedged")
    res, elapsed, timed_out = engine_call(env_for(binw, tmp_a, fd2), budget=6.0,
                                          limit=30)
    check("wedged stub: engine returns rather than hanging (6s budget)",
          not timed_out)
    check("wedged stub: status is `unavailable`",
          res is not None and res["status"] == "unavailable")
    check("wedged stub: returns inside the wall budget (+ kill escalation)",
          elapsed < 8.0)
    time.sleep(0.5)   # give any orphan a moment — if not group-killed it survives
    recorded = sum(1 for line in open(pids) if line.strip())
    check("wedged stub: the stub actually spawned children (the test is live)",
          recorded >= 1)
    check("wedged stub: no orphaned qmd descendants survive", alive(pids) == 0)
    reap(pids)
    check("wedged stub: the failure armed a stamp",
          os.path.exists(retrieval.cooldown_stamp_path(fd2)))

    # ---------------------------- 3. hook and CLI derive the SAME stamp path (KTD8)
    # Cleared environment, different TMPDIRs, two different entry shapes: the hook
    # (bash wrapper -> python importing the engine the way seeded-recall.sh does)
    # and the CLI (`retrieval.py --stamp-path`).
    hook_cmd = ["bash", "-c",
                'SCOPED_MEMORY_DIR="$1" python3 -c '
                '"import os,sys;sys.path.insert(0,os.environ[\'SCOPED_MEMORY_DIR\']);'
                'import retrieval;print(retrieval.cooldown_stamp_path())"',
                "_", os.path.abspath(ENGINE_DIR)]
    hook_path, _, _ = bounded(hook_cmd, env_for(binh, tmp_a), 20)
    cli_path, _, _ = bounded(
        [sys.executable, os.path.join(os.path.abspath(ENGINE_DIR), "retrieval.py"),
         "--stamp-path"], env_for(binh, tmp_b), 20)
    hook_path = (hook_path or "").strip()
    cli_path = (cli_path or "").strip()
    check("stamp path: hook and CLI derive it byte-identically under different TMPDIRs",
          hook_path != "" and hook_path == cli_path)
    check("stamp path: it lives under neither TMPDIR (the whole point of the move)",
          hook_path != "" and not hook_path.startswith(tmp_a)
          and not hook_path.startswith(tmp_b))
    check("stamp path: it is store-adjacent under HOME",
          hook_path.startswith(os.path.join(home, ".claude", "projects")))

    # ------------------- 4. a stamp armed by the hook suppresses the CLI's probe
    # The real hook arms it (wedged stub, threshold 1, TMPDIR=A, no FLAG_DIR — so the
    # derived store-adjacent path is what is exercised). The engine then runs as the
    # CLI would, under TMPDIR=B, and must skip the qmd call entirely.
    open(calls, "w").close()
    open(pids, "w").close()
    hook_env = env_for(binw, tmp_a, SEEDED_RECALL_TIMEOUT="1",
                       SEEDED_RECALL_FAIL_THRESHOLD="1")
    p = subprocess.Popen(["bash", os.path.abspath(HOOK)], env=hook_env,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        p.communicate('{"prompt":"anything","session_id":"P1"}', timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    armed_stamp = os.path.join(home, ".claude", "projects",
                               "-" + home.lstrip("/").replace("/", "-"),
                               "recall-state", retrieval.STAMP_NAME)
    check("cross-path stamp: the hook armed the derived store-adjacent stamp",
          os.path.exists(armed_stamp))
    calls_before = sum(1 for line in open(calls) if line.strip())
    cli_env = env_for(binw, tmp_b, SEEDED_RECALL_FAIL_THRESHOLD="1")
    res, elapsed, timed_out = engine_call(cli_env, budget=6.0, limit=30)
    calls_after = sum(1 for line in open(calls) if line.strip())
    check("cross-path stamp: the CLI observes the armed state (status `cooldown`)",
          res is not None and res["status"] == "cooldown")
    check("cross-path stamp: the CLI makes no qmd call at all",
          calls_after == calls_before)
    check("cross-path stamp: the CLI returns immediately, not after its budget",
          elapsed < 3.0)
    reap(pids)

    # ------------------------------ 5. budget asymmetry: who may arm the cooldown
    # A failure under a budget SHORTER than session-start recall's must not black
    # out every session; one at or above it may.
    open(pids, "w").close()
    fd5 = os.path.join(root, "flags-asym")
    res, _, _ = engine_call(env_for(binw, tmp_a, fd5), budget=1.0,
                            extra=", stamp_min_budget=6.0", limit=30)
    check("budget asymmetry: a below-floor failure does not arm the shared cooldown",
          res is not None and res["status"] == "unavailable"
          and res["_stamped"] is False
          and not os.path.exists(retrieval.cooldown_stamp_path(fd5)))
    res, _, _ = engine_call(env_for(binw, tmp_a, fd5), budget=6.0,
                            extra=", stamp_min_budget=6.0", limit=30)
    check("budget asymmetry: a failure at/above the floor does arm it",
          res is not None and res["_stamped"] is True
          and os.path.exists(retrieval.cooldown_stamp_path(fd5)))
    stamp = json.load(open(retrieval.cooldown_stamp_path(fd5)))
    check("budget asymmetry: the stamp records the budget that produced it",
          stamp.get("budget") == 6.0 and stamp.get("source") == "seeded")
    reap(pids)

    # A pre-U9 stamp (no budget field) still suppresses — today's hook contract.
    fd6 = os.path.join(root, "flags-legacy")
    os.makedirs(fd6, exist_ok=True)
    with open(retrieval.cooldown_stamp_path(fd6), "w") as fh:
        json.dump({"count": 2, "ts": time.time()}, fh)
    open(calls, "w").close()
    res, _, _ = engine_call(env_for(binw, tmp_a, fd6), budget=6.0, limit=30)
    check("legacy stamp without a budget field still suppresses (honoring is unconditional)",
          res is not None and res["status"] == "cooldown"
          and sum(1 for line in open(calls) if line.strip()) == 0)
    reap(pids)

print(f"retrieval: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
