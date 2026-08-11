---
description: Start a resumable Claude Code session on another model and print an attach handle you can use whenever you like. Nothing opens; the first turn runs headlessly.
argument-hint: "prose — name a model (and optionally a tier), then give the opening prompt"
---

**Create and seed a resumable Claude Code session** on a named gateway alias and hand back an attach handle. Nothing opens a terminal: the first turn runs headlessly, the session lands on disk, and you get a paste-ready attach command.

Everything after the command is prose. Derive the model family and optional tier from it and invoke the script with exactly one resolved `--alias`; the rest of the prose is the seed prompt.

1. What families and tiers exist is **declared, not guessed**:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/lib/launch.sh" --describe
   ```

   Read its `families` — each family's default alias and its tier-name-to-alias map, tier names spelled as prose spells them (a hyphenated one included) — and `no_family_alias`, what prose naming no family resolves to. `chain_policy` is also declared there; this surface is allowed a chain alias. The other two scripts answer from the same table. If the prose names a family or tier that block does not list, **fail loudly**: say so and name the served aliases from `families`, rather than silently resolving to the default.

2. Run the script, seed prompt on stdin:

   ```bash
   printf '%s' "$SEED" | bash "${CLAUDE_PLUGIN_ROOT}/lib/launch.sh" --alias <resolved-alias>
   ```

   `--prompt-file <path>` reads the seed from a file instead. `--cwd <dir>` pins the session's project directory; it defaults to the current directory and is resolved to its physical path. The seed must be non-empty — a session seeded with nothing is not worth a handle.

3. Branch on the exit code:

   - **0** — the session exists on disk and the handle is real. Go to step 4.
   - **2** — usage or refusal: no alias, an alias failing the grammar, an empty or missing seed, an unreadable `--prompt-file`, a `--cwd` that is not a directory.
   - **3** — the gateway is down and could not be started.
   - **4** — the gateway does not serve that alias; `preflight.served_aliases` names what does.
   - **5** — it got past preflight and then failed. `error` is `seed_failed` (the headless run exited non-zero or reported `is_error`; no session was made), `no_session_id` (the run succeeded but returned no session id), or `transcript_missing` (an id came back with no transcript on disk). In all three no handle is printed, deliberately — a handle to a session that does not exist is worse than a failure.
   - **6** — the seed outlived `SPAWN_LAUNCH_TIMEOUT` (default 600s). The child was TERMed, KILLed and reaped; nothing is still running and no session exists. Seeds are full agent turns — raise the knob rather than retrying blind.
   - **7** — the gateway refused the plugin's token. Restarting is the wrong move; look at the token in the resolved config.

4. On exit 0, present the handle plainly: `attach_command` exactly as given, `session_id`, `transcript_path`, `cwd`, `base_url`, and `context_window` (null means the alias has no declared window, so the session falls back to Claude Code's default and will draw an unrecognized-model warning — it still launches).

   **The gateway token appears in none of those fields.** The attach command carries it by reference and re-reads it from the gateway config at attach time. Do not resolve it into a literal, and do not print it if you happen to hold it.

5. Say what a gateway-pointed session is, so it reads as expected rather than broken. Lead with the trust posture: unlike a tool-less turn, an attached session runs Claude Code's **full agent loop under the user's own permissions in the pinned directory, with a third-party model choosing the actions.** That is the feature — but the judgement in that session is a third-party model's judgement holding your permissions.

   The rest are expected, not breakage: claude.ai MCP connectors do not load (the gateway token takes precedence over the claude.ai login), the advisor tool is disabled (gateway aliases have no advisor rank), and Claude Code warns about an unrecognized model when no context window is declared. Two caveats on the attach command itself, both inherent to carrying the token by reference: it is bash-specific, and it assumes the config path captured at launch still exists at attach time.

$ARGUMENTS
