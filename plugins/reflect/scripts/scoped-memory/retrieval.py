#!/usr/bin/env python3
"""retrieval.py — the shared qmd retrieval engine (plan U9, KTD8).

This module is the ONE retrieval engine. It used to live inside the bash heredoc
in `hooks/seeded-recall.sh`, where nothing could import it, so the recall CLI
copied it — which is how the hook/CLI drift this plan exists to fix was created.
The move preserves every contract the hook had: total wall budget across all qmd
calls, per-call timeouts drawn from the REMAINING budget, process-group kill on a
wedged child, the cross-session failure stamp with its threshold/TTL, the
"one genuine health signal" stamping discipline (only a failed `vsearch` stamps;
empty/filtered result sets and get-loop misses do not), and self-heal on success.

Callers: `hooks/seeded-recall.sh` (session start, short budget) and the recall CLI
(deliberate, longer budget). The hook keeps only stdin parsing, the once-per-session
guard, and output formatting.

Two decisions settled during the extraction:

1. **The cooldown stamp is store-adjacent, not `$TMPDIR`-relative.** The hook runs
   in the hook executor and the CLI runs inside the Bash tool; those are not
   guaranteed the same `TMPDIR`. Divergent paths mean the CLI reads a nonexistent
   stamp, fails open, and re-probes a wedged qmd for its full budget — the exact
   hang KTD8 exists to prevent, failing silently. The state dir is now derived from
   `$HOME` alone: `~/.claude/projects/<home-slug>/recall-state` — a SIBLING of the
   memory store, not inside it (a JSON stamp inside the store would show up as a
   store artifact to the corpus/lint readers). `SEEDED_RECALL_FLAG_DIR` still
   overrides it, and remains the test idiom.

2. **Budget asymmetry: honoring is unconditional, stamping is conditional.**
   Hook and CLI run different budgets against one shared failure counter, so a
   short-budget path could otherwise black out session-start recall for every
   session for the whole TTL. The rule:

   - **Honoring** an armed stamp is unconditional (KTD8: the CLI reads the shared
     stamp and skips straight to its fallback rather than re-taxing a wedged qmd).
     A stamp with no recorded budget (written by pre-U9 code) also suppresses —
     that is exactly today's hook contract.
   - **Stamping** requires `budget >= stamp_min_budget`: a path that gave qmd LESS
     time than session-start recall would have does not get to declare qmd wedged.
     The hook passes its own budget (so it always stamps — its behavior is
     unchanged, including the harness's `SEEDED_RECALL_TIMEOUT=1` blocks); the CLI
     passes the session-start budget, so a CLI timeout only arms the shared
     cooldown when it waited at least as long as the hook would have.

   The stamp records `budget` and `source` so a later loud-wedge message can say
   which path armed it and under what deadline.

Everything is fail-open: any error anywhere degrades to "no results", never an
exception into the caller's face and never a blocked prompt.
"""
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)

# Shared scope module — repo-scoped recall (plan 003). Import is fail-open: any
# problem leaves `scope` as None and recall behaves exactly as it did pre-scoping.
try:
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    import scope as scope  # noqa: F401  (resolver + qmd-path parse/match)
except Exception:
    scope = None

STAMP_NAME = "qmd-failure-stamp"
DEFAULT_BUDGET = 6.0
DEFAULT_COOLDOWN = 600.0
DEFAULT_FAIL_THRESHOLD = 2


# --------------------------------------------------------------- state location
def state_dir(flag_dir=None):
    """Directory holding the cooldown stamp and the once-per-session flags.

    Fixed and store-adjacent so every path (hook executor, Bash tool, subagent)
    derives the SAME location; `$TMPDIR` is deliberately not a component. The
    explicit argument, then `SEEDED_RECALL_FLAG_DIR`, are test overrides.
    """
    if flag_dir:
        return flag_dir
    env = os.environ.get("SEEDED_RECALL_FLAG_DIR")
    if env:
        return env
    home = os.path.expanduser("~")
    slug = scope.slugify(home)
    return os.path.join(home, ".claude", "projects", slug, "recall-state")


def cooldown_stamp_path(flag_dir=None):
    """Absolute path of the shared cross-session qmd-failure stamp."""
    return os.path.join(state_dir(flag_dir), STAMP_NAME)


def session_flag_path(session_id, flag_dir=None):
    """Once-per-session marker path (hashed so the filename is always safe)."""
    key = session_id or "no-session"
    return os.path.join(state_dir(flag_dir), hashlib.sha1(key.encode()).hexdigest())


# ------------------------------------------------------------------ health state
class HealthState:
    """The shared qmd health signal: a single stamp (fixed name, not session-keyed)
    carrying a consecutive-failure count, the failure time, and the budget/source
    that produced it. Recall self-suppresses only once the count reaches the
    threshold AND the stamp is still fresh — so one transient blip does not black
    out recall, but a persistently-wedged qmd costs `threshold` probes per TTL."""

    def __init__(self, flag_dir=None, cooldown=DEFAULT_COOLDOWN,
                 threshold=DEFAULT_FAIL_THRESHOLD, source="seeded"):
        self.dir = state_dir(flag_dir)
        self.path = os.path.join(self.dir, STAMP_NAME)
        self.cooldown = cooldown
        self.threshold = threshold
        self.source = source

    def read(self):
        """Return the stamp dict, or {} on any problem (fail open)."""
        try:
            with open(self.path) as fh:
                d = json.load(fh)
            return d if isinstance(d, dict) else {}
        except Exception:
            return {}

    def armed(self):
        """True when a fresh stamp has reached the failure threshold — skip qmd.

        Honoring is unconditional (see module docstring): a stamp written by any
        path suppresses, including a pre-U9 stamp with no recorded budget.
        """
        d = self.read()
        try:
            count = int(d.get("count", 0))
            ts = float(d.get("ts", 0.0))
        except (TypeError, ValueError):
            return False
        return count >= self.threshold and (time.time() - ts) < self.cooldown

    def note_failure(self, budget=None, stamp_min_budget=None):
        """Record one qmd-health failure. Continues the streak only if the prior
        stamp is still fresh; a stale prior stamp starts a new streak. Skipped
        entirely when this path's budget is below `stamp_min_budget` (a path that
        gave qmd less time than session-start recall does not get to declare it
        wedged). Best-effort — never raises."""
        if (stamp_min_budget is not None and budget is not None
                and budget < stamp_min_budget):
            return False
        try:
            d = self.read()
            try:
                count = int(d.get("count", 0))
                ts = float(d.get("ts", 0.0))
            except (TypeError, ValueError):
                count, ts = 0, 0.0
            prev = count if (time.time() - ts) < self.cooldown else 0
            os.makedirs(self.dir, exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump({"count": prev + 1, "ts": time.time(),
                           "budget": budget, "source": self.source}, fh)
            os.replace(tmp, self.path)
            return True
        except Exception:
            return False  # best-effort; worst case the cooldown just doesn't arm

    def clear(self):
        """Drop the failure stamp on success so a recovered qmd resets the streak."""
        try:
            os.remove(self.path)
        except OSError:
            pass


# ------------------------------------------------------------------------ config
def _f(name, default):
    try:
        v = os.environ.get(name)
        return float(v) if v not in (None, "") else default
    except ValueError:
        return default


class Config:
    """Retrieval knobs, all env-overridable — one parse shared by hook and CLI."""

    def __init__(self, **kw):
        env = os.environ.get
        self.collection = kw.get("collection") or env("SEEDED_RECALL_COLLECTION",
                                                      "claude-memory")
        try:
            self.k = max(1, int(env("SEEDED_RECALL_K", "3")))
        except ValueError:
            self.k = 3
        if kw.get("k"):
            self.k = max(1, int(kw["k"]))
        # TOTAL wall budget across all qmd calls (search + K gets + status), not
        # per-call. The default sits ABOVE healthy vsearch latency (p50 ~4s), not
        # minimized: too low a budget starves the healthy median query and, via the
        # cooldown stamp, would suppress recall on a working qmd. Headroom under the
        # 8s hook ceiling comes from the process-group kill, not from a small budget.
        self.budget = kw.get("budget")
        if self.budget is None:
            self.budget = _f("SEEDED_RECALL_TIMEOUT", DEFAULT_BUDGET)
        # A failure only arms the shared cooldown when this path waited at least
        # this long (module docstring, decision 2).
        self.stamp_min_budget = kw.get("stamp_min_budget", self.budget)
        raw_ms = env("SEEDED_RECALL_MIN_SCORE")
        try:
            self.min_score = float(raw_ms) if raw_ms not in (None, "") else None
        except ValueError:
            self.min_score = None
        try:
            self.max_body = max(200, int(env("SEEDED_RECALL_MAX_BODY", "1200")))
        except ValueError:
            self.max_body = 1200
        self.cooldown = _f("SEEDED_RECALL_COOLDOWN", DEFAULT_COOLDOWN)
        try:
            self.fail_threshold = max(1, int(env("SEEDED_RECALL_FAIL_THRESHOLD", "2")))
        except ValueError:
            self.fail_threshold = DEFAULT_FAIL_THRESHOLD
        self.flag_dir = kw.get("flag_dir") or env("SEEDED_RECALL_FLAG_DIR") or None
        self.force = kw.get("force")
        if self.force is None:
            self.force = env("SEEDED_RECALL_FORCE") == "1"
        self.floor_base = _f("SEEDED_RECALL_FLOOR_BASE", 0.45)
        self.floor_span = _f("SEEDED_RECALL_FLOOR_SPAN", 0.15)
        self.floor_ref = _f("SEEDED_RECALL_FLOOR_ACT_REF", 1.3)
        rf = env("SEEDED_RECALL_REPO_MIN_SCORE")
        try:
            self.repo_floor = float(rf) if rf not in (None, "") else None
        except ValueError:
            self.repo_floor = None
        self.memory_dir = kw.get("memory_dir") or env("SEEDED_RECALL_MEMORY_DIR") or None
        self.source = kw.get("source", "seeded")


# ----------------------------------------------------------------------- results
class RecallItem:
    """One retrieved memory: where it came from, why it survived, and its body."""

    def __init__(self, pointer, title, body, score=None, source="qmd", gate="pass"):
        self.pointer = pointer
        self.title = title
        self.body = body
        self.score = score
        self.source = source          # retrieval layer that produced it
        self.gate = gate              # "pass" | "repo" (current-repo K+1 addition)

    def as_dict(self):
        return {"pointer": self.pointer, "title": self.title, "body": self.body,
                "score": self.score, "source": self.source, "gate": self.gate}


class RecallResult:
    """Structured outcome. `status` is the contract the callers branch on:

    ok          — items present
    cooldown    — armed failure stamp; no qmd call was made
    unavailable — qmd itself failed (missing/timeout/non-zero/unparseable output)
    empty       — qmd answered but nothing survived filtering, or no bodies fetched
    no-query    — nothing to search for
    below-gate  — LOCAL FALLBACK ONLY: candidates existed, none confident enough
    """

    def __init__(self, status, items=None, source="qmd", pending_embeddings=False,
                 budget=None, stamped=False, reason=""):
        self.status = status
        self.items = items or []
        self.source = source
        self.pending_embeddings = pending_embeddings
        self.budget = budget
        self.stamped = stamped
        self.reason = reason          # why a below-gate/empty result is empty

    def __bool__(self):
        return bool(self.items)

    def as_dict(self):
        return {"status": self.status, "source": self.source,
                "pending_embeddings": self.pending_embeddings,
                "items": [i.as_dict() for i in self.items]}


# ------------------------------------------------------------- bounded qmd runner
class Runner:
    """Runs qmd commands under a shared TOTAL wall budget. Each call's timeout is
    drawn from the REMAINING budget so a caller can't blow past its ceiling."""

    def __init__(self, budget):
        self.deadline = time.monotonic() + budget

    def remaining(self):
        return self.deadline - time.monotonic()

    @staticmethod
    def _killpg(p):
        """Terminate the child's whole process group so a wedged qmd leaves no
        orphaned grandchildren (subprocess timeout only signals the direct child).
        SIGTERM first for a clean exit, then SIGKILL as a backstop; best-effort."""
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
            pass                         # includes TimeoutExpired -> escalate
        _sig(signal.SIGKILL)
        try:
            p.wait(timeout=0.2)
        except Exception:
            pass

    def run(self, args):
        """Run a qmd command bounded by the REMAINING wall budget. Returns stdout,
        or None on any failure (missing binary, non-zero exit, timeout, budget
        spent). The child runs in its own process group and, on timeout, the whole
        group is killed — no orphaned qmd model-loader subprocesses survive."""
        remaining = self.remaining()
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
            self._killpg(p)              # wedged qmd: reap the whole group, fail open
            return None
        except Exception:
            self._killpg(p)              # any other error: same — never leak a child
            return None
        if p.returncode != 0:
            return None
        return out


# ------------------------------------------------------------- activation floor
def _apply_activation_floor(results, cfg):
    """Activation-scaled floor (U6) — the "more intention to reach" proxy. A faded
    (low-activation) memory must clear a HIGHER vector-score floor than a fresh one.
    Fully fail-open: any problem (no activation module, body not found, parse error)
    leaves the result in, so recall never degrades below the global-floor behavior."""
    try:
        import importlib.util as _ilu
        _spec = _ilu.spec_from_file_location(
            "memory_activation", os.path.join(SCRIPTS, "memory_activation.py"))
        _ma = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_ma)
        from datetime import date as _date, datetime as _dt

        # Canonical store dir (same derivation as the lint/render scripts).
        _slug = "-" + os.path.expanduser("~").lstrip("/").replace("/", "-")
        _memdir = cfg.memory_dir or os.path.expanduser(
            f"~/.claude/projects/{_slug}/memory")
        _today = _date.today()
        # Read use-frequency once (not per candidate) so the floor scores activation
        # from the SAME inputs as the render — a frequently-cited memory shouldn't
        # face a harsher floor than its true (frequency-boosted) activation warrants.
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
                    uc = (_use_counts.get(stem, 0)
                          or _use_counts.get(stem.replace("_", "-"), 0))
                    return _ma.activation(_today, _ma.parse_last_used(p), md, uc,
                                          _ma.parse_pinned(p))
            return None

        def _passes(r):
            a = _act_for(r["file"])
            if a is None:
                return True                      # unknown -> keep (fail-open)
            required = _ma.recall_floor(a, cfg.floor_base, cfg.floor_span,
                                        cfg.floor_ref)
            s = r.get("score")
            return not isinstance(s, (int, float)) or s >= required

        _filtered = [r for r in results if _passes(r)]
        if _filtered:                    # never let the floor empty the set entirely
            return _filtered
    except Exception:
        pass                             # any failure -> unchanged results
    return results


# ------------------------------------------------------------------- entry point
def recall(query, budget=None, health=None, config=None, cwd=None, **kw):
    """Retrieve memory bodies for `query` from qmd under a wall budget.

    query   — the text to search for (truncated to 400 chars, as the hook did)
    budget  — total wall seconds across every qmd call; defaults to config/env
    health  — a HealthState (the shared cooldown handle); built from config if None
    cwd     — working directory used to resolve the current repo scope

    Returns a RecallResult. Never raises for a retrieval-layer problem.
    """
    cfg = config or Config(budget=budget, **kw)
    if config is not None and budget is not None:
        cfg.budget = budget          # explicit budget overrides a reused Config
    if health is None:
        health = HealthState(cfg.flag_dir, cfg.cooldown, cfg.fail_threshold,
                             cfg.source)

    query = (query or "").strip()
    if not query:
        return RecallResult("no-query", budget=cfg.budget)

    # Cooldown gate: a fresh, armed failure stamp means a recent qmd probe (or two)
    # already failed — skip immediately, no qmd call, so a wedged qmd stops taxing
    # every caller. A count below the threshold does NOT suppress (transient
    # tolerance). FORCE bypasses the gate.
    if not cfg.force and health.armed():
        return RecallResult("cooldown", budget=cfg.budget)

    runner = Runner(cfg.budget)

    # Vector search is semantic — the query text alone is the query. `--` ends flag
    # parsing so a leading-dash prompt can't inject a flag (e.g. a second -c that
    # redirects the collection).
    raw = runner.run(["qmd", "vsearch", "-c", cfg.collection, "--format", "json",
                      "--", query[:400]])
    if not raw:
        # The one genuine qmd-health signal: vsearch itself failed (missing binary,
        # timeout, non-zero exit). Record it toward the cooldown. Downstream
        # empty/filtered result sets and get-loop misses are NOT health failures
        # (qmd answered) and deliberately do not stamp.
        stamped = health.note_failure(cfg.budget, cfg.stamp_min_budget)
        return RecallResult("unavailable", budget=cfg.budget, stamped=stamped)
    try:
        results = json.loads(raw)
    except Exception:
        # Preserved from the pre-extraction hook: unparseable output does NOT stamp.
        return RecallResult("empty", budget=cfg.budget)
    if not isinstance(results, list) or not results:
        return RecallResult("empty", budget=cfg.budget)

    # In-script bounding: optional GLOBAL score floor (governs global selection),
    # then keep results carrying a file. Top-K is applied below.
    if cfg.min_score is not None:
        results = [r for r in results if isinstance(r, dict)
                   and isinstance(r.get("score"), (int, float))
                   and r["score"] >= cfg.min_score]
    results = [r for r in results if isinstance(r, dict) and r.get("file")]
    # Drop the index itself: MEMORY.md is in the QMD collection and matches almost
    # any prompt (it carries every hook), so it scores high and would pollute
    # recall. The index is auto-loaded already — recall is for the bodies behind it.
    results = [r for r in results if os.path.basename(r["file"]) != "MEMORY.md"]
    if not results:
        return RecallResult("empty", budget=cfg.budget)

    results = _apply_activation_floor(results, cfg)

    # Repo-scoped recall (plan 003 U4): keep today's top-K of the GLOBAL/ancestor
    # pool, then ADD the single best current-repo memory above a DISTINCT repo floor
    # as a K+1th item (front-and-center). Siblings (other repos) are suppressed.
    # Degrades to today's exact behavior when the scope module is unavailable, we're
    # not in a repo, or there are no scoped results. Globals are never displaced.
    cur_slug = None
    if scope:
        try:
            # Shared pure function (also unit-tested in the harness) — no hook/test
            # drift. Bound git to the REMAINING wall budget and fail open to today's
            # behavior on any error (e.g. os.getcwd() on a deleted cwd).
            _t = max(0.1, runner.remaining())
            cur_slug = scope.resolve_repo_slug(cwd or os.getcwd(), timeout=_t)
            results = scope.select_scoped(results, cur_slug, cfg.k, cfg.repo_floor)
        except Exception:
            cur_slug = None
            results = results[:cfg.k]
    else:
        results = results[:cfg.k]        # scope module absent -> today's behavior
    if not results:
        return RecallResult("empty", budget=cfg.budget)

    items = []
    for r in results:
        pointer = r["file"]
        title = (r.get("title") or pointer).strip()
        body = runner.run(["qmd", "get", pointer, "--no-line-numbers"])
        if not body:
            continue
        body = body.strip()
        if len(body) > cfg.max_body:
            body = body[:cfg.max_body].rstrip() + "\n…(truncated)"
        gate = "pass"
        if scope and cur_slug:
            try:
                if scope.classify(pointer, cur_slug) == "current":
                    gate = "repo"        # the K+1 current-repo addition
            except Exception:
                pass
        items.append(RecallItem(pointer, title, body, r.get("score"),
                                source="qmd", gate=gate))

    if not items:
        return RecallResult("empty", budget=cfg.budget)

    # Best-effort staleness signal: if status reports the collection has pending
    # embeddings, recall may be incomplete. Never fatal.
    pending = False
    status = runner.run(["qmd", "status"])
    if status:
        m = re.search(r"Pending:\s*([\d,]+)\s+need embedding", status)
        if m and m.group(1).replace(",", "") not in ("0", ""):
            pending = True

    # qmd answered successfully — clear any failure stamp so a recovered qmd resets
    # the streak and doesn't sit under a lingering cooldown (self-heal).
    health.clear()
    return RecallResult("ok", items, source="qmd", pending_embeddings=pending,
                        budget=cfg.budget)


# --------------------------------------------------------------- local fallback
def local_index_store():
    """The store the local fallback reads, derived exactly as the rest of the
    plugin derives it. Empty string if the local index module is unavailable, so a
    caller can fall back without importing it themselves."""
    try:
        if HERE not in sys.path:
            sys.path.insert(0, HERE)
        import local_index
        return local_index.default_store()
    except Exception:
        return ""


def _local_title(path, relpath):
    """Display name for a body read off disk: its frontmatter `name:`, else the
    filename stem. Only the frontmatter block is scanned, so a `name:` appearing
    in prose further down can't rename a memory."""
    stem = os.path.basename(relpath)
    if stem.endswith(".md"):
        stem = stem[:-3]
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            first = fh.readline()
            if first.strip() == "---":
                for line in fh:
                    if line.strip() == "---":
                        break
                    if line.startswith("name:"):
                        val = line.split(":", 1)[1].strip()
                        if val:
                            return val
    except OSError:
        pass
    return stem


def local_fallback(query, config=None, cwd=None, store_dir=None, **kw):
    """The qmd-free fail-over (plan U4): rank `query` with the LOCAL BM25 index and
    return bodies read straight off disk. Called when qmd is confirmed wedged — a
    failed probe or an armed cooldown — so session-start recall degrades to a
    weaker layer instead of degrading to silence.

    The gate is `local_index`'s own: COVERAGE of the query's discriminating
    vocabulary (`MEMORY_LOCAL_MIN_COVERAGE`), with a thin top1/top2 margin
    returning BOTH candidates rather than rejecting either. The qmd-side floors on
    `Config` are DELIBERATELY not passed down — they are vector-score thresholds and
    are arithmetically inert on BM25 scores (KTD12), so honoring them here would
    silently filter nothing while looking like a gate.

    Returns a RecallResult with `source="local-fallback"` and status:
      ok | below-gate | empty | no-query | unavailable (module missing/broken)
    Fail-open throughout: a caller that gets `unavailable` simply injects nothing.
    """
    cfg = config or Config(**kw)
    query = (query or "").strip()
    if not query:
        return RecallResult("no-query", source="local-fallback")
    try:
        if HERE not in sys.path:
            sys.path.insert(0, HERE)
        import local_index
    except Exception:
        return RecallResult("unavailable", source="local-fallback",
                            reason="local index module unavailable")
    try:
        store = store_dir or cfg.memory_dir or local_index.default_store()
        res = local_index.search(store, query[:400], cwd=cwd, k=cfg.k)
    except Exception:
        return RecallResult("unavailable", source="local-fallback",
                            reason="local index raised")

    if res.status != local_index.HITS:
        status = "below-gate" if res.status == local_index.BELOW_GATE else "empty"
        return RecallResult(status, source="local-fallback", reason=res.reason)

    cur_slug = None
    if scope:
        try:
            cur_slug = scope.resolve_repo_slug(cwd or os.getcwd())
        except Exception:
            cur_slug = None

    items = []
    for hit in res.hits:
        rel = hit.get("file")
        if not rel:
            continue
        path = os.path.join(store, rel)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                body = fh.read().strip()
        except OSError:
            continue
        if not body:
            continue
        if len(body) > cfg.max_body:
            body = body[:cfg.max_body].rstrip() + "\n…(truncated)"
        gate = "pass"
        if scope and cur_slug:
            try:
                if scope.classify(rel, cur_slug) == "current":
                    gate = "repo"
            except Exception:
                pass
        items.append(RecallItem(rel, _local_title(path, rel), body,
                                hit.get("score"), source="local-fallback",
                                gate=gate))
    if not items:
        return RecallResult("empty", source="local-fallback",
                            reason="no body was readable")
    return RecallResult("ok", items, source="local-fallback", reason=res.reason)


def _main(argv):
    """Small CLI for tests and for deriving the shared paths from any language."""
    if "--stamp-path" in argv:
        print(cooldown_stamp_path())
        return 0
    if "--state-dir" in argv:
        print(state_dir())
        return 0
    q = " ".join(a for a in argv if not a.startswith("-"))
    res = recall(q)
    print(json.dumps(res.as_dict()))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
