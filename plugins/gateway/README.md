# gateway

Run Claude on any model the local Superagent Gateway serves — headlessly for
skills that need a different-vendor answer (`lib/lens.sh`), or as an attachable
session (`lib/launch.sh`), over a control layer that owns liveness and startup
(`lib/gatewayctl.sh`).

> The rest of this README — install, the two surfaces, the exit-code contract by
> citation, and the settings allowlist entry — is written in U7. What follows is
> the terminal-escape audit from U6, which U7 keeps in place.

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
