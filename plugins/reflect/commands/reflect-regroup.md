---
description: A human-invoked stop. Drop the in-flight action, work out from your own recent turns what to search memory for, retrieve, and report the corrected course forward. Takes no topic argument.
---

Someone just interrupted you because you are doing something wrong and you never consulted memory.

**This command takes no argument, and that is the mechanism, not an omission.** The person invoking it can see you going wrong but cannot name which memory covers it — that is exactly why they typed a command with nothing after it. Requiring a topic would push the hard half of the work back onto the person interrupting. You derive the query yourself, from what you have been doing.

**Not `/memories`.** `/memories <topic>` takes an argument, is deliberate study of a subject you or the user chose, and stops nothing. `/reflect-regroup` (the plan calls it `/reflect regroup`) takes no argument, is human-invoked mid-task, and its first instruction is to stop. See `commands/memories.md`.

**Not an enforcement mechanism.** `/reflect-regroup` serves the agent that never looked. It is not a fix for the agent that had a memory, stated its lesson, and violated it anyway — that is a model behavior, decided permanently out of scope (plan Open Question 1). Do not read this command, or later extend it, as a compliance check.

---

## 1. Stop

Abandon the in-flight action. Do not finish the edit. Do not run the queued command. Do not "just complete this one step first" — the interrupt is the point, and completing the action defeats it.

## 2. Derive the situation from your recent context — and say what you derived

Read back over your last several turns and extract **3–5 searchable situations**. Look for:

- commands you just ran, and the tools they used
- the error or symptom you are chasing
- a tool whose output was thin, empty, or surprising
- a decision you just made, or an approach you just committed to
- an external system you just touched (a repo, a CI, a deploy target, a browser, a store)

Write them out before searching. **Naming them makes a bad derivation visible to the human instead of producing a mysteriously empty result** — if you derived the wrong situation, they can see that in one line and correct you, rather than watching you report "nothing found."

This extraction is a different act from search, and it is the one that failed in the first place: noticing that what you are doing *is* a situation a memory might cover.

## 3. Retrieve wide

Run each derived situation through the recall CLI in deliberate mode. A human explicitly asked, so a marginal hit costs one line you read and discard — much cheaper than the miss:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/scoped-memory/reflect_cli.py" recall --deliberate --cwd "$PWD" --query "$SITUATION"
```

`--deliberate` widens K and relaxes the local confidence gate. It does **not** bypass an armed qmd cooldown — if the status line says the cooldown is armed, that is the local index answering, and that is fine.

Read the **bodies**, not the titles. The status line at the end names which layer answered; if it says "no confident match," that is a real answer, not a failure.

Then read `MEMORY.md` and follow index pointers for cold memories whose one-line hook looks relevant to a derived situation but which the search did not surface — a memory the ranker missed still applies.

## 4. Report forward

Not a summary of what you read. **One line per change of course**, each naming the memory that caused it, plus one line for what is unchanged:

```
Grounding — 3 memories apply.
Changing course:
  • Not running the full build locally (feedback_no_local_ng_build_kills_machine)
    → verifying template errors via the PR build instead
  • Re-fetching before push (feedback_concurrent_sessions_same_feature_branch)
Unchanged: the fix itself.
```

A null result is a valid and useful outcome. State it plainly: *"Searched: wedged CI checks, e2e shard triage, force-push safety. Nothing on disk covers this — continuing as planned."*

## 5. Continue

Proceed on the corrected course **without waiting for confirmation**. The human just interrupted once; interrupting again is cheaper than a confirmation gate on every invocation.

## 6. Record honestly

For each memory that **actually changed your approach** — never for a memory you merely read — append one `applied` line:

```bash
MEMORY_NAME=feedback_example_memory python3 -c 'import os, sys
sys.path.insert(0, os.environ["CLAUDE_PLUGIN_ROOT"] + "/scripts/scoped-memory")
import telemetry
store = os.environ.get("REFLECT_MEMORY_DIR") or os.path.expanduser(
    "~/.claude/projects/-Users-shawnroos/memory")
telemetry.append_applied(os.path.join(store, "MEMORY_USE.log"),
                         os.environ["MEMORY_NAME"],
                         session_id=os.environ.get("CLAUDE_SESSION_ID"),
                         annotation="regroup")'
```

Pass the session id. A line written without one records `unknown`, and `unknown` refuses to join to anything — the record exists but is unmeasurable, so it cannot show whether `regroup` helped.

Only `applied` raises a memory's activation. Logging a memory you read but did not act on inflates it into surfacing itself more often — the loop the write-vs-apply split exists to prevent.

Where a memory clearly *should* have surfaced ambiently but carried no declared trigger, propose one: name the memory and the literal string or pattern that would have caught this situation. That feeds the trigger lifecycle; it is a proposal for the human, not an edit you make silently.
