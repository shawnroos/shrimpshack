#!/usr/bin/env bash
#
# seeded-recall.sh — UserPromptSubmit hook. Once per session, on the first
# prompt, inject the most relevant memory bodies as added context.
#
# Reads the hook payload from stdin JSON (.prompt, .session_id). Performs a FAST
# lexical search (`qmd search`, BM25, ~0.25s — never `qmd query`, which loads
# three models and stalls ~18-31s on this synchronous prompt path), under a hard
# timeout. Bounds results in-script (top-K + optional score floor) because qmd
# silently swallows unknown flags, so `-n`/`--min-score` are not trusted. Fetches
# each body with `qmd get` and emits them on stdout (exit 0 → injected context).
#
# Fail-safe: any missing qmd, error, or timeout exits 0 with no output — recall
# degrades to the manual pointer-index fallback, the prompt is never blocked.
#
# Config (env, all optional):
#   SEEDED_RECALL_COLLECTION   (default claude-memory)
#   SEEDED_RECALL_K            (default 3)        top-K bodies to inject
#   SEEDED_RECALL_TIMEOUT      (default 6)        seconds, TOTAL wall budget across
#                                                 all qmd calls (keep below the
#                                                 settings-level hook timeout, 8s)
#   SEEDED_RECALL_MIN_SCORE    (default unset)    drop results below this score
#   SEEDED_RECALL_MAX_BODY     (default 1200)     chars per body, budget guard
#   SEEDED_RECALL_FLAG_DIR     (default $TMPDIR/claude-seeded-recall)
#   SEEDED_RECALL_FORCE=1      bypass the once-per-session guard (tests)

INPUT="$(cat)"
export CLAUDE_HOOK_INPUT="$INPUT"

exec python3 - <<'PY'
import os, sys, json, subprocess, hashlib, re, time

def out_nothing():
    sys.exit(0)

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

deadline = time.monotonic() + budget

def run(args):
    """Run a qmd command, bounded by the REMAINING wall budget. Returns stdout, or
    None on any failure (missing binary, non-zero exit, timeout, budget spent)."""
    remaining = deadline - time.monotonic()
    if remaining <= 0.05:
        return None
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=remaining)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout

# Seed the query with the prompt plus the current branch.
branch = ""
b = run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
if b:
    branch = b.strip()
query = prompt if not branch else f"{prompt} {branch}"
query = query[:400]

# `--` ends flag parsing so a leading-dash prompt can't inject a flag (e.g. a
# second -c that redirects the collection).
raw = run(["qmd", "search", "-c", collection, "--format", "json", "--", query])
if not raw:
    out_nothing()
try:
    results = json.loads(raw)
except Exception:
    out_nothing()
if not isinstance(results, list) or not results:
    out_nothing()

# In-script bounding: optional score floor, then top-K (do NOT trust qmd flags).
if min_score is not None:
    results = [r for r in results if isinstance(r, dict)
               and isinstance(r.get("score"), (int, float)) and r["score"] >= min_score]
results = [r for r in results if isinstance(r, dict) and r.get("file")][:K]
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

print("<recalled-memories source=\"seeded-recall\">")
if stale_note:
    print(stale_note, end="")
print("\n\n---\n\n".join(blocks))
print("</recalled-memories>")
sys.exit(0)
PY
