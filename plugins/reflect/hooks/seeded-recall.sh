#!/usr/bin/env bash
#
# seeded-recall.sh — UserPromptSubmit hook. Once per session, on the first
# prompt, inject the most relevant memory bodies as added context.
#
# This file is now a thin caller: read the hook payload from stdin JSON
# (.prompt, .session_id), apply the once-per-session guard, ask the SHARED
# retrieval engine (scripts/scoped-memory/retrieval.py) for bodies, and format
# them for injection. All retrieval logic — qmd process runner, wall budget,
# process-group kill, cooldown read/stamp/clear, result parsing, floors, body
# fetch — lives in that module so the recall CLI runs the same engine instead of
# a drifting copy (plan U9 / KTD8). Read its docstring for the contracts,
# including the cooldown-stamp location and the budget-asymmetry rule.
#
# Fail-safe: any missing qmd, error, or timeout exits 0 with no output — recall
# degrades to the manual pointer-index fallback, the prompt is never blocked.
#
# Config (env, all optional) — parsed by retrieval.Config:
#   SEEDED_RECALL_COLLECTION      (default claude-memory)
#   SEEDED_RECALL_K               (default 3)        top-K bodies to inject
#   SEEDED_RECALL_TIMEOUT         (default 6)        seconds, TOTAL wall budget across
#                                                    all qmd calls; above healthy
#                                                    vsearch latency, under the 8s hook
#                                                    ceiling (headroom is the group-kill)
#   SEEDED_RECALL_MIN_SCORE       (default unset)    drop results below this score
#   SEEDED_RECALL_MAX_BODY        (default 1200)     chars per body, budget guard
#   SEEDED_RECALL_FLAG_DIR        (default ~/.claude/projects/<slug>/recall-state)
#   SEEDED_RECALL_COOLDOWN        (default 600)      seconds an armed failure stamp
#                                                    suppresses recall (cross-session)
#   SEEDED_RECALL_FAIL_THRESHOLD  (default 2)        consecutive failures before the
#                                                    cooldown arms (transient tolerance)
#   SEEDED_RECALL_FORCE=1         bypass the once-per-session guard AND the cooldown (tests)

INPUT="$(cat)"
export CLAUDE_HOOK_INPUT="$INPUT"
export SCOPED_MEMORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts/scoped-memory" 2>/dev/null && pwd)"

exec python3 - <<'PY'
import json, os, sys

def out_nothing():
    sys.exit(0)

# Import the shared engine. If it is missing or broken, recall degrades to the
# manual pointer-index fallback — the prompt is never blocked.
try:
    smd = os.environ.get("SCOPED_MEMORY_DIR")
    if not smd or not os.path.isdir(smd):
        out_nothing()
    sys.path.insert(0, smd)
    import retrieval
except Exception:
    out_nothing()

try:
    payload = json.loads(os.environ.get("CLAUDE_HOOK_INPUT", "") or "{}")
except Exception:
    out_nothing()

prompt = (payload.get("prompt") or "").strip()
session_id = (payload.get("session_id") or "").strip()
if not prompt:
    out_nothing()

cfg = retrieval.Config(source="seeded")

# Once-per-session guard (keyed on session id). The flag is checked here but
# WRITTEN only after we successfully build output (below) — so a cold/timed-out/
# empty first prompt does not disable recall for the rest of the session; it
# simply retries on the next prompt.
flag = None
if not cfg.force:
    flag = retrieval.session_flag_path(session_id, cfg.flag_dir)
    if os.path.exists(flag):
        out_nothing()              # already injected this session

try:
    res = retrieval.recall(prompt, config=cfg)
except Exception:
    out_nothing()
if res.status != "ok" or not res.items:
    out_nothing()

# Neutralize a literal closing tag in body/title so a memory's content can't break
# out of the <recalled-memories> wrapper it's injected into (zero-width space after
# '<' breaks the literal tag while staying visually identical).
def _safe(s):
    return s.replace("</recalled-memories>", "<​/recalled-memories>")

blocks = [f"### {_safe(i.title)}\n{_safe(i.body)}" for i in res.items]

stale_note = ""
if res.pending_embeddings:
    stale_note = ("> recall may be incomplete — the memory index has pending "
                  "embeddings (run `qmd embed -c %s`)\n\n" % cfg.collection)

# We have output to inject — NOW mark the session done so we don't re-fire.
if flag is not None:
    try:
        os.makedirs(os.path.dirname(flag), exist_ok=True)
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
