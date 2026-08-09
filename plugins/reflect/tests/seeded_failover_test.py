#!/usr/bin/env python3
"""seeded_failover_test.py — session-start recall fails OVER, not to silence (U4).

The behavior under test: once qmd is CONFIRMED wedged, `hooks/seeded-recall.sh`
states the degradation in one line and falls over to the local BM25 index, instead
of exiting 0 with no output — which is indistinguishable from "nothing relevant was
found" and is how a 4,796-line session ended up with zero recall and no explanation.

Everything runs against STUB qmd binaries and FIXTURE stores. Nothing here needs a
live qmd (it is wedged on this machine), nothing reads or writes the operator's live
memory store, and nothing uses a `timeout` binary (there is none — the bound is
subprocess's own timeout plus an explicit kill).

The harness EXPORTS `SEEDED_RECALL_*` into its children, so every run below builds
its environment explicitly rather than inheriting one.

Run: `python3 tests/seeded_failover_test.py`
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "..", "hooks", "seeded-recall.sh")
ENGINE_DIR = os.path.join(HERE, "..", "scripts", "scoped-memory")

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


# A wedged qmd: spawns two long-lived grandchildren (recorded by PID so survival is
# checkable without `pgrep -f`, which cannot see through /bin/sh's exec rewrite) and
# then waits on them, so the hook's wall budget expires here.
WEDGED_STUB = """#!/usr/bin/env bash
sleep 300 & echo $! >> "$SR_PIDFILE"
sleep 300 & echo $! >> "$SR_PIDFILE"
wait
"""

# A healthy qmd: instant valid results, a body carrying a unique token, empty status.
HEALTHY_STUB = """#!/usr/bin/env bash
case "$1" in
  vsearch) printf '[{"file":"failover_stub_body.md","title":"Failover Stub","score":0.9}]' ;;
  get)     printf 'HEALTHYSTUBTOKEN body content\\n' ;;
  status)  printf 'QMD Status\\nPending: 0 need embedding\\n' ;;
  *)       exit 0 ;;
esac
"""

#: The one memory the confident-fallback scenarios are supposed to surface. Its
#: distinctive terms appear nowhere else in the fixture store, so it is the sole
#: candidate and passes on the absolute floor alone (the documented SINGLETON case).
HIT_BODY = """---
name: frobnicator-calibration
description: how the frobnicator calibration bench is wired
metadata:
  type: reference
---

The frobnicator calibration bench needs its frobnicator recalibrated whenever the
calibration jig drifts. FROBNICATORTOKEN marks this body for the test.
"""

DECOY = """---
name: unrelated-note
description: something else entirely
metadata:
  type: reference
---

Nothing in this body shares a term with the query under test.
"""

#: Two bodies with IDENTICAL text: any query matching one matches the other exactly
#: as well, so top1/top2 == 1.00 and the separation gate must reject the pair.
FLAT_BODY = """---
name: flat-one
description: flat
metadata:
  type: reference
---

Ambiguous quibbleplex content that says nothing distinguishing at all.
"""


def make_store(root, name, bodies):
    store = os.path.join(root, name)
    os.makedirs(store, exist_ok=True)
    for fname, text in bodies.items():
        with open(os.path.join(store, fname), "w", encoding="utf-8") as fh:
            fh.write(text)
    return store


def run_hook(prompt, session, env_overrides, path_dir, cwd=None, timeout=30):
    """Run the hook with a fully explicit environment. Returns (stdout, exit)."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("SEEDED_RECALL_", "MEMORY_LOCAL_", "MEMORY_ACT_"))}
    env["PATH"] = path_dir + ":/usr/bin:/bin"
    env.update({k: str(v) for k, v in env_overrides.items()})
    payload = json.dumps({"prompt": prompt, "session_id": session})
    p = subprocess.Popen(["bash", HOOK], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, env=env, cwd=cwd or HERE,
                         start_new_session=True)
    try:
        out, _ = p.communicate(payload, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        return "", 99
    return out, p.returncode


def arm_cooldown(flag_dir, count=2):
    """Pre-write an armed failure stamp — the state two wedged probes would leave."""
    os.makedirs(flag_dir, exist_ok=True)
    with open(os.path.join(flag_dir, "qmd-failure-stamp"), "w") as fh:
        json.dump({"count": count, "ts": time.time(), "budget": 6.0,
                   "source": "seeded"}, fh)


def alive(pidfile, offset=0):
    try:
        pids = [int(x) for x in open(pidfile).read().split()]
    except (OSError, ValueError):
        return 0, 0
    pids = pids[offset:]
    n = 0
    for pid in pids:
        try:
            os.kill(pid, 0)
            n += 1
        except OSError:
            pass
    return len(pids), n


NOTICE = "local index fallback active"
MARKER = "[source: local-fallback]"


def main():
    root = tempfile.mkdtemp(prefix="seeded-failover.")
    try:
        bindir = os.path.join(root, "wedgedbin")
        healdir = os.path.join(root, "healthybin")
        os.makedirs(bindir)
        os.makedirs(healdir)
        write_exec(os.path.join(bindir, "qmd"), WEDGED_STUB)
        write_exec(os.path.join(healdir, "qmd"), HEALTHY_STUB)
        pidfile = os.path.join(root, "child-pids")
        open(pidfile, "w").close()

        hit_store = make_store(root, "store-hit", {
            "reference_frobnicator_calibration.md": HIT_BODY,
            "reference_unrelated.md": DECOY,
        })
        flat_store = make_store(root, "store-flat", {
            "reference_flat_one.md": FLAT_BODY,
            "reference_flat_two.md": FLAT_BODY,
        })

        # Floors are set explicitly per scenario, in the LOCAL index's own units —
        # the qmd-side floors are inert on BM25 scores (KTD12), so a test that let
        # them stand in would be testing nothing.
        local_env = {"MEMORY_LOCAL_FLOOR_MIN": "0.1",
                     "MEMORY_LOCAL_FLOOR_RATIO": "1.4"}
        wedged_env = {"SR_PIDFILE": pidfile, "SEEDED_RECALL_TIMEOUT": "1"}

        # -- scenario 1: wedged qmd, past the failure threshold -> notice + body ---
        f1 = os.path.join(root, "flags-1")
        env1 = dict(wedged_env, SEEDED_RECALL_FLAG_DIR=f1,
                    SEEDED_RECALL_MEMORY_DIR=hit_store, **local_env)
        out_a, rc_a = run_hook("frobnicator calibration", "F1A", env1, bindir)
        check("transient tolerance: 1st wedged prompt stays silent (unchanged)",
              rc_a == 0 and out_a.strip() == "")
        out_b, rc_b = run_hook("frobnicator calibration", "F1B", env1, bindir)
        check("wedged past threshold: exits 0", rc_b == 0)
        check("wedged past threshold: states the degradation", NOTICE in out_b)
        check("wedged past threshold: names the local-fallback source",
              MARKER in out_b)
        check("wedged past threshold: injects the matching memory body",
              "FROBNICATORTOKEN" in out_b)
        check("wedged past threshold: body rides the EXISTING wrapper",
              out_b.startswith('<recalled-memories source="seeded-recall">')
              and out_b.rstrip().endswith("</recalled-memories>"))

        # -- scenario 1b: injected fallback bodies are logged to RECALL.log --------
        rec = os.path.join(hit_store, "RECALL.log")
        line = open(rec).read().strip().splitlines()[-1] if os.path.exists(rec) else ""
        fields = line.split()
        check("telemetry: injected fallback body logged with source `seeded`",
              len(fields) >= 5 and fields[2] == "seeded"
              and fields[3] == "reference_frobnicator_calibration"
              and fields[4] == "local-fallback")

        # -- scenario 2: armed cooldown, healthy store -> notice once per session --
        f2 = os.path.join(root, "flags-2")
        arm_cooldown(f2)
        env2 = dict(wedged_env, SEEDED_RECALL_FLAG_DIR=f2,
                    SEEDED_RECALL_MEMORY_DIR=hit_store, **local_env)
        before = sum(1 for _ in open(pidfile))
        out_c, rc_c = run_hook("frobnicator calibration", "F2", env2, bindir)
        spawned, _ = alive(pidfile, before)
        check("armed cooldown: emits the notice instead of nothing",
              rc_c == 0 and NOTICE in out_c)
        check("armed cooldown: injects the fallback body", "FROBNICATORTOKEN" in out_c)
        check("armed cooldown: makes no qmd call at all", spawned == 0)
        out_d, rc_d = run_hook("frobnicator calibration", "F2", env2, bindir)
        check("armed cooldown: 2nd prompt in the SAME session emits nothing",
              rc_d == 0 and out_d.strip() == "")

        # -- scenario 3: wedged qmd, flat local scores -> loud state, no bodies ----
        f3 = os.path.join(root, "flags-3")
        arm_cooldown(f3)
        env3 = dict(wedged_env, SEEDED_RECALL_FLAG_DIR=f3,
                    SEEDED_RECALL_MEMORY_DIR=flat_store, **local_env)
        out_e, rc_e = run_hook("quibbleplex ambiguous content", "F3", env3, bindir)
        check("flat scores: hook still exits 0", rc_e == 0)
        check("flat scores: gate holds — no memory body injects",
              "quibbleplex" not in out_e.lower().replace(NOTICE, ""))
        check("flat scores: no local-fallback body marker", MARKER not in out_e)
        check("flat scores: still loud about STATE", NOTICE in out_e)

        # -- scenario 4: healthy qmd -> today's behavior, byte for byte ------------
        f4 = os.path.join(root, "flags-4")
        mem4 = make_store(root, "store-healthy", {})
        env4 = {"SEEDED_RECALL_FLAG_DIR": f4, "SEEDED_RECALL_MEMORY_DIR": mem4}
        out_f, rc_f = run_hook("anything at all", "F4", env4, healdir)
        expected = ('<recalled-memories source="seeded-recall">\n'
                    '### Failover Stub\nHEALTHYSTUBTOKEN body content\n'
                    '</recalled-memories>\n')
        check("healthy qmd: output is byte-identical to the pre-U4 shape",
              rc_f == 0 and out_f == expected)
        check("healthy qmd: no degradation notice", NOTICE not in out_f)
        check("healthy qmd: no fallback marker", MARKER not in out_f)

        # -- scenario 5: wedged timeout leaves no orphaned processes ---------------
        f5 = os.path.join(root, "flags-5")
        env5 = dict(wedged_env, SEEDED_RECALL_FLAG_DIR=f5,
                    SEEDED_RECALL_MEMORY_DIR=hit_store, **local_env)
        before = sum(1 for _ in open(pidfile))
        run_hook("frobnicator calibration", "F5", env5, bindir)
        time.sleep(0.5)
        recorded, still = alive(pidfile, before)
        check("group-kill: the wedged stub really spawned children (test is live)",
              recorded >= 1)
        check("group-kill: no orphaned qmd descendants survive the fail-over",
              still == 0)

        # reap anything the stubs left behind
        try:
            for pid in [int(x) for x in open(pidfile).read().split()]:
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
        except (OSError, ValueError):
            pass
    finally:
        shutil.rmtree(root, ignore_errors=True)

    print(f"seeded_failover_test: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
