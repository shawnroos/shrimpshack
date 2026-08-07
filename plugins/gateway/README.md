# gateway

Run Claude on any model the local Superagent Gateway serves — headlessly for
skills that need a different-vendor answer (`lib/lens.sh`), or as an attachable
session (`lib/launch.sh`), over a control layer that owns liveness and startup
(`lib/gatewayctl.sh`).

The gateway is a local process that fronts OpenRouter (and anything else its
config carries) behind an Anthropic-shaped API. This plugin is the control
surface for it: it decides whether the gateway is up, starts it if not, and then
either asks a model a question or hands you a session on one.

**Requirements:** `bash`, `curl`, `jq`. `python3` and `bats` only for the tests.
Nothing else — no other shrimpshack plugin, no node (R11).

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
GATEWAY_LENS=""
for f in ~/.claude/plugins/marketplaces/*/plugins/gateway/lib/lens.sh; do
    [ -f "$f" ] && GATEWAY_LENS="$f" && break
done
[ -n "$GATEWAY_LENS" ] || { echo "gateway plugin is not installed" >&2; exit 3; }

printf '%s' "$PROMPT" | bash "$GATEWAY_LENS" --alias gpt-sol
```

A glob, not `ls` — resolution has to survive shells whose `ls` decorates its
output. The same recipe with `launch.sh` or `gatewayctl.sh` reaches the other
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

### Control layer — `lib/gatewayctl.sh`

`start | stop | restart | status | ensure [alias]`. Liveness is a token-bearing
probe of the model-list endpoint (KTD3), never a pidfile read. `status` lists
what the gateway is actually serving and flags drift against the plugin's
context-window table. `ensure` is the shared preflight both surfaces call.

Full reference: `skills/status/SKILL.md`.

Every path between components goes through `${CLAUDE_PLUGIN_ROOT}`. Nothing is
invoked by PATH lookup — see *The `gw` note* below for why that matters.

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
settings allowlist the script.

**Do not copy a path from this document — read it off your own install**, then
put it in `permissions.allow` in `~/.claude/settings.json`:

```bash
ls -d ~/.claude/plugins/cache/*/gateway/*/lib/lens.sh
```

On the box this was verified on, that prints:

```
/Users/<you>/.claude/plugins/cache/shrimpshack/gateway/0.1.0/lib/lens.sh
```

giving a rule of the shape:

```json
"Bash(bash ~/.claude/plugins/cache/shrimpshack/gateway/0.1.0/lib/lens.sh:*)"
```

Notes on that string:

- **The version is IN the path.** `0.1.0` is a real directory component, so a
  rule pinned to it stops matching the moment you upgrade — and it stops
  matching *silently*, as a stalled fan-out rather than an error. Re-read the
  path after every upgrade, or write the rule against a stable absolute path you
  control (a symlink, or a wrapper script of your own that execs the versioned
  one).
- **An earlier version of this document named
  `~/.claude/plugins/marketplaces/<marketplace>/plugins/gateway/lib/lens.sh`.
  That path does not exist.** Installed plugins live under `cache/`, and on a
  verified install `~/.claude/plugins/marketplaces/<marketplace>/` was empty.
  A rule written against it can never match anything, which is the worst
  possible failure here because it presents as a hang, not a refusal.
- `${CLAUDE_PLUGIN_ROOT}` does not expand inside settings, which is why this has
  to be a literal path at all.
- **The rule matches literal command text, so the rule and the invocation must
  be spelled to agree.** A command that reaches Bash as an unexpanded
  `${CLAUDE_PLUGIN_ROOT}` path, or as the absolute `/Users/...` path the
  resolution recipe above produces, is a *different string* from the `~/...`
  spelling in this rule. Pick one spelling, use it in both the rule and the
  invocation — if your consumer resolves an absolute path, write the rule with
  that same absolute path. A mismatched rule does not error: it shows up as a
  fan-out silently stalled on a permission prompt.
- Allowlist the **lens** only. `launch.sh` starts a real session and
  `gatewayctl.sh` starts and stops a process; both are worth a prompt.

**This plugin cannot write that entry for you.** A plugin ships files inside its
own tree; it has no ability to modify user settings, and nothing here tries to.
Adding it is a manual, opt-in step, and rollout beyond this paragraph is
deliberately deferred.

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
  `gatewayctl.sh status` reports exactly that as `drift.missing_from_table`.

Two caveats on the attach command, both inherent to carrying the token by
reference rather than bugs: it is **bash-specific**, and it assumes the config
path captured at launch still exists at attach time.

---

## The `gw` note

`~/.local/bin/gw` is a **separate, unrelated binary**. This plugin deliberately
leaves it untouched (KTD4) — a plugin cannot ship a file outside its repo, so
"fix `gw`" became "replace what `gw` does" inside the plugin's own control
layer.

If you use both, know that they are not the same control surface, and that `gw`
still carries the defects `gatewayctl.sh` exists to fix:

| | `gw` | `lib/gatewayctl.sh` |
|---|---|---|
| **Liveness** | `kill -0` on the pidfile's pid — wrong when the pidfile is stale, and wrong again when that pid has been recycled onto an unrelated process | a token-bearing `GET /v1/models` probe (KTD3, R1) |
| **Logging** | `> "$LOG"` — **truncates** the log on every start, so the history that would explain a crash-restart loop is gone | `>> "$LOG"`, append-only, never truncated (R3) |
| **Install path** | `DIR="$HOME/gateway-0.1.1"` — pinned to one version; the next release silently breaks it | resolved at runtime: explicit env override, else the newest `~/gateway-*`, else a distinct failure (R4) |
| **Concurrent start** | none — five callers against a down gateway race five starts | locked, re-probe under the lock, exactly one process |
| **Token** | hardcoded in the script | read from the resolved config, never printed, never in argv (KTD6) |

The two surfaces share `~/.gateway.pid` and `~/.gateway.log` on purpose, so
neither double-starts against the other and both see the same gateway. But `gw`
truncating that shared log will still discard whatever the plugin appended.

---

## Tests

No CI exists in this repo, so the local harness is the entire automated
verification contract.

```bash
bash plugins/gateway/tests/run-tests.sh all         # release gate
bash plugins/gateway/tests/run-tests.sh unit        # per-unit iteration
bash plugins/gateway/tests/run-tests.sh self-check  # prove the harness can fail
bash plugins/gateway/tests/run-tests.sh smoke       # wire-up + agent-consumer + secret scan
```

Everything runs against `tests/fixtures/` — a stdlib-Python fake gateway and a
fake `claude`. **The real gateway on port 4000 and OpenRouter are out of the
test path by decision.** A suite that reached either would fight a live process
or spend real money, and both turn green into noise.

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
| **Sanitized at the sink** | free-form text — model prose, gateway error bodies, config-derived notes, log tails, process argv, raw argv | `gateway::sanitize_for_display` / `gateway::sanitize_stream` in `lib/sanitize.sh` |

`lib/sanitize.sh` strips C0 controls except **tab and newline** (so ESC, CR, BEL
and NUL go), DEL, C1 controls, and the Unicode format characters that reorder or
hide text (U+00AD, U+061C, U+200B–U+200F, U+2028–U+202E, U+2060–U+206F, U+FEFF).
It keeps every printable character, including non-ASCII prose. It does **not** do
NFKC / homoglyph defence — see *Known limits*.

### Sources

| # | Source | Reaches the plugin via |
|---|---|---|
| S1 | model prose | the messages response body (`lens.sh`) and the seed child's output (`launch.sh`) |
| S2 | gateway / upstream error bodies | `.error.message` on a non-200 (`lens.sh`); `~/.gateway.log` (`gatewayctl.sh`) |
| S3 | `gateway.yaml`-derived names and model strings | `yaml_scan` → `CONFIG_MODELS_JSON` (`gatewayctl.sh`) |
| S4 | `models.json` fields (`source` note, `model`, `context_window`) | the alias table (`gatewayctl.sh status`, `launch.sh`) |
| S5 | the gateway's served alias list | `GET /v1/models` response ids (`gatewayctl.sh probe`) |
| S6 | the caller's own argv (alias, flags, paths) | every script's argument parser |
| S7 | the `claude` CLI's reported session id | the seed run's JSON (`launch.sh`) |
| S8 | an unrelated process's argv | `ps -o args=` on a recycled pid (`gatewayctl.sh stop`) |
| S9 | the environment / filesystem (install dirs, state paths, base URL) | `GATEWAY_*` overrides and `~/gateway-*` resolution |

### Sinks, part 1 — everything written to stderr

Terminal sinks, per script. "Fixed" means the line interpolates nothing.

| Sink (file · function/line) | Sources reaching it | Disposition | Test |
|---|---|---|---|
| `gatewayctl.sh` · `say()` | S2, S3, S5, S6, S9 | **sanitized** — chokepoint | `argv:` …, `gateway log tail:` … |
| `gatewayctl.sh` · `die()` | S6, S9 | **sanitized** — chokepoint | `argv: an escape-laden unexpected argument …` |
| `gatewayctl.sh` · log tail after a failed start | S2 | **sanitized** — `gateway::sanitize_stream` | `gateway log tail: a poisoned log line …` |
| `gatewayctl.sh` · `tmpwork` / `need_jq` / `usage` | — | **fixed string** | (nothing to test — no interpolation) |
| `lens.sh` · `say()` | S6, S9 | **sanitized** — chokepoint | `argv:` … |
| `lens.sh` · `die()` | **S2 (upstream error body)**, S6, S9 | **sanitized** — chokepoint | `gateway error body: the upstream message …` |
| `lens.sh` · `tmpwork` / `need_jq` / `usage` | — | **fixed string** | — |
| `launch.sh` · `say()` | S4, S6, S9 | **sanitized** — chokepoint | `a non-numeric context_window …` |
| `launch.sh` · `die()` | S6, S7, S9 | **sanitized** — chokepoint | `argv:` …, `KTD5 grammar: a session id …` |
| `launch.sh` · seed-run stderr tail | **S1** | **sanitized** — `gateway::sanitize_stream` | `seed-run stderr tail: a poisoned child stderr …` |
| `launch.sh` · `tmpwork` / `need_jq` / `usage` | — | **fixed string** | — |

### Sinks, part 2 — the one JSON object on stdout

Each script writes exactly one JSON object through its own `emit()` (KTD2). The
object is a mixed channel, so the disposition is **per field**, not per script:

| Field | Script | Source | Disposition | Test |
|---|---|---|---|---|
| `text`, `output_file` contents | lens | S1 | **RAW BY DESIGN** — data, not display. JSON escapes the bytes in transit and a consumer gets them back on parse; KTD5 assigns that sink to the consumer, and `skills/lens/SKILL.md` says so. Stripping here would corrupt legitimate code blocks in a review answer. | `model prose: the JSON text field keeps the bytes as data …` |
| `error`, `detail` | all three | S2, S6, S9 | **sanitized** in `die()` / `emit_error()` | `gateway error body: …`, `argv: …` |
| `alias` (success paths) | all three | S6 | **closed by grammar** — `validate_alias` ran first | `KTD5 grammar:` ×3 |
| `alias` (error paths) | lens, launch | S6 | **sanitized** — this is the one path where the alias may be one the grammar *refused*; jq escapes a control byte but emits a bidi override literally | `KTD5 grammar: lens refuses an escape-laden alias …` |
| `served_aliases` | gatewayctl | S5 | **sanitized** at the probe, where the list enters. A grammar-valid alias is byte-identical through the sanitizer, so the `ensure` membership check that exit 4 depends on is unaffected. | `served alias list: escape bytes off the wire …` |
| `models[]` (`alias`, `source`, `model`) | gatewayctl | S4 | **sanitized** — display-only; this is the promise `skills/status/SKILL.md` already makes | `config-derived display text: …` |
| `drift.*` (`missing_from_table`, `model_drift.recorded`/`.current`) | gatewayctl | S3, S4, S5 | **sanitized**, and the `CONFIG_MODELS_JSON` it reads is built with `jq` so a poisoned config cannot produce invalid JSON either | `config-derived display text: …` |
| `install_dir_error` | gatewayctl | S9 | **sanitized** — display-only prose | `gateway log tail:` (same `say`/`die` chokepoint) |
| `actual_argv` (stop, pid mismatch) | gatewayctl | S8 | **sanitized** — another process's command line, printed by whoever is diagnosing | (chokepoint-level; covered by the `argv:` sanitize tests and the lint) |
| `verb` in the **no-jq** fallback line | gatewayctl | S6 | **closed by construction** — reduced in pure bash to the verb enum's charset, because with no jq there is no encoder and a quote would break the object | (structural; enforced by reading — see *Known limits*) |
| `session_id`, `transcript_path`, `attach_command` | launch | S7 | **closed by grammar** — the session id is held to `[A-Za-z0-9._-]+`; the path and the attach command are derived from it plus shell-quoted values | `KTD5 grammar: a session id that fails the grammar …` |
| `base_url`, `config`, `log`, `pidfile`, `install_dir`, `binary`, `cwd`, `output_file` path, `pid`, `context_window` | all three | S9, S4 | **RAW BY DESIGN — functional, not display.** `lens.sh` and `launch.sh` *parse* `.base_url` and `.config` back out to build the request and read the token; sanitizing a path or a URL would silently corrupt a value the plugin itself consumes. They are also caller-supplied (`GATEWAY_*` env, `--cwd`), so the threat model is self-shoot, not a hostile third party. Two of them are nonetheless closed by construction anyway: `pid` is digit-filtered by `read_pidfile`, and `context_window` is constrained to digits before it is used or printed. | `a non-numeric context_window …` |

One re-entrant path was checked and is not a sink: `gatewayctl.sh restart`
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
  `gateway::sanitize_stream` for a file), and adding a row here.

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
