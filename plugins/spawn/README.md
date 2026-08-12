# spawn

**Use a different AI model from inside Claude Code.**

Claude Code talks to Claude. This plugin lets it talk to GPT, Kimi, GLM, or
anything else — without leaving your session, and without changing how you work.

Everything runs on your Mac. Your prompt goes out to the model you asked for and
the answer comes back — nothing else about your work leaves the machine.

---

## Install

```
claude plugin install spawn@shrimpshack
```

Then, once:

```
/spawn:setup
```

Setup does the whole job: installs what it needs, asks for your OpenRouter key
and stores it in the macOS Keychain, wires up your shell, starts everything, and
then proves it works — it sends a real request to a real model,
and separately checks that a request with no credentials is *rejected*. It only
reports success if both are true.

You will not be prompted mid-run. If setup needs your permission for something —
replacing a file you wrote, adding a line to your shell config — it stops and
tells you exactly what to re-run.

**You need:** a Mac, and an [OpenRouter](https://openrouter.ai) account. That's
where the other models come from, and it's what your key pays for.

---

## What you can do

### Ask another model a question

```
/spawn:agent ask gpt whether this migration is reversible
/spawn:agent have kimi look at the diff in /tmp/changes.patch
```

You get an answer back, in one turn. Say it in plain English — it works out which
model you meant.

The model on the other end **cannot do anything**. It can't read your files, run
commands, or change your code. It reads what you sent and answers. That's the
whole interaction, and it's the point: it's a second opinion, not a second cook
in the kitchen.

Good for: a different vendor's read on a design, a review of a diff, a sanity
check on an approach.

### Work inside another model

```
/spawn:session start a glm session to explore the auth flow
```

This creates a real, resumable Claude Code session running on a different model.
Nothing opens on screen — the first turn runs quietly, the session is saved, and
you get a command you can paste in whenever you want to pick it up.

**Worth understanding before you use it:** that session has your normal
permissions in the folder you point it at, and a third-party model is deciding
what to do with them. That's the feature. It's also the reason to think about
which folder you point it at.

Good for: exploring a problem with a model that thinks differently, or working
somewhere you'd like a genuinely separate perspective.

### Check on things

```
/spawn:report
```

Tells you whether everything's working and which models are available. It finds
out by actually asking, not by reading a file that claims to know — so the answer
is true even if something crashed messily.

Add a word to act instead of look:

```
/spawn:report restart
```

## If you want to script it

Everything is a shell script that prints JSON, so you can pipe it to `jq` and
build on it.

The scripts live in the plugin's `lib/` directory. Inside Claude Code that is
`${CLAUDE_PLUGIN_ROOT}/lib`. From a plain shell, the tidiest way is to copy the
small launcher once, so you have a path that does not change when the plugin
upgrades:

```bash
mkdir -p ~/.claude/bin
cp ~/.claude/plugins/cache/shrimpshack/spawn/*/bin/spawn-lens ~/.claude/bin/
```

Then ask a model anything, from anywhere:

```bash
printf 'Is this SQL injection-safe?\n' \
  | ~/.claude/bin/spawn-lens --alias claude-gpt --max-tokens 2048 \
  | jq -r '.text'
```

Two things make that pleasant rather than fragile:

**Every script prints exactly one JSON object, always** — whether it worked or
not. Diagnostics go to stderr. So `| jq` never chokes on a half-written response.

**The exit code tells you what happened**, so you never parse English to find
out:

| Code | Meaning |
|---|---|
| `0` | it worked |
| `2` | you asked for something impossible — fix the call |
| `3` | it isn't reachable — try `/spawn:report` |
| `4` | that model isn't being served — the response lists which are |
| `5` | the provider failed — `error` says how |
| `6` | it took too long and was cancelled cleanly |
| `7` | the credentials were rejected |

And every script will describe itself, so a script can ask rather than assume:

```bash
bash lib/lens.sh --describe | jq '.families'
```

---

## About your keys

Your OpenRouter key lives in the macOS Keychain. It is never written into a
command line, a log file, or anything this plugin generates. When a script needs
to hand it over, it does so through a temporary file that only you can read, and
deletes it in the same breath.

There is a second credential used only between the pieces on your own machine.
It is worthless off `127.0.0.1`, and either can be replaced at any time:

```
/spawn:setup --rotate-gateway-token
/spawn:setup --rotate-openrouter-key
```

---

## Reference

Everything below is the detailed reference — the scripts, their flags, the
contracts they publish, and the reasoning behind the parts that look unusual.

---

## The two surfaces

### Headless lens — `lib/lens.sh` (the default)

A prompt in, one JSON object out, no terminal involved. This is what a skill
calls when it wants a different vendor's read on something.

```bash
printf '%s' "$PROMPT" | bash "${CLAUDE_PLUGIN_ROOT}/lib/lens.sh" --alias gpt-sol
bash "${CLAUDE_PLUGIN_ROOT}/lib/lens.sh" --alias kimi --prompt-file ./diff.txt
```

That form works **from this plugin's own skills and commands only** — see
*Calling from another plugin* below for everyone else.

The prompt goes on **stdin or `--prompt-file`, never argv** (KTD8) — argv hits
quoting and length limits first, and silently. A response above ~16 KB spills to
a file and the JSON carries `output_file` instead of `text`.

#### Calling from another plugin

`${CLAUDE_PLUGIN_ROOT}` always resolves to the **calling** plugin's root.
Inside this plugin's skills it points here; inside *your* plugin's skill it
points at your plugin, and the invocation above fails with "no such file". A
foreign consumer resolves the installed path first:

```bash
SPAWN_LENS=""
for f in ~/.claude/plugins/cache/*/spawn/*/lib/lens.sh; do
    [ -f "$f" ] && SPAWN_LENS="$f" && break
done
[ -n "$SPAWN_LENS" ] || { echo "spawn plugin is not installed" >&2; exit 3; }

printf '%s' "$PROMPT" | bash "$SPAWN_LENS" --alias gpt-sol
```

A glob, not `ls` — resolution has to survive shells whose `ls` decorates its
output. The same recipe with `launch.sh` or `spawnctl.sh` reaches the other
two surfaces.

There is no Claude Code agent loop on the far side (KTD1). It is a plain
completion against the gateway's messages endpoint, so the model cannot read a
file, run a command, or edit the code it is reviewing — in any configuration.
There is also no spend cap, warning, or counter anywhere in this path (R7), by
decision.

**The script is the real surface, not the skill.** The lens's primary consumers
run with `allowed-tools: Bash, Read` and cannot invoke a skill or a slash
command at all. `skills/lens/SKILL.md` is the human front door and the field
reference.

Full flag list and field-by-field JSON reference: `skills/lens/SKILL.md`.

### Interactive launch — `lib/launch.sh` (explicit invocation only)

Materializes a session on a named alias, seeded with an opening prompt, and
prints a resume handle. **The plugin never opens a terminal.** The seed turn
runs headlessly through `claude`, which puts the session on disk; you attach on
your own terms.

```bash
printf '%s' "$SEED" | bash "${CLAUDE_PLUGIN_ROOT}/lib/launch.sh" --alias gpt-sol
```

The handle carries `attach_command`, `session_id`, `transcript_path`, `cwd`,
`base_url`, and the declared `context_window`. **The gateway token appears in
none of them** (KTD6): the attach command carries the token *by reference* and
re-reads it from the gateway config at attach time. Do not resolve it into a
literal.

Full reference: `skills/launch/SKILL.md`.

### Setup — `lib/setup.sh` (the `/spawn:setup` command)

Takes a bare Mac to a working gateway-backed session in one run: resolve the
latest published gateway release, fetch and build it, promote it to
`~/gateway-<version>` in one atomic move, capture the OpenRouter key and a
generated gateway token into the macOS Keychain, adopt a launchd agent that
already supervises the gateway if there is one, wire every installed harness (Claude Code and Codex), start the gateway, and
only then claim success — after a live completion round-trip in each wired
harness's own wire shape *and* an unauthenticated request that the gateway must
reject.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/setup.sh"                          # the whole path
bash "${CLAUDE_PLUGIN_ROOT}/lib/setup.sh" --rotate-gateway-token   # replace the token
bash "${CLAUDE_PLUGIN_ROOT}/lib/setup.sh" acquire                  # just fetch/build/promote
```

Two properties worth knowing before you read the output:

- **Writing the config files is not evidence.** The plugin's expander resolves
  an unset `${VAR}` to an empty string while the gateway's own expander
  hard-errors on it, so plugin-side parsing can report a healthy-looking
  credential for a config the gateway would refuse to boot on. That is why
  success is a round-trip and never a file write (KD10).
- **An empty auth-token list is not "no auth" — it is an open proxy.** The
  gateway's auth check returns success immediately when its token list is
  empty, forwarding to a paid account for anything on the box. Setup refuses to
  leave that state and proves the refusal with a request that carries no
  credential at all.

`setup.sh` is **non-interactive**. Where it needs the operator's say-so —
appending a line to your shell rc, repointing a launchd agent it did not write —
it exits **8** with a `consent_required` field naming the flag to come back with
(`--consent-shell-rc`, `--consent-adopt-agent`). Exit **9** is a missing
prerequisite. Both codes join the enum below and belong to setup only.

**Setup deliberately ships no skill.** A command and a same-named skill collide
and the command wins — which is why the three `SKILL.md` files in this plugin
never load on the installed plugin. `commands/setup.md` therefore carries the
whole contract itself: the flag list, the exit-code table, the consent loop, and
the field-by-field JSON guide. Adding `skills/setup/SKILL.md` would shadow
nothing useful and silently strand the text inside it; `tests/unit/surfaces.bats`
fails if that directory appears.

#### What the Keychain does and does not buy you (KTD9)

Both secrets live in the macOS login keychain and neither is written to disk in
plaintext. **The limitation is documented here, not solved:** the default ACL
authenticates the *binary* `/usr/bin/security`, not the caller, so **any
same-user process can read either secret silently** — roughly the protection of
a mode-0600 file against same-user agents.

Its real wins, which are the reasons it is still the floor here:

- encryption at rest,
- protection while the keychain is locked,
- cross-user isolation,
- staying out of dotfile backups and Time Machine copies of your home directory.

A code-signed reader binary plus a partition list would close the hole. It is
out of scope and nothing here pretends otherwise.

### Control layer — `lib/spawnctl.sh`

`start | stop | restart | status | ensure [alias]`. Liveness is a token-bearing
probe of the model-list endpoint (KTD3), never a pidfile read. `status` lists
what the gateway is actually serving and flags drift against the plugin's
context-window table. `ensure` is the shared preflight both surfaces call.

Full reference: `skills/status/SKILL.md`.

Every path between components goes through `${CLAUDE_PLUGIN_ROOT}`. Nothing is
invoked by PATH lookup: a name on PATH is whatever the operator's machine says
it is, and the plugin has to reach its own scripts.

---

## Exit codes

The enum is defined once, in the plan's **KTD2**
([`docs/plans/2026-08-06-001-feat-gateway-plugin-plan.md`](../../docs/plans/2026-08-06-001-feat-gateway-plugin-plan.md),
*Key Technical Decisions*). Every script, SKILL.md, and test in this plugin
cites it rather than restating it as an independent rule. Reproduced here as a
lookup table only:

| Code | Class |
|---|---|
| `0` | ok |
| `2` | usage or refusal |
| `3` | gateway unreachable and could not be started |
| `4` | alias unknown to the gateway |
| `5` | upstream provider error — the JSON's `error` field distinguishes `rate_limited`, `context_overflow`, `no_text_truncated` (the model spent its whole token budget reasoning and never wrote an answer — raise `--max-tokens`) and `no_text_in_response` from other upstream failures |
| `6` | deadline exceeded |
| `7` | gateway reachable but rejected the plugin's token |
| `8` | operator confirmation required — `setup.sh` only; nothing was changed on that path |
| `9` | missing prerequisite — `setup.sh` only; nothing was changed |

`setup.sh` returns 0, 2, 3, 8 and 9 and nothing else; 4 through 7 belong to the
lens and the control layer. `tests/unit/surfaces.bats` reads the `EX_*`
constants out of `lib/setup.sh` and fails if the table in `commands/setup.md`
misses one, so the command's table cannot drift away from the code.

Two properties KTD2 owns that are easy to lose: **every script prints exactly
one JSON object on stdout, on every path including every failure**, and
diagnostics go to stderr only. And **7 is deliberately not 3** — an auth failure
means the gateway is *up*, so treating it as unreachable would send `ensure`
into a start that collides with the running process.

Failure-class tests in `tests/unit/` assert on the numeric code, never on a
message.

---

## Allowlist entry for unattended fan-out

A fan-out of lens calls stalls on a Bash permission prompt unless the caller's
settings allowlist the script. The path an install puts the lens at has the
**version in it**, so a rule naming it directly stops matching on the next
upgrade — silently, as a stalled fan-out rather than an error. Two steps, once:

**1. Install the shim.** The plugin ships `bin/spawn-lens`, a wrapper that
resolves the installed lens at run time and execs it. Copy it to a path of your
own that has no version in it:

```bash
mkdir -p ~/.claude/bin
for f in ~/.claude/plugins/cache/*/spawn/*/bin/spawn-lens; do
    [ -f "$f" ] && install -m 0755 "$f" ~/.claude/bin/spawn-lens && break
done
```

**2. Add one rule** to `permissions.allow` in `~/.claude/settings.json`:

```json
"Bash(bash ~/.claude/bin/spawn-lens:*)"
```

Then call the lens through that same path, spelled the same way:

```bash
bash ~/.claude/bin/spawn-lens --alias gpt-sol --prompt-file ./diff.txt
```

Notes on that string:

- **The version is not in it, and the wildcard is not in the rule.** The shim
  globs the cache and picks the newest install, so the rule survives an upgrade
  without `permissions.allow` ever naming a cache directory — a rule containing
  a wildcarded cache path would authorize whatever else ever lands under it.
  The shim resolves the lens and nothing else, and takes no path from its
  caller, so allowlisting it authorizes exactly one thing.
- **Re-copy the shim after a plugin upgrade only if this section says to.** The
  shim's own resolution logic carries no version, so an existing copy keeps
  working across upgrades; the rule never changes.
- **An earlier version of this document named
  `~/.claude/plugins/marketplaces/<marketplace>/plugins/<plugin>/lib/lens.sh`.
  That path does not exist.** Installed plugins live under `cache/`, and on a
  verified install `~/.claude/plugins/marketplaces/<marketplace>/` was empty.
  A rule written against it can never match anything, which is the worst
  possible failure here because it presents as a hang, not a refusal.
- `${CLAUDE_PLUGIN_ROOT}` does not expand inside settings, which is why this has
  to be a literal path at all.
- **The rule matches literal command text, so the rule and the invocation must
  be spelled to agree.** A command that reaches Bash as an unexpanded
  `${CLAUDE_PLUGIN_ROOT}` path, or as the absolute `/Users/you/...` path the
  foreign-consumer recipe above resolves, is a *different string* from the
  `~/...` spelling in this rule. Pick one spelling, use it in both the rule and
  the invocation — if your consumer resolves an absolute path, write the rule
  with that same absolute path. A mismatched rule does not error: it shows up as
  a fan-out silently stalled on a permission prompt.
- Allowlist the **lens** only. `launch.sh` starts a real session and
  `spawnctl.sh` starts and stops a process; both are worth a prompt. The shim
  reaches the lens and only the lens, which is what makes one rule enough.
- With no install to resolve, the shim prints one JSON object with
  `error: "not_installed"` and exits `3` — the same code the foreign-consumer
  recipe uses for the same condition. It never falls through to a prompt.

**This plugin can do neither step for you.** A plugin ships files inside its own
tree: it cannot copy the shim to `~/.claude/bin` and it cannot modify user
settings, and nothing here tries to. Both steps are manual and opt-in, and
rollout beyond this paragraph is deliberately deferred.

---

## Two doors, two ceilings — `lib/bg-operator.sh` and `lib/bg-repo.sh`

A background job runs under a permission ceiling, and **which ceiling is
decided by which file ran** — not by anything the caller says about itself.

| entry point | who it is for | what the child gets |
|---|---|---|
| `lib/bg-operator.sh` | a person who typed a command | `--settings permissions/operator.settings.json --permission-mode dontAsk` |
| `lib/bg-repo.sh` | an agent, with no human present | `--setting-sources project --settings <rendered repo-bounded config> --permission-mode dontAsk` |

The difference that actually bites is `--setting-sources project`: it drops
`user`, so the child does **not** inherit what you have already allowed
yourself. Measured — a child launched from a session that broadly allows shell
access could not run a shell command, while the control arm with the same
prompt could.

`--permission-mode dontAsk` is on both, and is not about who called: an
unattended job that can wait on a permission decision nobody is there to make
is stalled forever, so an unallowed call is refused rather than queued.

There is deliberately **no `--ceiling` flag**. A flag would be self-declared,
and any agent able to run the script could claim to be the operator. Allowlist
the two paths separately and the harness decides which ceiling a caller can
reach:

```json
"Bash(bash */plugins/spawn/lib/bg-operator.sh:*)"
"Bash(bash */plugins/spawn/lib/bg-repo.sh:*)"
```

### What the repo-bounded default allows and denies

Read the file — `permissions/repo-bounded.settings.json` — it is the whole
story. In summary: reads, greps, writes and edits are **scoped to the
worktree**; version-control internals and hooks, and agent configuration
(`.claude/`, `.claude-plugin/`, `CLAUDE.md`, `AGENTS.md`, `.mcp.json`) are
denied; `Bash` is simply not allowed.

`{{WORKTREE}}` in that file is substituted at launch with the job's worktree.
A permission path is only absolute when it starts with `//`, which is why the
rules read `//{{WORKTREE}}/**` and the substitution drops the leading slash —
a rule written `/Users/...` matches nothing and reads exactly like a working
allow that silently is not one.

Two consequences worth knowing:

- **The symlink bound is not a rule, it is a resolution.** There is no symlink
  primitive in the settings grammar. The permission system resolves a path
  before matching it, so a link inside the tree that resolves outside falls
  outside the worktree-scoped allow and is refused. Measured.
- **Nothing here removes a tool, but only some refusals are observable.** A
  tool-level deny *removes* the tool — the model reports having no such tool
  and never attempts it, so there is nothing to see. This ceiling uses none of
  those. What it does use splits in two, measured:
  - **Not allowed** (`Bash`, a write outside the worktree): attempted,
    refused, and recorded in the child's result JSON as
    `permission_denials[] = {tool_name, tool_use_id, tool_input}`.
  - **A deny rule** (`.git/**`, `.claude/**`, `CLAUDE.md`, …): attempted and
    refused, but it leaves **no** entry in `permission_denials[]`. The only
    account of it is the model's own prose, which is not a witness worth
    trusting. Detect those by effect — the file is not there — not by asking.

Within the bound the model still **reads** whatever the worktree contains,
secrets included. This ceiling denies execution-bearing paths, not readable
ones.

### Overriding a ceiling

The plugin ships defaults and **never edits your settings** — not your
`~/.claude/settings.json`, not a project's. To override, point an environment
variable at your own file:

```bash
export SPAWN_CEILING_CONFIG_REPO=~/my-repo-ceiling.json      # the agent door
export SPAWN_CEILING_CONFIG_OPERATOR=~/my-operator-ceiling.json
```

Your file is used exactly as shipped ones are: read, `{{WORKTREE}}`
substituted, handed to the child. Editing `permissions/*.json` in place works
too, and is the right move when the change should travel with the plugin. The
harness's own agent defaults are the third route, and they are outside this
plugin entirely.

A ceiling that cannot be read or rendered is **not** a job that starts wide —
it is exit 2 with `error: "ceiling_unavailable"` and no child at all.

### What these doors do not do

They do not police the bound. The ceiling is a permission configuration the
child session runs under and the **harness** enforces it; these scripts choose
which configuration to hand down and hand it down. They also do not classify
the result: a fully denied child returns `is_error: false` and exit 0
(measured), so `child_exit_code` in the response is data, never evidence that
work happened.

---

## What a gateway-pointed session does not have

First, the thing it *does* have, because it changes the trust posture: unlike
the lens — a plain completion, no tools, can only answer — a launch session
runs Claude Code's **full agent loop** under the user's normal permissions in
the pinned project directory, with a third-party model deciding the actions.
That is the feature; weigh it the way KTD5 weighs lens text.

The rest, verified live on 2026-08-06 (see `skills/launch/SKILL.md`, which says
the same thing at the point of handover) — expected, not breakage:

- **claude.ai MCP connectors do not load.** The gateway auth token takes
  precedence over the claude.ai login, so the connectors that login would carry
  are absent.
- **The advisor tool is disabled.** Gateway aliases carry no advisor rank in the
  model catalog.
- **Claude Code warns that the model is unrecognized** unless a context window
  is declared. That is what `lib/models.json` and
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` are for (KTD7). An alias with no table entry
  still launches — the gateway's served list is the allowlist, the table is only
  metadata — but it launches without a declared window and draws the warning.
  `spawnctl.sh status` reports exactly that as `drift.missing_from_table`.

Two caveats on the attach command, both inherent to carrying the token by
reference rather than bugs: it is **bash-specific**, and it assumes the config
path captured at launch still exists at attach time.

---

## The `gw` note

If you already have a `~/.local/bin/gw`, **this plugin does not touch it**.
Setup used to rewrite it to delegate to `lib/spawnctl.sh`; that step is gone,
because taking over a file the operator wrote is not setup's to do.

The consequence worth knowing: your `gw` and this plugin are two independent
front doors to one gateway. If yours does pidfile-based liveness or truncates
`~/.gateway.log` on start, it still does — the plugin's control layer probes the
model-list endpoint instead (KTD3) and appends to the log, and the two can
disagree about whether the gateway is up. Reach for `lib/spawnctl.sh` when you
want the plugin's answer.

Both do share `~/.gateway.pid`, `~/.gateway.log` and `~/.gateway.lock` if your
`gw` uses the default paths, so they see the same gateway rather than starting
two.

---

## Tests

No CI exists in this repo, so the local harness is the entire automated
verification contract.

```bash
bash plugins/spawn/tests/run-tests.sh all         # release gate
bash plugins/spawn/tests/run-tests.sh unit        # per-unit iteration
bash plugins/spawn/tests/run-tests.sh self-check  # prove the harness can fail
bash plugins/spawn/tests/run-tests.sh smoke       # wire-up + agent-consumer + secret scan
```

Suites in `tests/unit/`:

| Suite | What it holds |
|---|---|
| `fixtures.bats` | the fixtures themselves — a fake gateway that stops requiring auth would turn every later suite into noise |
| `spawnctl.bats`, `lens.bats`, `launch.bats` | the three runtime surfaces |
| `escapes.bats` | the escape matrix below, plus the computed-scope lint over every `lib/*.sh` |
| `regressions.bats` | defects that came back once |
| `secrets.bats` | the Keychain primitives — argv leakage, the silent-empty write, read-back proof |
| `setup-acquire.bats` | release resolution, fetch, build, staging invisibility, atomic promotion |
| `setup-config.bats` | config migration and token retirement (the token entry is deleted, never parsed) |
| `setup-wiring.bats` | harness detection, the Codex managed block, the shell snippet and rc line |
| `setup.bats` | orchestration, rotation, and the two-layer round-trip proof |
| `surfaces.bats` | the shipped surfaces — no skill directory shares a command's name, `commands/setup.md` reaches no other surface, and its exit-code table matches `setup.sh`'s `EX_*` constants |

Everything runs against `tests/fixtures/` — a stdlib-Python fake gateway
(`fake-gateway.py`) and fakes for every external the setup path touches:
`fake-security.sh` and `fake-osascript.sh` stand in for the credential store and
the key dialog, `fake-curl.sh` and `fake-cargo.sh` for the fetch and the build,
`fake-gateway-bin.sh` for the built binary at exec time, and `fake-claude.sh` /
`fake-codex.sh` for the two harnesses. **The real gateway on port 4000 and
OpenRouter are out of the test path by decision.** A suite that reached either
would fight a live process or spend real money, and both turn green into noise.
Nothing fakes the live completion — that is the one thing only a real run
proves, and setup's round-trip is the only place it happens.

`smoke` covers four things: plugin/marketplace version parity, the
agent-consumer invocation (the lens driven exactly the way a tool-restricted
subagent drives it — Bash, prompt on stdin, stdout captured), a secret scan over
every shipped file (R12), and `claude plugin validate` — judged by grepping its
output for `Validation passed`, **never by its exit code**, which is 0 even when
validation fails.

---

## Terminal-escape source × sink matrix (KTD5)

### Why this section exists

This plugin's whole job is printing text produced by a **non-Anthropic model**,
plus alias names and notes read from a **user-editable `gateway.yaml`**, straight
to a terminal. ESC / CSI / OSC sequences (an OSC-2 title rewrite, a CSI screen
erase) and Unicode bidi overrides (U+202E) in that output can rewrite the
statusline or spoof a consent prompt.

The precedent is
[`plugins/claude-modes/docs/solutions/terminal-escape-audit.md`](../claude-modes/docs/solutions/terminal-escape-audit.md).
Two lessons from it shape this one:

1. **Narrow greps leave siblings open.** That bug class reopened at a new sink
   in three consecutive review rounds because each round grepped for the last
   round's pattern. This matrix was built by reading all three scripts end to
   end, and the sinks are closed at **chokepoints** — `say()`, `die()`,
   `emit_error()` — not at call sites, so a diagnostic nobody has written yet is
   closed too.
2. **Verify against source, never against this table.** The precedent's own
   audit doc falsely claimed a sink was sanitized and hid a real gap for seven
   rounds. Every row below names the file and the function; read them. And every
   row marked closed has a test in `tests/unit/escapes.bats` pointing at it —
   listed in the last column, by test name.

### The defence has two halves

| Half | Applies to | Mechanism |
|---|---|---|
| **Closed by construction** | identifiers — alias names, the session id | validated against `[A-Za-z0-9._-]+` at every input site, so an escape byte is *impossible*, not filtered |
| **Sanitized at the sink** | free-form text — model prose, gateway error bodies, config-derived notes, log tails, process argv, raw argv | `spawn::sanitize_for_display` / `spawn::sanitize_stream` in `lib/sanitize.sh` |

`lib/sanitize.sh` strips C0 controls except **tab and newline** (so ESC, CR, BEL
and NUL go), DEL, C1 controls, and the Unicode format characters that reorder or
hide text (U+00AD, U+061C, U+200B–U+200F, U+2028–U+202E, U+2060–U+206F, U+FEFF).
It keeps every printable character, including non-ASCII prose. It does **not** do
NFKC / homoglyph defence — see *Known limits*.

### Sources

| # | Source | Reaches the plugin via |
|---|---|---|
| S1 | model prose | the messages response body (`lens.sh`) and the seed child's output (`launch.sh`) |
| S2 | gateway / upstream error bodies | `.error.message` on a non-200 (`lens.sh`); `~/.gateway.log` (`spawnctl.sh`) |
| S3 | `gateway.yaml`-derived names and model strings | `yaml_scan` → `CONFIG_MODELS_JSON` (`spawnctl.sh`) |
| S4 | `models.json` fields (`source` note, `model`, `context_window`) | the alias table (`spawnctl.sh status`, `launch.sh`) |
| S5 | the gateway's served alias list | `GET /v1/models` response ids (`spawnctl.sh probe`) |
| S6 | the caller's own argv (alias, flags, paths) | every script's argument parser |
| S7 | the `claude` CLI's reported session id | the seed run's JSON (`launch.sh`) |
| S8 | an unrelated process's argv | `ps -o args=` on a recycled pid (`spawnctl.sh stop`) |
| S9 | the environment / filesystem (install dirs, state paths, base URL) | `SPAWN_*` overrides and `~/gateway-*` resolution |
| S10 | GitHub release metadata — tag names, commit shas | the release/commit lookups in `setup.sh` acquire |
| S11 | a harness's own loader output | `codex doctor --json` → `CODEX_LOAD_DETAIL` (`setup.sh` wire) |
| S12 | files on disk setup did not write — `~/.codex/config.toml`, a previous `gateway.yaml`, a launchd plist | the managed-block scan, config migration, the supervisor's plist read (`setup.sh`) |
| S13 | build tool output — `cargo`, `tar`, `curl` failures | the acquire step's failure messages (`setup.sh`) |

**Not a source, deliberately.** Neither credential is ever a display value.
`secrets.sh` returns them to a caller's local and prints nothing at all; the
round-trip drops the HTTP response body rather than reporting it, because a 401
body can quote the credential that was presented (AE7). Only the status code and
the route reach the output.

### Sinks, part 1 — everything written to stderr

Terminal sinks, per script. "Fixed" means the line interpolates nothing.

| Sink (file · function/line) | Sources reaching it | Disposition | Test |
|---|---|---|---|
| `spawnctl.sh` · `say()` | S2, S3, S5, S6, S9 | **sanitized** — chokepoint | `argv:` …, `gateway log tail:` … |
| `spawnctl.sh` · `die()` | S6, S9 | **sanitized** — chokepoint | `argv: an escape-laden unexpected argument …` |
| `spawnctl.sh` · log tail after a failed start | S2 | **sanitized** — `spawn::sanitize_stream` | `gateway log tail: a poisoned log line …` |
| `spawnctl.sh` · `tmpwork` / `need_jq` / `usage` | — | **fixed string** | (nothing to test — no interpolation) |
| `lens.sh` · `say()` | S6, S9 | **sanitized** — chokepoint | `argv:` … |
| `lens.sh` · `die()` | **S2 (upstream error body)**, S6, S9 | **sanitized** — chokepoint | `gateway error body: the upstream message …` |
| `lens.sh` · `tmpwork` / `need_jq` / `usage` | — | **fixed string** | — |
| `launch.sh` · `say()` | S4, S6, S9 | **sanitized** — chokepoint | `a non-numeric context_window …` |
| `launch.sh` · `die()` | S6, S7, S9 | **sanitized** — chokepoint | `argv:` …, `KTD5 grammar: a session id …` |
| `launch.sh` · seed-run stderr tail | **S1** | **sanitized** — `spawn::sanitize_stream` | `seed-run stderr tail: a poisoned child stderr …` |
| `launch.sh` · `tmpwork` / `need_jq` / `usage` | — | **fixed string** | — |
| `setup.sh` · `say()` | S6, S9, S10, S11, S12, S13 | **sanitized** — chokepoint, byte-identical to the sibling scripts' so the lint can read it | the `lib/*.sh` sink lint (computed scope — `setup.sh` is in it) |
| `setup.sh` · `die()` | S6, S9, S10, S11, S12, S13 | **sanitized** — chokepoint, inline at the `printf` | the `lib/*.sh` sink lint |
| `setup.sh` · `usage()` / `need_jq` | — | **fixed string** | (nothing to test — no interpolation) |
| `secrets.sh` · — | — | **no terminal sink at all**; it prints nothing and returns values to the caller's local. Callers own their own diagnostics and must not print a returned value. | exempt from the three structural lint checks by an annotated carve-out; still scanned for raw sinks |

### Sinks, part 2 — the one JSON object on stdout

Each script writes exactly one JSON object through its own `emit()` (KTD2). The
object is a mixed channel, so the disposition is **per field**, not per script:

| Field | Script | Source | Disposition | Test |
|---|---|---|---|---|
| `text`, `output_file` contents | lens | S1 | **RAW BY DESIGN** — data, not display. JSON escapes the bytes in transit and a consumer gets them back on parse; KTD5 assigns that sink to the consumer, and `skills/lens/SKILL.md` says so. Stripping here would corrupt legitimate code blocks in a review answer. | `model prose: the JSON text field keeps the bytes as data …` |
| `error`, `detail` | all three | S2, S6, S9 | **sanitized** in `die()` / `emit_error()` | `gateway error body: …`, `argv: …` |
| `alias` (success paths) | all three | S6 | **closed by grammar** — `validate_alias` ran first | `KTD5 grammar:` ×3 |
| `alias` (error paths) | lens, launch | S6 | **sanitized** — this is the one path where the alias may be one the grammar *refused*; jq escapes a control byte but emits a bidi override literally | `KTD5 grammar: lens refuses an escape-laden alias …` |
| `served_aliases` | spawnctl | S5 | **sanitized** at the probe, where the list enters. A grammar-valid alias is byte-identical through the sanitizer, so the `ensure` membership check that exit 4 depends on is unaffected. | `served alias list: escape bytes off the wire …` |
| `models[]` (`alias`, `source`, `model`) | spawnctl | S4 | **sanitized** — display-only; this is the promise `skills/status/SKILL.md` already makes | `config-derived display text: …` |
| `drift.*` (`missing_from_table`, `model_drift.recorded`/`.current`) | spawnctl | S3, S4, S5 | **sanitized**, and the `CONFIG_MODELS_JSON` it reads is built with `jq` so a poisoned config cannot produce invalid JSON either | `config-derived display text: …` |
| `install_dir_error` | spawnctl | S9 | **sanitized** — display-only prose | `gateway log tail:` (same `say`/`die` chokepoint) |
| `actual_argv` (stop, pid mismatch) | spawnctl | S8 | **sanitized** — another process's command line, printed by whoever is diagnosing | (chokepoint-level; covered by the `argv:` sanitize tests and the lint) |
| `verb` in the **no-jq** fallback line | spawnctl | S6 | **closed by construction** — reduced in pure bash to the verb enum's charset, because with no jq there is no encoder and a quote would break the object | (structural; enforced by reading — see *Known limits*) |
| `session_id`, `transcript_path`, `attach_command` | launch | S7 | **closed by grammar** — the session id is held to `[A-Za-z0-9._-]+`; the path and the attach command are derived from it plus shell-quoted values | `KTD5 grammar: a session id that fails the grammar …` |
| `steps[].detail`, `failed_step` | setup | S6, S9, S10, S11, S12, S13 | **sanitized** — every entry is either an authored fixed string or a `die()` message, and `die()` sanitizes before the failure object is built | (chokepoint-level; the `lib/*.sh` sink lint) |
| `changed[]` (`what`, `target`, `detail`) | setup | S9 | **authored fixed strings plus functional paths** — the paths are the same raw-by-design class as the last row: they are what the operator has to go look at | — |
| `losses`, `validation_gaps` | setup | — | **authored fixed strings**, copied into `setup.sh` at authoring time rather than read from a `SKILL.md` that never loads (KD9). No external input reaches them. | — |
| `wired[]` / `skipped[]` (`validation_detail`) | setup | **S11 (another program's output)** | **sanitized** — `CODEX_LOAD_DETAIL` is `codex doctor`'s own text, encoded by `jq` and relayed as display only | — |
| `verification.round_trip[]` | setup | — | **status code and route only.** The HTTP response body is **dropped, never relayed** — a 401 body can quote the credential that was presented (AE7). | `setup.bats` (the auth-class round-trip test asserts on the code, not a message) |
| `consent_required` | setup | — | **closed by construction** — one of two authored literals (`shell-rc`, `adopt-agent`), which is what lets `commands/setup.md` map it to a flag | `surfaces.bats` (the table names the flag) |
| `base_url`, `config`, `log`, `pidfile`, `install_dir`, `binary`, `cwd`, `output_file` path, `pid`, `context_window` | all three | S9, S4 | **RAW BY DESIGN — functional, not display.** `lens.sh` and `launch.sh` *parse* `.base_url` and `.config` back out to build the request and read the token; sanitizing a path or a URL would silently corrupt a value the plugin itself consumes. They are also caller-supplied (`SPAWN_*` env, `--cwd`), so the threat model is self-shoot, not a hostile third party. Two of them are nonetheless closed by construction anyway: `pid` is digit-filtered by `read_pidfile`, and `context_window` is constrained to digits before it is used or printed. | `a non-numeric context_window …` |

One re-entrant path was checked and is not a sink: `spawnctl.sh restart`
re-invokes itself as `bash "$0" stop >/dev/null 2>&1`, discarding **both**
streams, so the inner run's diagnostics never reach a terminal. It is the only
self-re-exec in the plugin.

### What is NOT sanitized, restated

- The lens's `text` field and the spill file. Data, by decision (KTD5), and the
  lens skill documents it. A consumer that prints them owns that sink.
- Functional path and URL fields in the JSON, for the reason in the last row
  above. Sanitizing them would break the plugin's own parsing.

### Enforcement

- `tests/unit/escapes.bats` — 17 tests. Every sanitization test first asserts
  the poison byte is **present in the input**, because "no escape survived" is
  vacuously true when the escape was never there. Negative assertions go through
  `refute_bytes`, never `! grep` — bats runs under `set -e`, but POSIX exempts a
  pipeline beginning with `!`, and that shape has already let a false assertion
  pass green in this repo.
- The last two tests are a **lint** with computed scope: it reads every
  `lib/*.sh` (excluding `sanitize.sh`, the defence itself) and fails if a script
  does not source the shared sanitizer, if its `say()` chokepoint stops
  sanitizing, or if any line writes to stderr while interpolating a variable
  without routing through a defence. The second test **plants a raw sink and
  asserts the lint goes red** — a detector never seen failing is vacuous green.
- Adding a new print site means routing it through `say`/`die` (or
  `spawn::sanitize_stream` for a file), and adding a row here.

### Known limits

- **No homoglyph / NFKC defence.** Visually-confusable Unicode still renders as
  itself. This stops injection, not all spoofing.
- **Without `jq`, the fallback is byte-oriented** (`tr`), so it removes every C0
  control — hence every CSI and OSC sequence — but not the multi-byte Unicode
  format characters. Accepted: with no `jq` every script here exits 2 within a
  few lines anyway, since it cannot satisfy "one JSON object on stdout".
- **The no-jq JSON fallback lines are structural, not test-covered.** They are
  reachable only on a box without `jq`, which the harness's own dependency check
  refuses to run on. They are closed by construction (fixed strings plus a
  charset-reduced verb) rather than by a test, and this row says so instead of
  claiming coverage that does not exist.
