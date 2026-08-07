---
description: Is the local Superagent Gateway up, and what is it serving? Reports liveness, the served aliases, where it was resolved from, and any genuine drift.
argument-hint: "(no arguments; add \"start\", \"stop\" or \"restart\" to act on the gateway instead of just reporting)"
---

**Answer whether the gateway is up and what it serves.** Liveness is a real probe of the gateway's model-list endpoint — the pidfile is never consulted for it, so a stale pidfile over a serving gateway still reports up, and a dead gateway whose pid got recycled still reports down.

1. Run the script:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/lib/spawnctl.sh" status
   ```

   If the prose asked to act rather than report, the same script owns `start` (idempotent — five concurrent callers against a down gateway yield exactly one process), `stop`, and `restart`. Same contract, same JSON.

2. Branch on the exit code:

   - **0** — up, and it answered the probe. For `stop`, this also covers "was not running" and "the pidfile was stale": both are successful outcomes.
   - **2** — an unknown or missing verb. On `stop` it also means the script refused to signal: a gateway is serving but the pidfile is empty, or the pidfile's pid belongs to a live unrelated process (a recycled pid, reported with its argv rather than killed).
   - **3** — for `status`, this is **a normal answer, not an error**: the gateway is down. The JSON is complete, with `running: false` and `error` naming what the probe saw. Report it and stop; do not retry. For `start` and `restart` it means the start did not produce a serving gateway.
   - **7** — the gateway is up and answering but refused the plugin's token. Deliberately not exit 3: the process is running, so treating it as down would send a start into a collision with the live gateway. The fix is the token in the resolved config, not a restart.

3. Answer in prose a human can read, rendered from the JSON — and keep the JSON intact underneath rather than replacing it. Report `running` first, since that is the question. Then `served_aliases`, which is authoritative for "what models can I use" — the plugin's own table is not. Then where it came from: `base_url`, `install_dir`, `binary`, `config`. `install_dir_error` non-null means the install directory could not be resolved; liveness is still reported, because an unresolvable install dir must not block the one question this answers. `pid_verified: false` alongside `running: true` means something else is serving or the pidfile is stale — worth saying out loud, but it does not change the liveness answer.

4. Report drift only when it is genuine, and say so plainly when there is none. `drift` has three classes: `missing_from_table` (an alias served with no window recorded — a session on it launches without a declared window), `missing_window` (a table entry with no window), and `model_drift` (an alias whose upstream model string no longer matches the one recorded when its window was written, with `recorded` and `current` both shown — the one that matters most, because the alias keeps its name while the recorded window may no longer be right).

   Whether two aliases are the same thing is decided by what the gateway says they resolve to, never by one name being a prefix of another: a new model served under a prefixed name is real drift and must still be reported. Empty arrays in all three classes means no drift — say that in one line instead of listing three empty lists. A report that cries wolf gets ignored.

   Anything the gateway's config supplies as display text is already sanitized before it is printed. Do not re-render raw config-derived text through another sink.

$ARGUMENTS
