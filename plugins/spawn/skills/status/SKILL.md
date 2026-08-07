---
name: status
description: >
  Invoked by name only (via the Skill tool, or by a person naming this skill) — do NOT
  trigger this skill from conversational phrasing on your own; `/spawn:report` is the
  conversational front door and carries its own instructions.
  Report the local Superagent Gateway's state — running or not, the aliases it is
  actually serving, where it was resolved from, and any drift between the plugin's
  context-window table and the gateway's own config. Also starts, stops and restarts
  it. Use when someone asks whether the gateway is up, which models are available,
  what aliases exist, or wants the gateway started or bounced.
allowed-tools: Bash, Read
---

# Gateway status and control

One script owns liveness, start/stop, and reporting. Liveness is a real probe of the gateway's model-list endpoint (KTD3) — the pidfile is never consulted for it, which is why a stale pidfile over a serving gateway still reports "up", and a dead gateway whose pid got recycled still reports "down".

## Workflow

1. Run the script:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/lib/spawnctl.sh" status
   ```

   Always through `${CLAUDE_PLUGIN_ROOT}/lib/spawnctl.sh`, never by PATH lookup. (`gw` on your PATH is an unrelated binary; this plugin deliberately leaves it alone and both surfaces share the same pid and log files, so neither double-starts against the other.)

   The other verbs, same script, same contract:

   - `start` — start it if it is not already up. Idempotent under concurrent callers: a fan-out of five against a down gateway yields exactly one gateway process.
   - `stop` — stop the gateway we started.
   - `restart` — stop, tolerating "not running", then start.
   - `ensure [alias]` — the preflight `lens` and `launch` call. You rarely run it by hand; both of those call it for you.

2. Read the exit code. KTD2 owns the enum — what each code means *here*:

   - **Exit 0 (ok):** the gateway is up and answered the probe. For `stop`, it also covers "was not running" and "the pidfile was stale" — both are successful outcomes.
   - **Exit 2 (usage/refusal):** an unknown or missing verb. On `stop` it also means the script refused to signal: either a gateway is serving but the pidfile is empty (it will not guess which process to kill), or the pidfile's pid belongs to a live but unrelated process — a recycled pid, reported with its actual argv rather than killed.
   - **Exit 3 (gateway unreachable):** for `status`, this is **a normal answer, not an error.** It means the gateway is down. The JSON is still complete, with `running: false`, `error` carrying the enum value you branch on and `detail` naming what the probe saw — report it and stop; do not retry. For `start` and `restart` it means the start did not produce a serving gateway.
   - **Exit 4 (alias unknown):** only from `ensure <alias>` — the gateway is up but does not serve that alias. The JSON carries `served_aliases`.
   - **Exit 7 (token rejected):** the gateway is up and answering but refused the plugin's token. This is deliberately not exit 3: the process is running, so treating it as "down" would send a start into a collision with the live gateway. The fix is the token in the resolved config, not a restart.

   Exit 5 and exit 6 belong to the lens; this script does not produce them.

3. Report the state from the JSON:

   - **`running`** — the probe's answer. This is the question status exists to settle.
   - **`served_aliases`** — the aliases the gateway is serving *right now*. This is authoritative; the plugin's own table is not. When someone asks "what models can I use", this is the list.
   - **`base_url`** — the endpoint that was probed.
   - **`install_dir`** / **`binary`** / **`config`** — where the gateway was resolved from at runtime, the executable found there, and the config file the token was read from.
   - **`install_dir_error`** — non-null when the install directory could not be resolved. Status still reports liveness anyway; an unresolvable install dir must not stop the one question status is for.
   - **`pid`** and **`pid_verified`** — the pidfile's pid, and whether a live process with that pid actually has the gateway binary in its argv. `pid_verified: false` alongside `running: true` means something else is serving, or the pidfile is stale — worth saying out loud, but it does not change the liveness answer.
   - **`log`** / **`pidfile`** — the runtime state paths. The log is append-only; it is never truncated.

4. Report drift if there is any. `models` lists the plugin's per-alias context-window table (`alias`, `context_window`, `source`, `model`, `chain`), and `drift` has four classes (KTD7):

   - **`missing_from_table`** — the gateway serves an alias the plugin has no window for, *and* the gateway says it resolves to something no table entry already covers. A session on it launches without a declared window and draws Claude Code's unrecognized-model warning.
   - **`unknown_resolution`** — the gateway serves an alias the table does not list and says nothing about what it resolves to: no entry in the config's `models:` block, and no display name matching one the table already carries. It is not called drift, because it may be a second name for something already listed; it is not hidden either, because it may be a new model. Say plainly that its resolution could not be determined.
   - **`missing_window`** — a table entry with no window recorded.
   - **`model_drift`** — an alias whose upstream model string in the gateway's config no longer matches the one recorded when the window was written, with `recorded` and `current` both shown. This is the one that matters most: the alias keeps its name, so a repointed model would otherwise drift silently, and the recorded window may no longer be the right number.

   Sameness is decided from what the gateway says an alias resolves to — the model string in its config, or the display name it serves — never from one name being a prefix of another. Two aliases resolving to the same model are one model served twice, not drift; a new model served under a prefixed name is real drift and is still reported.

   Empty arrays in all four means no drift — say so plainly rather than listing them.

Anything the gateway's config supplies as display text is sanitized before it is printed. Do not re-render raw config-derived text through another sink.
