# Driving the six surfaces — first real invocation

Date: 2026-08-07. Plugin loaded via a local dev marketplace (`gateway-surfaces-dev`,
scope local) off this worktree at `5c9f0d0`, then `/reload-plugins`. Gateway up at
`http://127.0.0.1:4000/anthropic`, config `~/gateway-0.1.1/gateway.yaml`, 18 aliases.

The handoff opened with: **none of the six surfaces has ever been invoked.** That
is now **four of six** — and the two that remain unreached are the interesting
part (F1).

## Result

| surface | reached | result |
|---|---|---|
| command `lens` | yes | body returned and followed |
| command `launch` | yes | body returned and followed |
| command `status` | yes | body returned and followed |
| skill `lens` | **no** | `Skill(gateway:lens)` returned the *command* body |
| skill `launch` | **no** | not reached by name |
| skill `status` | **no** | `Skill(gateway:status)` returned the *command* body |

The three `lib/*.sh` scripts all ran clean — the same way the previous session
exercised them, by absolute path:

- `gatewayctl.sh status` → exit 0, gateway up, 18 aliases
- `lens.sh --alias gpt` → exit 0, answer returned, `content_trust` /
  `content_notice` present as designed
- `launch.sh --alias gpt --cwd /tmp` → exit 0, session `f29f7a40…`

`launch` verified **by effect**, not just by handle: the transcript at
`~/.claude/projects/-private-tmp/f29f7a40-….jsonl` is 70 KB / 11 lines and carries
the completed seed turn — user `"Say hello and nothing else."`, assistant
`"Hello"`. The session really was materialized on the `gpt` alias.

KD3 holds by inspection: the printed `attach_command` carries an `awk` that
re-reads the token from `gateway.yaml` at attach time. No token value in the
handle.

## F1 — Invoking `gateway:<name>` resolves to the COMMAND, not the skill

`Skill(gateway:status)` and `Skill(gateway:lens)` both returned the body of
`commands/<name>.md` — the thin wrapper ending in `$ARGUMENTS`, with
`${CLAUDE_PLUGIN_ROOT}` expanded. The corresponding `skills/<name>/SKILL.md` never
appeared in either invocation.

So the command redirect ("Use the Skill tool to invoke: `gateway:lens`") is a
redirect to itself by name. The skill bodies — 61-86 lines each, ~140 always-on
tokens apiece — were not reached by name in any of the three invocations.

This is handoff Q2 (command/skill name collision) with evidence: the collision is
not merely confusing, it appears to make one of the two surfaces unreachable by
its own name.

Hedge on mechanism: what is observed is that **name resolution went to the command
in all three invocations**. That is not proof the skill can never load — autonomous
model-triggered selection (the description matching, rather than an explicit
`gateway:lens` call) is a separate path and was not tested. But the explicit path a
command body itself instructs a caller to take does not reach the skill.

## F2 — `lens.sh` is mode 644; the other two entry points are 755

```
100644 plugins/gateway/lib/lens.sh
100755 plugins/gateway/lib/gatewayctl.sh
100755 plugins/gateway/lib/launch.sh
```

Committed that way, not a local artifact. Every documented invocation uses
`bash "${CLAUDE_PLUGIN_ROOT}/lib/lens.sh"`, so nothing is broken. But the natural
direct call fails as a **shell** error:

```
(eval):2: permission denied: …/lib/lens.sh
```

That's outside the plugin's exit enum entirely — a consumer that branches on the
frozen codes (0,2,3,4,5,6,7) sees a shell failure it has no case for. Sourced libs
(`common.sh`, `sanitize.sh`) are correctly 644; the inconsistency is only among the
three executables, and it lands on the headline agent surface.

## F3 — `--help` exits 2 and writes to both streams

Confirms Q3, with a detail the handoff didn't record: usage goes to **stdout
(106 bytes) *and* stderr**, and the exit is 2 for both `--help` and a genuine
usage error. `launch.sh --help` makes the ambiguity explicit — it emits
`{"error":"usage","detail":"help requested","exit_code":2}`, so "I asked for help"
and "you called me wrong" are the same exit code and differ only in a JSON field.
Neither script has `--describe` (`grep -c -- '--describe' lens.sh` → 0).

## F4 — The drift block reports 9 false alarms

`status` reports `missing_from_table` for nine aliases:

```
claude-default claude-glm claude-gpt claude-gpt-luna claude-gpt-sol
claude-gpt-sol-pro claude-gpt-terra claude-k3 claude-kimi
```

Every one is a `claude-`-prefixed twin of an alias that *is* in the table
(`claude-gpt`/`gpt`, `claude-kimi`/`kimi`, …). `missing_window` and `model_drift`
are both empty — the only populated field in the block that exists to flag real
problems is entirely noise. Handoff Q7 (what does `/gateway:status` show a human),
and concrete enough to fix rather than brainstorm.

## F5 — Loading the plugin is not a `/reload-plugins` away, and the obvious
marketplace name collides

`plugins/gateway/` exists only on the unmerged `feature/gateway-plugin` (PR #30);
the registered `shrimpshack` marketplace resolves to GitHub **main**, which has
none of it. A local dev marketplace is required.

Naming it `gateway-dev` — the obvious choice — collided with a concurrent session
in the `gateway-plugin` worktree that picked the same name and silently repointed
the global registration at its own scratchpad. This session's skills then loaded
the *other* worktree's files, with no error. Name the marketplace after the
worktree.

Also verified: `${CLAUDE_PLUGIN_ROOT}` resolves to the marketplace's
`installLocation`, not the version-pinned cache copy — so with a symlinked
directory-source marketplace, **`lib/*.sh` edits are live**: the scripts are read
at invocation time, straight through the symlink.

The markdown surfaces are **not** live. `SKILL.md` and `commands/*.md` are the
~561 always-on tokens loaded at session start; editing them needs at least a
`/reload-plugins`. Since this workstream's job is editing exactly that layer, plan
for a reload after every surface edit.

## Not yet driven

The three commands as *typed slash commands* (`/gateway:lens` etc.). Their bodies
were exercised (F1), but a human typing the slash command is a path only Shawn can
run.
