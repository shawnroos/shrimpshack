---
name: launch
description: >
  Invoked by name only (via the Skill tool, or by a person naming this skill) — do NOT
  trigger this skill from conversational phrasing on your own; `/spawn:session` is the
  conversational front door and carries its own instructions.
  Materialize a Claude Code session on a model the local Superagent Gateway serves,
  seeded with an opening prompt, and print a resume handle. Use when someone wants to
  work *with* a different model rather than just ask it something — "start a session
  on GPT", "give me a Kimi session with this context", "launch on glm". The first turn
  runs headlessly; nothing opens a terminal, and the handle is attached on demand.
allowed-tools: Bash, Read
user-invocable: false
---

# Interactive launch

The plugin never opens a terminal. It runs the seed prompt headlessly through `claude`, which materializes the session on disk, then prints a handle Shawn attaches with on his own terms (F2, R8, R9).

## Workflow

1. Run the script with the seed prompt on stdin:

   ```bash
   printf '%s' "$SEED" | bash "${CLAUDE_PLUGIN_ROOT}/lib/launch.sh" --alias gpt-sol
   ```

   Or from a file, and pinned to a project directory:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/lib/launch.sh" --alias kimi --prompt-file ./seed.md --cwd ~/projects/thing
   ```

   Always through `${CLAUDE_PLUGIN_ROOT}/lib/launch.sh`, never by PATH lookup. (A `gw` on your PATH is the operator's own tool — this plugin does not write or read it, and it has no launch verb. Reach for the script.)

2. Flags — this is the whole set:

   - `--alias <name>` — **required.** Must be served by the gateway; grammar `[A-Za-z0-9._-]+`, checked before any network call and before the alias is ever put into the attach command. `/spawn:report` lists what is served.
   - `--prompt-file <path>` — read the seed prompt from a file instead of stdin.
   - `--cwd <dir>` — the session's project directory. Defaults to the current directory. It is resolved to its physical path, so the transcript path in the handle is reproducible from anywhere.

   The seed prompt must be non-empty: a session seeded with nothing is not worth a handle.

3. Read the exit code. KTD2 owns the enum — what each code means *here*:

   - **Exit 0 (ok):** the session exists on disk and the handle is real. Go to step 4.
   - **Exit 2 (usage/refusal):** bad arguments — no `--alias`, an alias that failed the grammar, an empty or missing seed prompt, an unreadable `--prompt-file`, a `--cwd` that is not a directory.
   - **Exit 3 (gateway unreachable):** the gateway was down and could not be started. Propagated from the preflight, not decided here.
   - **Exit 4 (alias unknown):** the gateway does not serve that alias. The code is propagated from the preflight; the JSON is in launch's own shape (`error` is `alias_unknown`, the handle fields null), with the preflight's full object — including `served_aliases` — under `preflight`. Every preflight failure (exit 2/3/4/7) carries that key.
   - **Exit 5 (upstream provider error):** the launch got past preflight and then failed. Branch on `error`:
     - `seed_failed` — the `claude` run exited non-zero, or reported `is_error`. No session was materialized.
     - `no_session_id` — the run succeeded but its JSON carried no session id; the CLI's output shape has drifted from what the script reads.
     - `transcript_missing` — a session id came back but no transcript is on disk at the derived path.
     In all three the script refuses to print a handle. That is deliberate: a handle to a session that does not exist is worse than a failure, because you would attach to nothing.
   - **Exit 6 (deadline exceeded):** the seed run outlived `SPAWN_LAUNCH_TIMEOUT` (default 600 seconds). The child was TERMed, KILLed if it ignored that, and reaped — nothing is still running, and no session handle exists. Seeds are full agent turns, so raise the knob for long seeds rather than retrying.
   - **Exit 7 (token rejected):** the gateway is up but refused the plugin's token. Propagated from the preflight; restarting the gateway is the wrong move.

4. On exit 0, present the handle plainly. The fields:

   - **`attach_command`** — a ready-to-paste command that re-establishes the gateway environment and resumes the session on the same alias. Show it as-is.
   - **`session_id`** — the session it resumes.
   - **`transcript_path`** — the session's transcript on disk, verified to exist before the handle was printed.
   - **`cwd`** — the pinned project directory. The attach command `cd`s there itself, so it works from anywhere.
   - **`base_url`** — the gateway endpoint the session talks to.
   - **`context_window`** — the window declared for this alias, or null if the alias is not in the plugin's table. An unlisted alias still launches; the drift is a stderr warning, and the session falls back to Claude Code's default window. The table is metadata, not an allowlist — the gateway's served list is the allowlist.

   **The gateway token appears in none of these** (KTD6). The attach command carries the token *by reference*: it re-reads it from the gateway config at attach time. Do not "helpfully" resolve it into a literal, and do not print it if you happen to hold it.

## What a gateway-pointed session does not have

Say this when you hand over the handle. And lead with the one difference that changes the **trust posture**, not just the feature set: unlike the lens — a plain completion with no tools, which can only *answer* — an attached launch session runs Claude Code's **full agent loop**, under the user's normal permissions, in the pinned project directory, with a **third-party model** deciding the actions. It can read and edit files and run commands wherever it was pinned. That is the feature, not a bug — but hand it over the way KTD5 hands over lens text: this session's judgement is a third-party model's judgement, operating with your permissions.

The rest are expected, not breakage — verified live on 2026-08-06:

- **claude.ai MCP connectors do not load.** The gateway auth token takes precedence over the claude.ai login, so the connectors that login would carry are not there.
- **The advisor tool is disabled.** Gateway aliases have no advisor rank in the model catalog.
- **Claude Code warns that the model is unrecognized** unless a context window is declared — which is exactly what `context_window` above is for. An alias with no table entry launches without one and will draw that warning.

Two caveats on the attach command itself, both inherent to carrying the token by reference (KTD6) rather than bugs:

- It is **bash-specific.** The `${VAR}` indirection it uses to expand a config-referenced token is a bash feature; pasting it into a non-bash shell will not work.
- It assumes **the config path captured at launch still exists at attach time.** If the gateway config moves or is rewritten between launch and attach, the reference has nothing to resolve.
