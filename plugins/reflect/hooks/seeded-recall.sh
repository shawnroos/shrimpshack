#!/usr/bin/env bash
#
# seeded-recall.sh — UserPromptSubmit hook. Once per session, on the first
# prompt, inject the most relevant memory bodies as added context.
#
# Reads the hook payload from stdin JSON (.prompt, .session_id). Performs a VECTOR
# search (`qmd vsearch`) under a hard wall budget. The Phase B spike (see
# scripts/spikes/RESULTS.md) measured recall@3 of 0.75 for vsearch vs 0.25 for
# full-prompt BM25 — BM25 is AND-over-content-terms, so a realistic paraphrased
# prompt under-recalls. vsearch costs latency (p50 ~4s, cold-load tail to ~20s);
# the fail-open wall budget below handles the tail (a slow first prompt simply
# gets no recall that session — never blocked). `qmd query` (hybrid+rerank) is
# avoided: it loads three models and stalls ~18-31s. Bounds results in-script
# (top-K + optional global floor + an activation-scaled per-memory floor) because
# qmd silently swallows unknown flags. Fetches each body with `qmd get` and emits
# them on stdout (exit 0 → injected context).
#
# Fail-safe: any missing qmd, error, or timeout exits 0 with no output — recall
# degrades to the manual pointer-index fallback, the prompt is never blocked. A
# slow/wedged qmd is not just tolerated but *remembered*: after N consecutive health
# failures a cross-session cooldown stamp short-circuits future prompts (no qmd call)
# until it ages out, so a wedged qmd costs a bounded few probes per window instead of
# taxing every prompt. qmd children run in their own process group and are killed as
# a group on timeout, so no orphaned model-loader subprocesses survive the hook.
#
# Config (env, all optional):
#   SEEDED_RECALL_COLLECTION      (default claude-memory)
#   SEEDED_RECALL_K               (default 3)        top-K bodies to inject
#   SEEDED_RECALL_TIMEOUT         (default 6)        seconds, TOTAL wall budget across
#                                                    all qmd calls; above healthy
#                                                    vsearch latency, under the 8s hook
#                                                    ceiling (headroom is the group-kill)
#   SEEDED_RECALL_MIN_SCORE       (default unset)    drop results below this score
#   SEEDED_RECALL_MAX_BODY        (default 1200)     chars per body, budget guard
#   SEEDED_RECALL_FLAG_DIR        (default $TMPDIR/claude-seeded-recall)
#   SEEDED_RECALL_COOLDOWN        (default 600)      seconds an armed failure stamp
#                                                    suppresses recall (cross-session)
#   SEEDED_RECALL_FAIL_THRESHOLD  (default 2)        consecutive failures before the
#                                                    cooldown arms (transient tolerance)
#   SEEDED_RECALL_FORCE=1         bypass the once-per-session guard AND the cooldown (tests)

INPUT="$(cat)"
export CLAUDE_HOOK_INPUT="$INPUT"
# Shared scope module (plan 003 U2/U4). If absent/broken, recall falls back to
# today's unscoped behavior — scoping is purely additive and never required.
export SCOPED_MEMORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts/scoped-memory" 2>/dev/null && pwd)"

exec python3 - <<'PY'
import os, sys, json, subprocess, hashlib, re, time, signal

def out_nothing():
    sys.exit(0)

# Shared scope module — repo-scoped recall (plan 003). Import is fail-open: any
# problem leaves `scope` as None and recall behaves exactly as it did pre-scoping.
scope = None
try:
    _smd = os.environ.get("SCOPED_MEMORY_DIR")
    if _smd and os.path.isdir(_smd):
        sys.path.insert(0, _smd)
        import scope as scope  # noqa: F401  (resolver + qmd-path parse/match)
except Exception:
    scope = None

try:
    payload = json.loads(os.environ.get("CLAUDE_HOOK_INPUT", "") or "{}")
except Exception:
    out_nothing()

prompt = (payload.get("prompt") or "").strip()
session_id = (payload.get("session_id") or "").strip()
if not prompt:
    out_nothing()

collection = os.environ.get("SEEDED_RECALL_COLLECTION", "claude-memory")
try:
    K = max(1, int(os.environ.get("SEEDED_RECALL_K", "3")))
except ValueError:
    K = 3
# SEEDED_RECALL_TIMEOUT is the TOTAL wall budget across all qmd calls (git +
# search + K gets + status), not per-call — so the hook can't blow past the
# settings-level hook timeout (keep this default below it). run() draws each
# call's timeout from the remaining budget.
try:
    # The default must sit ABOVE healthy vsearch latency (p50 ~4s per the header),
    # not be minimized: too low a budget starves the healthy median query and, via
    # the cooldown stamp below, would suppress recall on a working qmd. The 8s
    # ceiling headroom comes from run()'s process-group kill (near-instant teardown),
    # NOT from a small budget. 6 leaves room for the follow-on gets while staying
    # under 8s even after the bounded kill escalation. Validate against a measured
    # healthy full-path number, never the wedged-index pathology.
    budget = float(os.environ.get("SEEDED_RECALL_TIMEOUT", "6"))
except ValueError:
    budget = 6.0
try:
    raw_ms = os.environ.get("SEEDED_RECALL_MIN_SCORE")
    min_score = float(raw_ms) if raw_ms not in (None, "") else None
except ValueError:
    min_score = None
try:
    max_body = max(200, int(os.environ.get("SEEDED_RECALL_MAX_BODY", "1200")))
except ValueError:
    max_body = 1200

flag_dir = os.environ.get("SEEDED_RECALL_FLAG_DIR") or os.path.join(
    os.environ.get("TMPDIR", "/tmp"), "claude-seeded-recall")
force = os.environ.get("SEEDED_RECALL_FORCE") == "1"

# Cross-session failure cooldown (KTD1). A qmd *health* failure is recorded in a
# single shared stamp (fixed name, not session-keyed) carrying a consecutive-failure
# count and the failure time. Recall self-suppresses only once the count reaches the
# threshold AND the stamp is still fresh — so one transient blip (count 1) does not
# black out recall, but a persistently-wedged qmd is capped at `threshold` probes
# then silence for the TTL. A success clears the stamp (self-heal).
try:
    cooldown = float(os.environ.get("SEEDED_RECALL_COOLDOWN", "600"))
except ValueError:
    cooldown = 600.0
try:
    fail_threshold = max(1, int(os.environ.get("SEEDED_RECALL_FAIL_THRESHOLD", "2")))
except ValueError:
    fail_threshold = 2
stamp_path = os.path.join(flag_dir, "qmd-failure-stamp")

def _read_stamp():
    """Return (count, ts) from the stamp, or (0, 0.0) on any problem (fail open)."""
    try:
        with open(stamp_path) as fh:
            d = json.load(fh)
        return int(d.get("count", 0)), float(d.get("ts", 0.0))
    except Exception:
        return 0, 0.0

def note_failure():
    """Record one qmd-health failure. Continues the streak only if the prior stamp is
    still fresh; a stale prior stamp starts a new streak. Best-effort — never raises."""
    try:
        count, ts = _read_stamp()
        prev = count if (time.time() - ts) < cooldown else 0
        os.makedirs(flag_dir, exist_ok=True)
        tmp = stamp_path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump({"count": prev + 1, "ts": time.time()}, fh)
        os.replace(tmp, stamp_path)
    except Exception:
        pass  # best-effort; worst case the cooldown just doesn't arm this round

def clear_stamp():
    """Drop the failure stamp on success so a recovered qmd resets the streak."""
    try:
        os.remove(stamp_path)
    except OSError:
        pass

# Once-per-session guard (keyed on session id; hash so the filename is safe). The
# flag is checked here but WRITTEN only after we successfully build output (near
# the end) — so a cold/timed-out/empty first prompt does not disable recall for
# the rest of the session; it simply retries on the next prompt.
flag = None
if not force:
    key = session_id or "no-session"
    flag = os.path.join(flag_dir, hashlib.sha1(key.encode()).hexdigest())
    if os.path.exists(flag):
        out_nothing()              # already injected this session
    # Cooldown gate: a fresh, armed failure stamp means a recent qmd probe (or two)
    # already failed — skip immediately, no qmd call, so a wedged qmd stops taxing
    # every prompt. A count below the threshold does NOT suppress (transient tolerance).
    _c, _ts = _read_stamp()
    if _c >= fail_threshold and (time.time() - _ts) < cooldown:
        out_nothing()

deadline = time.monotonic() + budget

def _killpg(p):
    """Terminate the child's whole process group so a wedged qmd leaves no orphaned
    grandchildren (subprocess timeout only signals the direct child). SIGTERM first
    for a clean exit, then SIGKILL as a backstop; all best-effort."""
    try:
        pgid = os.getpgid(p.pid)
    except OSError:
        pgid = None
    def _sig(s):
        try:
            if pgid is not None:
                os.killpg(pgid, s)
            else:
                p.send_signal(s)
        except OSError:
            pass
    _sig(signal.SIGTERM)
    try:
        p.wait(timeout=0.3)
        return                       # exited cleanly on SIGTERM
    except Exception:
        pass                         # includes TimeoutExpired -> escalate to SIGKILL
    _sig(signal.SIGKILL)
    try:
        p.wait(timeout=0.2)
    except Exception:
        pass

def run(args):
    """Run a qmd command, bounded by the REMAINING wall budget. Returns stdout, or
    None on any failure (missing binary, non-zero exit, timeout, budget spent). The
    child runs in its own process group (start_new_session) and, on timeout, the whole
    group is killed — no orphaned qmd model-loader subprocesses survive the hook."""
    remaining = deadline - time.monotonic()
    if remaining <= 0.05:
        return None
    try:
        p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, start_new_session=True)
    except (FileNotFoundError, OSError):
        return None
    try:
        out, _ = p.communicate(timeout=remaining)
    except subprocess.TimeoutExpired:
        _killpg(p)                   # wedged qmd: reap the whole group, fail open
        return None
    except Exception:
        _killpg(p)                   # any other error: same — never leak a child
        return None
    if p.returncode != 0:
        return None
    return out

# Vector search is semantic — the prompt alone is the query. The branch name
# (a useful lexical signal for the old BM25 path) is noise for a vector query and
# is dropped; repo scoping is applied separately below via the working directory.
query = prompt[:400]

# `--` ends flag parsing so a leading-dash prompt can't inject a flag (e.g. a
# second -c that redirects the collection).
raw = run(["qmd", "vsearch", "-c", collection, "--format", "json", "--", query])
if not raw:
    # The one genuine qmd-health signal: vsearch itself failed (missing binary,
    # timeout, non-zero exit, unparseable output). Record it toward the cooldown.
    # Downstream empty/filtered result sets and get-loop misses are NOT health
    # failures (qmd answered) and deliberately do not stamp.
    note_failure()
    out_nothing()
try:
    results = json.loads(raw)
except Exception:
    out_nothing()
if not isinstance(results, list) or not results:
    out_nothing()

# In-script bounding: optional GLOBAL score floor (governs global selection,
# unchanged), then keep results carrying a file. Top-K is applied below.
if min_score is not None:
    results = [r for r in results if isinstance(r, dict)
               and isinstance(r.get("score"), (int, float)) and r["score"] >= min_score]
results = [r for r in results if isinstance(r, dict) and r.get("file")]
# Drop the index itself: MEMORY.md is in the QMD collection and matches almost any
# prompt (it carries every hook), so it scores high and would pollute recall. The
# index is auto-loaded already — recall is for the bodies behind it.
results = [r for r in results if os.path.basename(r["file"]) != "MEMORY.md"]
if not results:
    out_nothing()

# Activation-scaled floor (U6) — the "more intention to reach" proxy. A faded
# (low-activation) memory must clear a HIGHER vector-score floor to surface than a
# fresh one; a pinned/fresh memory clears a low floor. Fully fail-open: any
# problem (no activation module, body not found, parse error) leaves the result
# in, so recall never degrades below the global-floor behavior above.
try:
    # Locate memory_activation.py via SCOPED_MEMORY_DIR (exported above, absolute,
    # = <scripts>/scoped-memory) — NOT __file__, which is the literal "<stdin>"
    # under `python3 - <<'PY'` and would resolve against the cwd.
    import importlib.util as _ilu
    _scripts = os.path.dirname(os.environ.get("SCOPED_MEMORY_DIR", "") or "")
    if not _scripts:
        raise RuntimeError("no SCOPED_MEMORY_DIR")
    _spec = _ilu.spec_from_file_location("memory_activation",
                                         os.path.join(_scripts, "memory_activation.py"))
    _ma = _ilu.module_from_spec(_spec); _spec.loader.exec_module(_ma)
    from datetime import date as _date, datetime as _dt

    def _floorf(name, default):
        try:
            v = os.environ.get(name)
            return float(v) if v not in (None, "") else default
        except ValueError:
            return default
    _base = _floorf("SEEDED_RECALL_FLOOR_BASE", 0.45)   # floor a FRESH memory must clear
    _span = _floorf("SEEDED_RECALL_FLOOR_SPAN", 0.15)   # extra a fully-faded one must clear
    _ref = _floorf("SEEDED_RECALL_FLOOR_ACT_REF", 1.3)  # activation treated as "fresh"

    # Canonical store dir (same derivation as the lint/render scripts).
    _slug = "-" + os.path.expanduser("~").lstrip("/").replace("/", "-")
    _memdir = os.environ.get("SEEDED_RECALL_MEMORY_DIR") or os.path.expanduser(
        f"~/.claude/projects/{_slug}/memory")
    _today = _date.today()
    # Read use-frequency once (not per candidate) so the floor scores activation
    # from the SAME inputs as the render — a frequently-cited memory shouldn't face
    # a harsher floor than its true (frequency-boosted) activation warrants.
    _use_counts = _ma.use_counts(os.path.join(_memdir, "MEMORY_USE.log"))

    def _act_for(pointer):
        # qmd pointers dash-case the filename; bodies use underscores.
        base = os.path.basename(pointer)
        cand = base.replace("-", "_")
        for fn in (cand, base):
            p = os.path.join(_memdir, fn)
            if os.path.isfile(p):
                try:
                    md = _dt.fromtimestamp(os.path.getmtime(p)).date()
                except Exception:
                    md = None
                stem = fn[:-3]
                uc = _use_counts.get(stem, 0) or _use_counts.get(stem.replace("_", "-"), 0)
                return _ma.activation(_today, _ma.parse_last_used(p), md, uc,
                                      _ma.parse_pinned(p))
        return None

    def _passes(r):
        a = _act_for(r["file"])
        if a is None:
            return True                      # unknown -> keep (fail-open)
        required = _ma.recall_floor(a, _base, _span, _ref)
        s = r.get("score")
        return not isinstance(s, (int, float)) or s >= required

    _filtered = [r for r in results if _passes(r)]
    if _filtered:                            # never let the floor empty the set to nothing
        results = _filtered
except Exception:
    pass                                     # any failure -> unchanged results

# Repo-scoped recall (plan 003 U4): keep today's top-K of the GLOBAL/ancestor pool,
# then ADD the single best current-repo memory above a DISTINCT repo floor as a
# K+1th item (front-and-center). Siblings (other repos) are suppressed. Degrades to
# today's exact behavior when the scope module is unavailable, we're not in a repo,
# or there are no scoped results. Globals are never displaced — the extra is additive.
try:
    _rf = os.environ.get("SEEDED_RECALL_REPO_MIN_SCORE")
    repo_floor = float(_rf) if _rf not in (None, "") else None
except ValueError:
    repo_floor = None

if scope:
    try:
        # Shared pure function (also unit-tested in the harness) — no hook/test drift.
        # Bound git to the REMAINING wall budget and fail open to today's behavior on
        # any error (e.g. os.getcwd() on a deleted cwd) — recall must never crash.
        _t = max(0.1, deadline - time.monotonic())
        cur_slug = scope.resolve_repo_slug(os.getcwd(), timeout=_t)
        results = scope.select_scoped(results, cur_slug, K, repo_floor)
    except Exception:
        results = results[:K]
else:
    results = results[:K]                        # scope module absent -> today's behavior
if not results:
    out_nothing()

blocks = []
for r in results:
    pointer = r["file"]
    title = (r.get("title") or pointer).strip()
    body = run(["qmd", "get", pointer, "--no-line-numbers"])
    if not body:
        continue
    body = body.strip()
    if len(body) > max_body:
        body = body[:max_body].rstrip() + "\n…(truncated)"
    # Neutralize a literal closing tag in body/title so a memory's content can't
    # break out of the <recalled-memories> wrapper it's injected into (zero-width
    # space after '<' breaks the literal tag while staying visually identical).
    def _safe(s):
        return s.replace("</recalled-memories>", "<​/recalled-memories>")
    blocks.append(f"### {_safe(title)}\n{_safe(body)}")

if not blocks:
    out_nothing()

# Best-effort staleness note: if status reports the collection has pending
# embeddings, recall may be incomplete. Never fatal.
stale_note = ""
status = run(["qmd", "status"])
if status:
    m = re.search(r"Pending:\s*([\d,]+)\s+need embedding", status)
    if m and m.group(1).replace(",", "") not in ("0", ""):
        stale_note = ("> recall may be incomplete — the memory index has pending "
                      "embeddings (run `qmd embed -c %s`)\n\n" % collection)

# We have output to inject — NOW mark the session done so we don't re-fire.
if flag is not None:
    try:
        os.makedirs(flag_dir, exist_ok=True)
        open(flag, "w").close()
    except Exception:
        pass  # best-effort; worst case recall fires again next prompt

# qmd answered successfully — clear any failure stamp so a recovered qmd resets the
# streak and doesn't sit under a lingering cooldown (self-heal). Best-effort.
clear_stamp()

print("<recalled-memories source=\"seeded-recall\">")
if stale_note:
    print(stale_note, end="")
print("\n\n---\n\n".join(blocks))
print("</recalled-memories>")
sys.exit(0)
PY
