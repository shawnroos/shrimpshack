---
title: "feat: claude-modes V2 — Modal Harness (SUPERSEDED)"
type: feat
status: superseded
date: 2026-05-17
origin: docs/brainstorms/2026-05-17-v2-modal-harness-requirements.md
superseded_by: docs/plans/2026-05-18-001-feat-modal-harness-v2-plan.md
superseded_date: 2026-05-18
superseded_reason: |
  Original plan assumed a single-overlay-per-machine mechanism. User raised two structural concerns post-plan-review (2026-05-18):
  (1) hooks/permissions/MCP servers that apply "across all modes" had nowhere to live except inside every mode YAML — duplication.
  (2) A single user-global .live-settings.json couldn't represent two repos in different modes simultaneously without race-condition workarounds.
  Brainstorm was updated with a cascading configuration model (5 tiers in V2.0; V2.1 adds tier 5). New plan adopts the cascade architecture.
---

# claude-modes V2 — Modal Harness

## Overview

V2 of the claude-modes plugin pivots from V1's parasitic PreToolUse block-after-attempt to "modes are settings files." `/mode:set` rewrites a narrow set of plugin-owned keys in `~/.claude/modes/.live-settings.json` from the active mode's YAML; the harness reshapes its catalog on `/reload-plugins` instead of intercepting tool dispatch. V1 substrate (audit log, slugify_branch, Python YAML safety pattern, statusline, test harness with `$HOME` isolation) carries forward verbatim where applicable. The five genuinely new mechanisms — atomic merge with preserve-the-rest semantics (R5), `flock`-serialized worktree reconciliation (R27), `realpath` path-traversal validation (R7), drift-aware uninstall (R17), and PostToolUse Write adoption consent (R20) — get test-first treatment because the failure modes are silent and security-sensitive.

V1 is archived at git tag `v0.1.0-experiment`. V2 ships as a fresh rebuild from current main (commit `e36d81f` U1 scaffold). The 28 requirements in the origin brainstorm are organized into 13 implementation units across 3 phases.

---

## Problem Frame

Claude Code exposes a single flat descriptor surface to the model. Plugin descriptors compete for the same context budget; `/doctor` warns at ~200 agents and Shawn hit 278 on this machine. V1's parasitic gate could deny *dispatch* but not *visibility* — users saw 278 agents in `/help` even when a restrictive mode unmounted most of them. V2's premise: modes are settings.json overlays. `/mode:set` rewrites which plugins are loaded; the catalog actually shrinks at the harness level when the user runs `/reload-plugins`.

V2 also positions the plugin as marketplace-ready (a stranger-adopter persona is in the origin's A3): byte-identical uninstall round-trip, restrictive permissions on settings-derived files, and a published README with a "How V2 handles your files" section are first-class requirements.

(see origin: docs/brainstorms/2026-05-17-v2-modal-harness-requirements.md, Problem Frame)

---

## Requirements Trace

This plan implements all 28 requirements from the origin brainstorm. Each implementation unit cites the R-IDs it advances.

**Core mode mechanism:** R1, R2, R5, R6, R8, R14 — implemented across U2, U3, U4, U5, U12.
**User catalog:** R3, R4, R7, R20 — implemented across U6, U8, U11.
**Plugin catalog:** R11, R22, R28 — implemented across U3, U4, U12.
**Safety, reversibility, uninstall:** R12, R13, R17, R18, R21, R24 — implemented across U6, U7, U13.
**Conversational authoring:** R10, R15 — implemented in U12.
**Schema and migration:** R9 — implemented across U3, U6.
**Observability:** R16, R23 — R16 in U13 (statusline carry-forward); R23 deferred to V2.1 per origin.
**Distribution and adoption:** R19 — implemented in U13.
**Hooks and reconciliation (new in V2):** R25, R26, R27 — implemented across U5, U9, U10.

**Origin actors:** A1 (mode user, Shawn V0), A2 (mode author), A3 (hypothetical stranger adopter), A4 (Claude the model), A5 (Claude Code the harness), A6 (Anthropic).
**Origin flows:** F1 (first-time install — U6, U8), F2 (set a mode — U5, U8, U9), F3 (author a new mode — U12), F4 (return to Claude Mode — U5), F5 (uninstall — U7).
**Origin acceptance examples:** AE1 (covers R3, R12, R17 — U6, U7, U13), AE2 (covers R2, R8 — U3, U5), AE3 (covers R5, R7, R11 — U4, U8), AE4 (covers R13, R17 — U7, U13 lint), AE5 (covers R22 — U4, U12), AE6 a/b/c (covers R20 — U11). AE7 removed per origin (R23 deferred to V2.1).

---

## Scope Boundaries

### Deferred for later

Carried verbatim from the origin requirements doc (V2.1+ candidates):

- Snapshot mode capture (`/mode:snapshot` — bake current settings into a new mode YAML)
- Compositional modes (stacking — `discovery + oncall` overlay)
- Mode inheritance
- Per-mode hook overrides (re-considering R28 when a demonstrated use case appears)
- Convention-driven mode inference (auto-suggest based on branch-name patterns)
- Usage telemetry / coverage weighting
- Shared / team-level mode definitions
- Mount/unmount semantics for individual agents within an enabled plugin
- `/mode:rollback` first-class slash command
- Auto-reload on settings file change
- Per-mode color in statusline (V2 inherits yellow-only)
- R23 drift detection in `/mode:status` (live vs YAML mismatch surfacing)
- User-catalog manifest glob patterns (V2.0 ships filename-list only)

### Outside this product's identity

Carried verbatim from the origin requirements doc:

- Not a workflow enforcement engine (modes shape the harness, don't enforce branch state, gate merges, or validate PR shape)
- Not a plugin manager (V2 reads `enabledPlugins`, doesn't install/version/update plugins)
- Not a memory or personalization system
- Not a state machine for project lifecycle (discovery → delivery is one mode-pair example, not the system's identity)
- Not multi-user or multi-tenant (single-user-per-install assumption)
- Not a replacement for skills
- Not a way to write to third-party plugin files (V1's R19 invariant carries forward, generalized to "no destructive verbs on user paths")

### Deferred to Follow-Up Work

V2.0 is shipped in a single PR off `feat/modes-v2`. No work is intentionally split across other repos. The post-publication marketplace name resolution for R22 (see Q2 in Open Questions) is the only deferred-to-publication item.

---

## Context & Research

### Relevant Code and Patterns

V1 substrate is at git tag `v0.1.0-experiment`. Access via `git show v0.1.0-experiment:<path>`. Carry-forward references:

- `lib/set-mode.sh` — V1's ordered-execution skeleton for `/mode:set`. U5 extends with R26 idempotent sentinel + R27 flock acquisition.
- `lib/validate-mode-name.sh` — `claude_modes::validate_name` (allowlist, reserved tokens, length, path-traversal) + `claude_modes::slugify_branch` (LC_ALL=C tr → collapse → strip → reject empty/dot-traversal). Carry verbatim; reserved-token list extends with `claude` (the Claude Mode baseline name).
- `lib/mode-yaml.sh` — `__claude_modes::py_yaml_query`, `resolve_mode_file`, `validate_schema_version`, `get_field`. The argv-not-interpolation Python contract is the load-bearing security pattern; carry verbatim except update validator to accept `schema_version: 2`.
- `lib/audit.sh` — append-only audit log writer with umask-on-create + chmod-on-append + sanitize-tabs-and-newlines + truncate-reason-to-200-chars pattern. U7 (uninstall events) + U5 (swap events) + U11 (adoption events) append.
- `lib/write-mode-yaml.sh` — mechanical-validation-before-mutation pattern. U12's mode-author skill routes writes through a V2-equivalent.
- `lib/inject-heuristic.sh` + `scripts/on-prompt-submit.sh` — V1's UserPromptSubmit consumer with stdin-JSON extraction. U10 (R25 prose injection) carries forward unchanged in shape.
- `scripts/on-session-start.sh` — contract-anchor-to-file + 7d marker pruning pattern. U9 (R27 worktree reconciliation) and U11 (R20 SessionStart scan) attach here.
- `scripts/statusline.sh` + `install-statusline.sh` + `uninstall-statusline.sh` — yellow segment + OSC 2 title pattern. U13 R16 carries forward verbatim.
- `.claude/skills/mode-author/SKILL.md` — V1's 7-phase conversational flow. U12 extends Phase 2.5 to ask which axes the mode shapes (plugin catalog / user catalog / context injection / none).
- `tests/helpers/test-helpers.sh` — `$HOME` isolation contract + macOS PYTHONPATH leak escape hatch. EVERY V2 integration test inherits this.
- `tests/run.sh` — isolation verification via hash-before-vs-after. Keep verbatim.
- `tests/integration/r19-lint.test.sh` — positive+negative fixture lint pattern. U13's `tests/integration/no-destructive-rm.test.sh` inherits the shape.
- `tests/integration/perf.test.sh` — Python `time.perf_counter_ns` measurement pattern. U9's flock-acquire path needs a baseline under this shape.

### Institutional Learnings

- `Slate/plugins/docs/solutions/architecture-patterns/silent-failure-when-singleton-assumption-breaks-2026-05-09.md` — Canonical `flock(2)` on `O_CREAT|O_RDWR` (never `rm`) pattern with `os.execvp` to bridge held FDs across process boundaries. U9 (R27 worktree reconciliation) adopts verbatim.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_slash_command_arg_substitution.md` — Slash-command `.md` bodies pre-substitute `$0/$1/$ARGUMENTS` before bash runs. **Every** V2 slash command (`/mode:set`, `/mode:adopt`, `/mode:status`, `/mode:setup`, `/mode:registry`, `/mode:statusline`) MUST follow the convention: `.md` body is prose + a single-line `"${CLAUDE_PLUGIN_ROOT}/lib/<verb>.sh" "$ARGUMENTS"` invocation; all `$`-bearing logic lives in `lib/*.sh`. See Key Technical Decisions.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_predicted_bugs_need_tests_not_conventions.md` — Test fixtures named in the brainstorm (R7 symlink-path-traversal, R24 settings-file-perms, R26 mode-set-crash-recovery, R27 worktree-mode-reconciliation, R17 install-uninstall-roundtrip) are non-negotiable per-unit verification artifacts. They may not be downgraded to "convention-enforced" during the code-review loop.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_deterministic_over_probabilistic_v1.md` — V2's load-bearing enforcements MUST be mechanical, not probabilistic. R7's realpath check, R22's `/mode:set`-time validation, R24's 0600 invariant, R26's sentinel-driven recovery — each must be enforced by code, not by convention or comment.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_subagent_write_verification.md` — When ce-work fans implementation units to subagents, every install/uninstall integration test must read back the filesystem (`stat`, `readlink`, `sha256`) after the operation, not trust agent self-reports.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_ce_worktree_no_remote.md` — `claude-modes` is local-only (no git remote). Parallel subagent dispatch during V2 build must downgrade to shared-directory mode with no-stage/no-commit constraints; orchestrator handles staging post-batch.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_review_loop_catches_narrowing.md` — V2 PR must loop on `/ce-code-review` until verdict is green. Single-pass review misses narrowed-not-closed bugs, especially in symlink-rebuild and JSON-merge paths.

### External References

None used. Local research surfaced sufficient direct examples for every pattern.

---

## Key Technical Decisions

- **`/mode:set` performs parse → mutate → atomic write on settings.json.** Read the current live settings via Python `json.load`, mutate the plugin-owned-keys subset from the mode YAML's `mechanism:` section, write to `~/.claude/modes/.live-settings.json.tmp.<pid>` with `chmod 0600` (or `umask 077` in the writing context) **before** first write, then `os.rename` (`mv`) atomically into place. Same-filesystem `mv` is atomic on APFS. **Never** mutate textually. Rationale: avoids the edit-block-replacement-boundaries bug class; gives crash safety without WAL-style journaling; preserves non-plugin-owned keys verbatim.

- **Slash-command argument substitution: `.md` body holds NO `$`-bearing bash.** Per `feedback_slash_command_arg_substitution`. Every V2 slash command `.md` file MUST contain only prose plus a single-line `"${CLAUDE_PLUGIN_ROOT}/lib/<verb>.sh" "$ARGUMENTS"` invocation (or equivalent positional pass-through). All `$1`, `$@`, `${var:-default}` logic lives in `lib/*.sh`. **Smoke-test every command with real arguments before declaring the unit done.**

- **Plugin-owned settings.json keys (V2.0): `enabledPlugins`, `env`, `permissions`, `mcpServers`.** `hooks` is explicitly NOT plugin-owned (R28 — prevents hooks-injection via shared YAML). The reload-semantics matrix in U1 may scope this set further: rows that fail empirical verification get dropped from V2.0 and deferred to V2.0.x dot-releases.

- **`hooks` are the plugin's own concern, not modes'.** The plugin registers `~/.claude/plugins/claude-modes/.claude/hooks/hooks.json` with PostToolUse (Write matcher), UserPromptSubmit, and SessionStart. PreToolUse is dropped from V1. Mode YAMLs cannot add, remove, or modify hooks.

- **Path-traversal validation via `realpath`, mechanically enforced.** Per R7. Every symlink target the plugin creates is resolved via `realpath` (or `python3 -c 'import os; print(os.path.realpath(sys.argv[1]))'` for macOS-Linux portability) and asserted to be a descendant of `~/.claude/modes/.user-catalog/` before the symlink is created. A user-catalog manifest entry containing `..` or any path-traversal MUST fail validation. This is the load-bearing security mechanism for the symlink mechanism — comment-only or convention-only mitigations are not acceptable.

- **0600 permissions on every settings-derived file write, not just on creation.** Per R24 + V1's audit log pattern (`rel-101` / `sec-004`). Prefer the **born-at-0600** pattern (`(umask 077 && mktemp ... && write ... && mv ...)`) over retroactive chmod — eliminates the TOCTOU window between write and chmod. Where retroactive chmod is unavoidable (appends to existing files like audit.log), re-assert chmod 0600 after every append — symlinks excepted (macOS `chmod` does not honor `-h`; check `[ ! -L "$path" ]` first). **Chmod failure is fail-closed** (per adversarial F4): if `chmod 0600` exits non-zero (e.g., network FS that doesn't support chmod, ACL conflict), the write is considered FAILED — the plugin rolls back the mv if possible (atomic rename to `.0600-failed.<pid>` tmp, surface error to user, exit non-zero), audits the failure with explicit severity, and refuses to proceed. The R24 invariant is load-bearing for the README's safety claim; a silent fail-open would breach it. Test scenario: simulate chmod failure via a fault-injection wrapper; assert the operation exits non-zero and the audit log records the failure.

- **`/mode:set` idempotent re-apply with sentinel-driven recovery.** Per R26. The swap builds target state from the mode YAML alone, never depending on previous state. Plugin writes `~/.claude/modes/.mode-set.in-progress` before any mutation; clears on success. Subsequent `/mode:set` or `/mode:status` detects orphaned sentinel and re-applies idempotently.

- **Worktree reconciliation via SessionStart + flock + no-op fast path + divergence toast.** Per R27. SessionStart hook acquires `flock(2)` on `~/.claude/modes/.symlink-lock` (open with `O_CREAT|O_RDWR`, never `rm` — see slate-weekly-gist canonical pattern), compares current symlink set to target via cheap `readlink` enumerate, skips rebuild if match (same-mode concurrent worktrees → zero contention), rebuilds otherwise. If session's recorded branch-mode differs from active symlink set's target (concurrent worktree set a different mode), R25's UserPromptSubmit hook fires a one-time divergence toast. Modes are per-branch in intent, per-machine in mechanism.

- **Drift-aware uninstall.** Per R17. `scripts/unmodes.sh` diffs `~/.claude/settings.json.pristine` vs current live settings before overwriting; if non-plugin-owned keys diverged, prompts `preserve these post-install changes? [Y/n]` (default Y). On Y → only the plugin-owned subset is restored from pristine; non-owned keys keep current values. On N → byte-identical full restore (the original claim). Two-branch round-trip test covers both paths.

- **V1 mode YAMLs (`schema_version: 1`) are archived, not migrated.** Per R9. On V2 install (`/mode:setup`), if any `~/.claude/modes/*.yaml` has `schema_version: 1`, move them to `~/.claude/modes/.v1-archive/` and emit a one-time `<system-reminder>` directing the user to re-author via `/mode:registry`. The V1 mechanism is incompatible enough with V2's that translation would mostly invent intent.

- **YAML schema design: human-readable, parse-only via `yaml.safe_load`.** Per V1 mode-yaml.sh substrate. NEVER bare `yaml.load`. Every YAML read passes through `__claude_modes::py_yaml_query` (or its V2 successor) which routes untrusted strings via `sys.argv`, never shell interpolation. Closes the `sec-001` RCE pattern V1 fixed.

- **Test posture: test-first for new security mechanisms.** U4 (R5 merge engine with R28 constraint), U7 (R17 drift-aware uninstall), U8 (R7 path-traversal), U9 (R27 flock race), U11 (R20 adoption). Per `feedback_predicted_bugs_need_tests_not_conventions` — fixtures must be written before the mitigation, with both positive (attack succeeds without the mitigation) and negative (attack fails with the mitigation) cases.

---

## Open Questions

### Resolved During Planning

- **Q1: schema_version 1 vs 2 collision on V2 install.** Resolved: V2 archives V1 YAMLs to `~/.claude/modes/.v1-archive/` and emits a one-time `<system-reminder>` directing the user to re-author via `/mode:registry`. No automatic migration (per origin's "V1 is archived, not migrated" Key Decision).
- **Q2: marketplace identifier format for R22 self-check (pre-publication).** Resolved with three-tier strategy: (1) post-publication, the canonical `claude-modes@<official-marketplace>` is hardcoded once known; (2) development / private installs where `installed_plugins.json` lists the plugin: parse it and match the key whose `realpath(installPath)` equals `realpath(CLAUDE_PLUGIN_ROOT)`; (3) fallback for first-run installs where `installed_plugins.json` doesn't yet list claude-modes (or is missing entirely): synthesize the identifier as `claude-modes@local-dev`. This synthetic identifier is written into claude.yaml's enabledPlugins during /mode:setup; once the user installs via marketplace and `installed_plugins.json` updates, /mode:setup-or-/mode:registry detects the mismatch and offers to rewrite affected mode YAMLs with the canonical identifier. If multiple installs of claude-modes exist (e.g., dev install + marketplace install), the lookup is ambiguous; U6 emits a one-time warning and uses the first match by `realpath(installPath)` order, deterministic across runs.
- **Q3: user-catalog manifest YAML shape.** Resolved: filename list for V2.0; globs are V2.1 extension. Shape: `user_catalog: { commands: [str], agents: [str] }`. Matches scope-guardian's "smallest mechanism that V2.0 thesis depends on."
- **Q5: detached HEAD / no-branch / no-repo behavior for R6+R27.** Resolved: detached HEAD slugs to `detached-<short-sha>`; no-repo falls back to "active mode is user-global, no per-branch record"; R27 reconciliation hook degrades gracefully via `git -C "$PWD" symbolic-ref HEAD 2>/dev/null` guard.
- **R20 PostToolUse-on-editor-writes empirical verification (origin gate 2).** Resolved during doc-review: architectural inference confirms PostToolUse matchers fire on tool dispatch, not filesystem events. External editor writes are invisible to hooks. R20 ships with three paths: manual `/mode:adopt <file>` (load-bearing), PostToolUse for Claude-tool writes (immediate UX), SessionStart-scan for editor writes (catches the majority case).
- **Multi-worktree user-catalog architecture (origin gate 1).** Resolved during doc-review: SessionStart hook + flock + no-op fast path + divergence toast. Modes are per-branch in intent, per-machine in mechanism (see R27).
- **Hooks-injection threat model (origin gate 3).** Resolved during doc-review: `hooks` are not plugin-owned in V2.0 (R28). `permissions` gets a diff/confirm gate on `/mode:set`.

### Deferred to Implementation

**Original planning-time deferrals:**

- **Q4: Can `/reload-plugins` be programmatically triggered from a hook/script, or is it strictly user-typed?** Empirically deferred — U1's reload-semantics matrix surfaces this. If yes, `/mode:set` invokes it (silent flow); if no, signals user with `claude-modes: mode set to <X> — run /reload-plugins to apply` (current default).
- **Exact API for parsing `installed_plugins.json` to resolve R22 self-identification pre-publication.** U4's R22 enforcement step; depends on installed_plugins.json shape being stable (currently `{version: 2, plugins: Record<name@marketplace, [{installPath, ...}]>}`). If shape changes pre-publication, U4 may need a fallback.
- **Exact UX for the divergence toast (R27).** U9 implements via R25's UserPromptSubmit `<system-reminder>` injection. Final wording lands during U9 testing; the toast must mention current symlink-set mode, branch-recorded mode, and the command to align (`/mode:set <branch-mode>`).
- **Whether `/mode:status` reports drift between live settings and active mode YAML in V2.0.** Per R23, drift detection deferred to V2.1. U12's `/mode:status` reports active mode + plugin catalog + user catalog only.

**Surfaced by plan-doc-review (2026-05-17). P2 — significant decisions for implementer to settle:**

- [Affects U4][coherence F6] `env` replace-vs-merge semantics. Plan currently states wholesale replacement (`live_new.env = mode.mechanism.env`) and the test scenario confirms. If a user's pre-install env had `{DATABASE_URL: ...}` and a mode adds `{FOO: bar}`, the user loses DATABASE_URL on `/mode:set`. Decide during implementation whether to (a) keep wholesale replacement (simplest; mode owns the env namespace; users should declare their full env in claude.yaml) or (b) shallow-merge env keys (`{**live.env, **mode.env}`) and document. The plan's preserve-the-rest framing argues for (b) but consistency with permissions/mcpServers argues for (a).
- [Affects U11][coherence F8] Explicit TTY detection logic for PostToolUse Write consent. Plan says non-interactive defaults to N but the detection mechanism is unspecified. Use `[ -t 0 ]` (stdin TTY check) OR check `CLAUDE_NON_INTERACTIVE=1` env-var (set by CE fan-out wrappers). Pick during U11 implementation; document the heuristic in U11's narrative.
- [Affects audit log][security-lens F4, adversarial F11] Explicit audit log payload constraint. Plan inherits V1's audit log shape but doesn't state V2 constraint. Implementer MUST document: audit log records `{event, mode_name, timestamp, branch_slug, status}` — NEVER mechanism payload values (env values, mcpServer URLs, hook command lines, permission grants). Verify via test that stat-and-grep the audit log post-/mode:set for env value substrings.
- [Affects R17][security-lens F5] Stale-credential risk on uninstall-with-N path. Pristine captures env at install time; if user rotates credentials post-install, uninstall-with-N restores stale values. Implementer adds a warning to the uninstall-with-N prompt when pristine.env or pristine.mcpServers is non-empty: "Pristine contains credentials from install time. If you've rotated credentials since, update settings.json after uninstall."
- [Affects R27][adversarial F8] Divergence toast aggregation across N worktrees. With N worktrees in N modes, N concurrent toasts fire (one per session). UX worth surfacing as README "known behavior under heavy worktree use." V2.1 candidate: aggregate toasts within a short window, or suppress secondary toasts.
- [Affects U11][adversarial F9] Temp-file filter for PostToolUse. Hook currently fires for any file under `~/.claude/commands/*.md`. Files matching `.tmp-*`, `*.backup`, `.draft-*` should be filtered out. Implementer adds pattern exclusion to U11's path-filter step.
- [Affects U7][adversarial F11] Audit log forensics gap post-uninstall. uninstall deletes `~/.claude/modes/` including the audit log. No surviving record of install → use → uninstall lifecycle. Implementer adds option: preserve `~/.claude/modes/.audit.log` as `~/.claude/.claude-modes-uninstall.log` before final rm (with explicit R12-exception comment in unmodes.sh).
- [Affects U4][adversarial F5] Concurrent third-party plugin write to settings.json. V2 assumes claude-modes is the sole writer of settings.json. Document this assumption in README + docs/architecture.md. V2.1 candidate: file-lock around the read-mutate-write window (could share R27's `.symlink-lock` semantics).

**Surfaced by plan-doc-review (2026-05-17). P3 — clarifications:**

- [Affects Requirements Trace][coherence F3] R6 (per-branch state file) is credited only to U5 (writer); the reader is U9 (R27 reconciliation). Update Requirements Trace to credit both: "R6 — U5 writes, U9 reads."
- [Affects all V1 substrate references][coherence F11] Pre-flight check that git tag `v0.1.0-experiment` is accessible. Add to U1 (or a separate pre-implementation verification step): `git show v0.1.0-experiment:lib/mode-yaml.sh > /dev/null` succeeds; if tag missing, halt and surface to Shawn.
- [Affects R7 + U6][adversarial F12] Parent-directory symlink case. If `~/.claude/commands/` itself is a symlink (whole-directory pointed at a vault), U6's mv resolves through. U6 step 1 (presence check) adds: `[ -L "$HOME/.claude/commands" ] && fail "parent dir is a symlink — unsupported; use individual file symlinks instead"`.
- [Affects AE5][coherence F7] R22 error message wording. AE5 prescribes the exact text; U4 + U3's enforcement messages should match (or note that AE5 illustrates the spirit, with implementation choosing equivalent wording).

---

## Output Structure

```text
claude-modes/
├── .claude-plugin/
│   └── plugin.json                         # U2 (bump to 0.2.0, drop V1 description)
├── .claude/
│   ├── hooks/
│   │   └── hooks.json                      # U2 (drop PreToolUse, add PostToolUse Write)
│   └── skills/
│       └── mode-author/
│           └── SKILL.md                    # U12 (extend Phase 2.5 for axes question)
├── lib/
│   ├── audit.sh                            # carry from v0.1.0-experiment
│   ├── validate-mode-name.sh               # carry verbatim (reserve "claude")
│   ├── mode-yaml.sh                        # U3 (update validator to schema_version: 2)
│   ├── write-mode-yaml.sh                  # U3 (V2 mechanism layer validation)
│   ├── set-mode.sh                         # U5 (R26 sentinel + R27 flock acquisition)
│   ├── active-mode.sh                      # U5 (extend for R6 per-branch state)
│   ├── live-settings-merge.sh              # U4 NEW — atomic merge engine (R5 + R28)
│   ├── live-settings-merge.py              # U4 NEW — Python helper for parse/mutate
│   ├── symlink-rebuild.sh                  # U8 NEW — user-catalog symlink mechanism
│   ├── symlink-validate.py                 # U8 NEW — realpath path-traversal check (R7)
│   ├── adopt-file.sh                       # U11 NEW — /mode:adopt mechanism
│   ├── drift-diff.sh                       # U7 NEW — uninstall drift diff (R17)
│   ├── status.sh                           # U12 NEW — /mode:status mechanism
│   ├── registry.sh                         # U12 NEW — /mode:registry mechanism
│   └── statusline-dispatcher.sh            # carry from v0.1.0-experiment
├── scripts/
│   ├── on-pre-tool-use.sh                  # U2 (delete; replaced by PostToolUse)
│   ├── on-post-tool-use.sh                 # U2 NEW — Write matcher consent (R20)
│   ├── on-prompt-submit.sh                 # U10 (extend for R25 prose injection)
│   ├── on-session-start.sh                 # U9 + U11 (R27 reconciliation + R20 scan)
│   ├── setup.sh                            # U6 NEW — /mode:setup install wizard
│   ├── unmodes.sh                          # U7 NEW — drift-aware uninstall
│   ├── restore-claude-modes.sh             # U7 NEW — R22 wedge recovery
│   ├── statusline.sh                       # carry verbatim from v0.1.0-experiment
│   ├── install-statusline.sh               # carry from v0.1.0-experiment
│   └── uninstall-statusline.sh             # carry from v0.1.0-experiment
├── commands/
│   ├── set.md                              # U5 — /mode:set
│   ├── status.md                           # U12 — /mode:status
│   ├── setup.md                            # U6 — /mode:setup
│   ├── adopt.md                            # U11 — /mode:adopt
│   ├── registry.md                         # U12 — /mode:registry
│   └── statusline.md                       # carry from v0.1.0-experiment
├── examples/
│   ├── example-discovery.yaml              # U3 (bump to schema_version: 2, add mechanism layer)
│   └── example-delivery.yaml               # U3 (bump to schema_version: 2, add mechanism layer)
├── tests/
│   ├── run.sh                              # carry verbatim
│   ├── helpers/
│   │   └── test-helpers.sh                 # carry verbatim ($HOME isolation + PYTHONPATH leak)
│   ├── unit/
│   │   ├── live-settings-merge.test.sh     # U4
│   │   ├── symlink-validate.test.sh        # U8
│   │   ├── drift-diff.test.sh              # U7
│   │   └── schema-version.test.sh          # U3
│   └── integration/
│       ├── install-uninstall-roundtrip.test.sh  # U6, U7 — clean + drifted branches
│       ├── symlink-path-traversal.test.sh       # U8 — R7 attack fixtures
│       ├── settings-file-perms.test.sh          # U13 — R24 0600 invariant
│       ├── mode-set-crash-recovery.test.sh      # U5 — R26 idempotency
│       ├── worktree-mode-reconciliation.test.sh # U9 — R27 same-mode/diff-mode/branch-checkout
│       ├── mode-adopt.test.sh                   # U11 — R20 a/b/c paths
│       ├── prose-injection.test.sh              # U10 — R25 systemMessage shape
│       ├── no-destructive-rm.test.sh            # U13 — R13 lint (positive + negative fixtures)
│       ├── r22-self-enforcement.test.sh         # U4 — R22 write-time + /mode:set-time
│       ├── perf.test.sh                         # carry + extend with flock-acquire baseline
│       └── r19-lint.test.sh                     # extend lint to V2 paths
├── docs/
│   ├── brainstorms/
│   │   ├── 2026-05-15-modes-as-infrastructure-requirements.md  # V1 origin (carry)
│   │   └── 2026-05-17-v2-modal-harness-requirements.md         # V2 origin (carry)
│   ├── plans/
│   │   ├── 2026-05-15-001-feat-modes-as-infrastructure-plan.md # V1 plan (carry)
│   │   ├── 2026-05-17-001-feat-modal-harness-v2-plan.md        # this plan
│   │   └── 2026-05-XX-reload-matrix-results.md                 # U1 — empirical matrix
│   ├── architecture.md                     # U13 NEW — V2 hook surface table
│   └── solutions/                          # U13 NEW — seed for institutional learnings
└── README.md                               # U13 NEW — brisk install + uninstall + safety section
```

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**The `/mode:set` data flow (U4 + U5):**

```text
/mode:set delivery
  │
  ├─ acquire flock(~/.claude/modes/.symlink-lock, LOCK_EX)
  ├─ write ~/.claude/modes/.mode-set.in-progress sentinel
  │
  ├─ validate name (R-validate-name carry: allowlist + reserved tokens)
  ├─ resolve YAML: ~/.claude/modes/delivery.yaml
  ├─ validate schema_version == 2
  ├─ validate R22: enabledPlugins[<claude-modes-id>] truthy
  │
  ├─ load live: ~/.claude/modes/.live-settings.json
  ├─ extract mode mechanism: {enabledPlugins, env, permissions, mcpServers}
  ├─ permissions diff vs current → if additive, prompt [y/N]
  │
  ├─ merge: live ∖ plugin-owned-keys ∪ mode mechanism
  ├─ atomic write: tmp = mktemp(0600) → write JSON → mv tmp live
  ├─ symlink-rebuild: enumerate manifest → realpath-validate each → rebuild ~/.claude/commands + ~/.claude/agents
  ├─ write per-branch state: <repo>/.claude/modes/<slug>.mode
  │
  ├─ audit: append swap event
  ├─ clear sentinel
  ├─ release flock
  │
  └─ signal user: "mode set to delivery — run /reload-plugins to apply"
       (or invoke /reload-plugins programmatically if U1 matrix confirms it's possible)
```

**The merge contract (U4):**

```text
live_new = {
  k: mode.mechanism[k] for k in PLUGIN_OWNED_KEYS_V2 if k in mode.mechanism,
  **{k: live[k] for k in live if k not in PLUGIN_OWNED_KEYS_V2}
}
where PLUGIN_OWNED_KEYS_V2 = ["enabledPlugins", "env", "permissions", "mcpServers"]
                              # hooks NOT in set (R28); subject to U1 matrix
```

**Key invariants enforced mechanically:**

- `hooks` never appears in `PLUGIN_OWNED_KEYS_V2` → mode YAMLs cannot inject hooks (R28)
- Every symlink target passes `realpath` check before creation (R7)
- Every settings-derived write goes through atomic `mktemp + mv + chmod 0600` (R24)
- `/mode:set` is idempotent — re-running from any partial state converges (R26)
- `flock` serializes concurrent symlink rebuilds across worktrees (R27)

---

## Implementation Units

### Phase 1: Foundation

- U1. **Reload-semantics matrix (empirical, no V2 code yet)**

**Goal:** Execute the 7-row matrix from the origin's "Resolve Before Planning" → "/reload-plugins reload-semantics matrix — Day 1 of planning" before any V2 code is written. Determine empirically which plugin-owned keys remain in U4's merge engine.

**Requirements:** R5 (final plugin-owned set), R8 (reload-plugins semantics), "/doctor pressure dissolves" success criterion (model-context purge verification).

**Dependencies:** None.

**Files:**
- Create: `docs/plans/2026-05-XX-reload-matrix-results.md` (date filled at execution time)
- Reference: `docs/brainstorms/2026-05-17-v2-modal-harness-requirements.md` (matrix recipe section)

**Approach:**
- Run each matrix row in a fresh Claude Code session per the origin recipe
- Record `/doctor` counts before + after settings edits + after `/reload-plugins`
- Record whether MCP tool list updates without restart, whether new permissions take effect without restart, whether `/doctor` reads settings.json directly vs runtime state
- If Row 1 (enabledPlugins purges model-context descriptors in the SAME session) fails — surface to Shawn before continuing. That's V2's central thesis-test.
- Apply decision rules from the origin recipe: failing rows → drop the key from V2.0 plugin-owned set; restart-required rows → add restart-prompt UX to U4's merge step

**Execution note:** Pure empirical execution-time work — no code. Results are the artifact.

**Patterns to follow:**
- Origin doc's "Resolve Before Planning → reload-semantics matrix" section (Day-1 recipe with 7 rows)

**Test scenarios:** Test expectation: none — this unit produces an empirical results document, not feature-bearing code.

**Verification:**
- Create the results artifact at `docs/plans/2026-05-XX-reload-matrix-results.md` (date filled at execution time) with one row per matrix entry plus a "Decision summary: which keys stay in U4's PLUGIN_OWNED_KEYS_V2 list" section. This is the canonical artifact path; downstream units (U4 specifically) reference it for their plugin-owned-keys constant
- If row 7 reveals `/doctor` reads settings.json directly (not runtime state), V2 can skip `/reload-plugins` for the `/doctor`-pressure-dissolves criterion — surface to Shawn as a scope simplification opportunity

---

- U2. **Plugin manifest + hook registration restructure**

**Goal:** Restructure `.claude-plugin/plugin.json` and `.claude/hooks/hooks.json` for V2's hook surface. Drop V1's PreToolUse(Task|Skill|Agent). Add PostToolUse(Write). Keep UserPromptSubmit + SessionStart. Bump plugin version.

**Requirements:** R25, R27, R20, R28 (hooks-not-plugin-owned context).

**Dependencies:** None (U1 results don't change hook registration).

**Files:**
- Modify: `.claude-plugin/plugin.json` (bump version → 0.2.0, update description, add commands list `[set, status, setup, adopt, registry, statusline]`, hooks list reference unchanged)
- Modify: `.claude/hooks/hooks.json` (drop `PreToolUse` block; add `PostToolUse` block with matcher `Write`; keep `UserPromptSubmit` and `SessionStart`; all `timeout: 5`)
- Delete: `scripts/on-pre-tool-use.sh` (replaced by `scripts/on-post-tool-use.sh` in U11)

**Approach:**
- Hooks.json JSON shape mirrors `/Users/shawnroos/.claude/settings.json::hooks` structure: `{HookName: [{matcher?, hooks: [{type: "command", command: "bash ${CLAUDE_PLUGIN_ROOT}/scripts/...sh"}]}]}`
- PreToolUse deletion is the visible "V2 dropped block-after-attempt" signal
- PostToolUse Write matcher is registered now but the consumer script (`scripts/on-post-tool-use.sh`) is created in U11 with R20's logic — U2 just registers the matcher
- Version bump: 0.2.0 (V1 was 0.1.x at the tag)

**Patterns to follow:**
- V1's `.claude/hooks/hooks.json` at git tag v0.1.0-experiment for JSON shape
- Cost-of-being-installed gate (`[ -d "${HOME}/.claude/modes" ] || exit 0`) preserved in every hook shim

**Test scenarios:**
- Happy path: After commit, `jq '.PostToolUse[0].matcher' .claude/hooks/hooks.json` returns `"Write"`
- Happy path: `jq '.PreToolUse' .claude/hooks/hooks.json` returns `null` (key absent)
- Happy path: `jq '.UserPromptSubmit' .claude/hooks/hooks.json` returns non-null (key preserved)
- Integration: `bash -n .claude/hooks/*.sh 2>&1` produces no syntax errors for every hook script

**Verification:**
- `plugin.json` parses as valid JSON with `version: "0.2.0"`
- `hooks.json` parses as valid JSON with the V2 hook surface (no PreToolUse, has PostToolUse Write)
- `scripts/on-pre-tool-use.sh` is deleted (or empty placeholder noting deprecation)

---

- U3. **YAML schema v2 + validator + example modes**

**Goal:** Define the V2 mode YAML schema (mechanism layer + prose layer), update `lib/mode-yaml.sh`'s `validate_schema_version` to accept `2`, port the V1 example modes (discovery, delivery) to V2 shape.

**Requirements:** R1 (schema layers), R9 (schema_version: 2, reject unknown), R11 (enabledPlugins shape), R22 (claude-modes-must-be-present invariant).

**Dependencies:** None (parallel-safe with U2 once both touch separate file sets).

**Files:**
- Modify: `lib/mode-yaml.sh` (extract from v0.1.0-experiment tag, update `validate_schema_version` to accept `2`, extend `get_field` for `mechanism.enabledPlugins`, `mechanism.env`, `mechanism.permissions`, `mechanism.mcpServers`, `mechanism.user_catalog.commands`, `mechanism.user_catalog.agents`, plus prose fields `philosophy`, `scope`, `lens`, `constraints`, `command_heuristics`)
- Create: `lib/write-mode-yaml.sh` (V2 — validates mechanism block + user_catalog manifest shape + R22 claude-modes-present BEFORE atomic write)
- Modify: `examples/example-discovery.yaml` (bump to `schema_version: 2`, add `mechanism: {enabledPlugins: {...}, user_catalog: {commands: [], agents: []}}`, preserve prose layer)
- Modify: `examples/example-delivery.yaml` (same V2 shape)
- Create: `tests/unit/schema-version.test.sh` (validator unit tests)

**Approach:**
- Schema design (canonical V2 shape):
  ```yaml
  schema_version: 2
  name: example-delivery
  description: ...
  mechanism:
    enabledPlugins:
      "claude-modes@<marketplace>": true        # R22 invariant
      "compound-engineering@every-marketplace": true
    env: {}                                     # optional, plugin-owned
    permissions: {}                             # optional, diff/confirm on add
    mcpServers: {}                              # optional, subject to U1 matrix
    user_catalog:
      commands: ["strict-deploy.md"]            # filename list (V2.0 — globs are V2.1)
      agents: []
  philosophy: |
    [carried prose layer from V1]
  scope: |
    ...
  lens: |
    ...
  constraints: [...]
  command_heuristics: {...}
  ```
- `validate_schema_version` rejects any value except `2`; V1 (schema_version: 1) YAMLs are rejected with a clear error directing the user to `/mode:setup`'s archive path
- Python `yaml.safe_load` only (never `yaml.load`); untrusted strings passed via `sys.argv`, never shell-interpolated (V1 sec-001 pattern)
- `write-mode-yaml.sh` enforces R22 mechanically: refuses to write a mode YAML whose `mechanism.enabledPlugins[claude-modes@*]` is missing or set to `false`

**Execution note:** Test-first for the `write-mode-yaml.sh` R22 enforcement — write the failing test (YAML missing claude-modes → write refused with clear error) before the implementation.

**Patterns to follow:**
- V1's `lib/mode-yaml.sh::__claude_modes::py_yaml_query` (argv-not-interpolation contract — load-bearing for sec-001)
- V1's `lib/write-mode-yaml.sh` (mechanical validation before any filesystem mutation)
- `CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"` pin

**Test scenarios:**
- Happy path: `validate_schema_version` on `schema_version: 2` YAML returns 0
- Edge case: `validate_schema_version` on `schema_version: 1` returns non-zero with stderr matching `V1 mode YAML detected.*archive`
- Edge case: `validate_schema_version` on `schema_version: 3` (unknown future) returns non-zero with stderr matching `unknown schema_version`
- Edge case: Missing `schema_version` key returns non-zero
- Error path: Malformed YAML (`!!python/object` tag injection attempt) — `yaml.safe_load` rejects with `YAMLError`; never executes
- Error path: `mechanism.enabledPlugins` missing → get_field returns empty list cleanly
- Integration: `write-mode-yaml.sh` REFUSES a YAML without `claude-modes@*` in enabledPlugins; stderr matches `claude-modes must be enabled in every mode`
- Integration: `write-mode-yaml.sh` ACCEPTS a YAML with `claude-modes@dev-install: true`

**Verification:**
- `validate_schema_version` correctly accepts `2` and rejects everything else
- Example YAMLs at `examples/example-{discovery,delivery}.yaml` parse cleanly via `yaml.safe_load` and produce the expected mechanism + prose structure
- `lib/write-mode-yaml.sh` exits non-zero on R22 violations and zero on valid YAMLs
- All unit tests pass under `tests/run.sh`

---

### Phase 2: Core mechanism + user-catalog substrate

- U4. **Live-settings merge engine (R5 + R28)**

**Goal:** Implement the atomic parse → mutate → write engine that generates `~/.claude/modes/.live-settings.json` from a mode YAML's mechanism section + the current live settings. Enforce the V2 plugin-owned-keys set (subject to U1 matrix results). Enforce R28 (`hooks` never appears in the merge). Enforce R22 (claude-modes-must-be-present) at swap-time. Apply the permissions diff/confirm gate.

**Requirements:** R5 (atomic merge with preserve-the-rest), R11 (enabledPlugins control), R22 (claude-modes self-enforcement at /mode:set-time), R24 (0600 perms), R28 (hooks excluded).

**Dependencies:** U1 (matrix dictates final PLUGIN_OWNED_KEYS_V2 list); U3 (schema validator + mode YAML read).

**Files:**
- Create: `lib/live-settings-merge.sh` (orchestrator — calls Python helper, applies permissions diff gate, writes atomically)
- Create: `lib/live-settings-merge.py` (Python helper for JSON parse/mutate/serialize — argv contract, never shell interpolation)
- Create: `tests/unit/live-settings-merge.test.sh`
- Create: `tests/integration/r22-self-enforcement.test.sh`

**Approach:**
- Constant at the top of `live-settings-merge.py`: `PLUGIN_OWNED_KEYS_V2 = ["enabledPlugins", "env", "permissions", "mcpServers"]` (subject to U1 narrowing). `hooks` MUST NOT appear in this list. **Three-layer defense (per cross-persona finding cluster, R28):**
  1. **Static lint** (first line): `r19-lint.test.sh` greps for the literal string `"hooks"` in PLUGIN_OWNED_KEYS_V2's declaration. Catches the naive add.
  2. **Runtime assertion** (mechanical guarantee): immediately after the constant declaration, `assert "hooks" not in PLUGIN_OWNED_KEYS_V2, "R28: hooks must never be plugin-owned — see brainstorm Key Decisions"`. Fires at module import time, so EVERY merge engine invocation re-validates the invariant. Catches indirect adds (`HOOKS_KEY = "hooks"; PLUGIN_OWNED_KEYS_V2 = [..., HOOKS_KEY]`) that bypass the static lint.
  3. **Behavioral test** (end-to-end guarantee): U4 test scenario "Edge case (R28): Mode YAML with `mechanism.hooks: {...}` → hooks key is IGNORED in live_new" verifies that even IF the assertion was bypassed, the merge logic itself doesn't apply hooks. Defense in depth.
- Read live JSON via `json.load(open(live_path))` (defaults to empty dict if missing — first-install case)
- Read mode YAML via the U3 reader; extract `mechanism` block
- Build `live_new = {k: live[k] for k in live if k not in PLUGIN_OWNED_KEYS_V2} | {k: mechanism[k] for k in mechanism if k in PLUGIN_OWNED_KEYS_V2}`
- Preserve `statusLine`, `worktree`, `plugins`, etc. — non-plugin-owned keys verbatim
- Treat `mcpServers` absence in live as legitimate (don't fill from mode YAML if user has none)
- R22 enforcement at swap-time: before write, assert `live_new["enabledPlugins"][CLAUDE_MODES_ID]` is truthy where CLAUDE_MODES_ID resolves per Q2 (installPath-match against `~/.claude/plugins/installed_plugins.json`)
- Permissions diff gate: before write, diff `live.get("permissions", {})` vs `live_new["permissions"]`; if any permission is added that wasn't in the previous mode, surface named diff + prompt `add these permissions on swap? [y/N]` (default N — safer)
- Atomic write: `(umask 077 && mktemp ~/.claude/modes/.live-settings.json.XXXXXX) → write JSON → mv tmp ~/.claude/modes/.live-settings.json`. After mv, re-assert `chmod 0600` (V1 sec-004 pattern).

**Execution note:** Test-first. Write failing tests for: (a) hooks key ignored even if present in mode YAML, (b) R22 violation rejected, (c) permissions addition triggers prompt, (d) `statusLine` (an object) preserved verbatim, (e) `mcpServers` absence preserved (not filled from mode), (f) atomic write tolerates kill mid-write (sentinel file or `.tmp` cleanup).

**Patterns to follow:**
- V1 `lib/set-mode.sh` for the orchestration skeleton (validate → atomic write)
- V1 `lib/mode-yaml.sh::__claude_modes::py_yaml_query` for the argv-not-interpolation Python contract
- V1 atomic-write idiom: `(umask 077 && mktemp "${target_dir}/.live-settings.json.XXXXXX") → write → mv → chmod 0600`
- Re-assert chmod 0600 after every write (`rel-101` / `sec-004` pattern from V1 audit.sh)

**Test scenarios:**
- Happy path: Mode YAML with `mechanism.enabledPlugins: {claude-modes@x: true, compound-engineering@y: true}` produces live settings with those two keys set; previous extraneous enabledPlugins entries are removed
- Happy path: Mode YAML with `mechanism.env: {FOO: "bar"}` sets `env.FOO` in live; previous `env` is replaced wholesale (key is plugin-owned)
- Happy path: Mode YAML omits `mechanism.mcpServers` → live's `mcpServers` set to empty `{}` (or omitted entirely if user had none) — NEVER inherits previous mode's MCP servers
- Edge case (preserve-the-rest): Mode YAML omits `mechanism.statusLine` → live's `statusLine` (an object) is preserved verbatim, byte-for-byte
- Edge case (R28 — behavioral): Mode YAML with `mechanism.hooks: {PreToolUse: [{command: "rm -rf /"}]}` → hooks key is IGNORED. Live settings' `hooks` key is preserved from current value. Test asserts: live_new.hooks == live.hooks regardless of mode YAML hooks content.
- Edge case (R28 — runtime assertion): Test imports `lib/live-settings-merge.py` with PLUGIN_OWNED_KEYS_V2 monkey-patched to include `"hooks"`. Assert that any merge call raises `AssertionError` with message matching `R28: hooks must never be plugin-owned`. Fixture: `tests/unit/live-settings-merge-r28-assert.test.sh` runs `python3 -c "import sys; sys.path.insert(0, 'lib'); from live_settings_merge import PLUGIN_OWNED_KEYS_V2; PLUGIN_OWNED_KEYS_V2.append('hooks'); from live_settings_merge import merge; merge(...)"` and asserts non-zero exit with the expected assertion message.
- Error path (R22 violation): Mode YAML with `mechanism.enabledPlugins` missing claude-modes → merge engine rejects with exit 2 and stderr matching `claude-modes must be enabled in every mode`. Covers AE5.
- Error path: Malformed mode YAML → exit non-zero, no partial write to live settings (atomic mv never fires)
- Error path: Live settings JSON corrupted (unparseable) → exit non-zero with clear error; do not clobber the corrupted file
- Integration (permissions diff gate): Mode YAML adds a new permission grant not in current → prompt fires; user N → no write; user Y → write proceeds
- Integration (atomic): Kill engine mid-write (SIGTERM after tmp file written but before mv) → re-run engine produces correct end state; no `.live-settings.json.XXXXXX` files leak (trap cleanup)

**Verification:**
- All test cases above pass under `tests/run.sh`
- `tests/integration/r19-lint.test.sh` extended pattern `hooks` appearing in `PLUGIN_OWNED_KEYS_V2` (positive fixture: must catch; negative fixture: must not false-positive on the string `enabledPlugins` or `hooks_dir`)
- `stat -f %A ~/.claude/modes/.live-settings.json` reports `600` after every merge
- Manual smoke: `/mode:set delivery` (after U5 lands) produces a `.live-settings.json` that diffs cleanly from the previous mode on plugin-owned keys only

---

- U5. **`/mode:set` orchestration with idempotent crash-safe execution (R26)**

**Goal:** Build the `/mode:set <name>` slash command end-to-end. Orchestrate: name validation → branch resolution → mode YAML load → R22 swap-time validation → U4 merge → symlink rebuild (delegated to U8) → per-branch state write (R6) → audit log → user signal. Wrap in R26's idempotent crash-safe contract via `.mode-set.in-progress` sentinel.

**Requirements:** R5 (orchestration uses U4 merge), R6 (per-branch state file), R8 (signal user; optionally invoke /reload-plugins per U1 result), R26 (idempotent crash-safe), permissions diff gate (R5 revised).

**Dependencies:** U3 (YAML reader), U4 (merge engine), U8 (symlink rebuild — sequenced after U4 write but before sentinel clear).

**Files:**
- Modify: `lib/set-mode.sh` (extract V1 skeleton from v0.1.0-experiment tag; extend with sentinel + flock + R22 swap-time check + U4 merge invocation + U8 symlink-rebuild invocation)
- Modify: `lib/active-mode.sh` (carry from V1, extend `read_active_mode_name` for per-branch + Claude-Mode-baseline fallback)
- Create: `commands/set.md` (slash-command body: prose + single-line `"${CLAUDE_PLUGIN_ROOT}/lib/set-mode.sh" "$ARGUMENTS"`)
- Create: `commands/apply.md` (slash-command body for `/mode:apply` — conservative-mode helper that copies `.live-settings.json` over `settings.json`)
- Create: `lib/apply-mode.sh` (mechanism for `/mode:apply` — diff-aware cp with confirmation prompt)
- Create: `tests/integration/mode-set-crash-recovery.test.sh`
- Extend: `tests/integration/mode-set-crash-recovery.test.sh` to also exercise `/mode:apply` in conservative-mode round-trip

**Approach:**
- Sentinel file `~/.claude/modes/.mode-set.in-progress` written before any mutation; cleared after last mutation. Recovery: on `/mode:set` and `/mode:status` startup, if sentinel exists with a name, log `previous /mode:set was interrupted; re-running for <target>` and re-apply.
- Flock acquisition is U9's responsibility (R27 reconciliation) — U5's `/mode:set` proceeds WITHOUT flock for now (single-worktree case). U9 wires the flock into a shared `acquire_symlink_lock` helper that both `/mode:set` and SessionStart use.
- Idempotency contract: rebuild target state from mode YAML + current live settings; never depend on previous catalog state. Concretely: U4's merge is already idempotent (deterministic from YAML + current live); U8's symlink rebuild is idempotent (enumerate manifest → ensure each symlink matches target → no diff = no-op).
- Per-branch state: `<repo>/.claude/modes/<branch-slug>.mode` (slugify via V1 `validate-mode-name.sh::slugify_branch`). Detached HEAD → slug `detached-<short-sha>`. No-repo case → no per-branch state (user-global; first-mode-set wins).
- User signal: depends on R21 install mode. In **opt-in symlink mode** (~/.claude/settings.json is a symlink to .live-settings.json): `mode set to <X> — run /reload-plugins to apply` (or invoke /reload-plugins programmatically if U1 row 5/6/7 confirmed it works for the keys this mode changed). In **conservative mode** (~/.claude/settings.json is a regular file): `mode set to <X> — run /mode:apply (or copy ~/.claude/modes/.live-settings.json over ~/.claude/settings.json) then /reload-plugins to apply`. The `/mode:apply` slash command (added to U5's command list) is a thin wrapper around `cp ~/.claude/modes/.live-settings.json ~/.claude/settings.json` with a "this will overwrite settings.json from current live; preserve any manual edits to non-plugin-owned keys you've made since /mode:set [Y/n]" prompt (similar to R17's drift-aware uninstall).
- AE2 acceptance: `/mode:set claude` works exactly like the install-time baseline — full catalog visible after `/reload-plugins`

**Execution note:** Test-first for crash recovery. Write the failing test first: kill `/mode:set` after sentinel write but before completion, then re-run `/mode:set <same-target>`, assert end state correct.

**Patterns to follow:**
- V1 `lib/set-mode.sh` (ordered execution: validate → resolve → schema → atomic write)
- V1 `lib/active-mode.sh` (`current_branch_slug`, detached-HEAD handling)
- Slash-command arg convention: `commands/set.md` is prose + ONE line: `"${CLAUDE_PLUGIN_ROOT}/lib/set-mode.sh" "$ARGUMENTS"`. No `$`-bearing logic inline.
- V1 `lib/audit.sh` for swap-event recording

**Test scenarios:**
- Happy path: `/mode:set delivery` writes live settings, updates per-branch state, signals user; on `/reload-plugins` (manual), `/help` reflects delivery's `enabledPlugins`
- Happy path (AE2): `/mode:set claude` restores the baseline catalog (Claude Mode YAML's mechanism = user's pre-install settings.json)
- Edge case (detached HEAD): `git checkout <sha>` → `/mode:set delivery` → per-branch state file is named `detached-<short-sha>.mode`
- Edge case (no git repo): `cd /tmp && /mode:set delivery` → mode set successfully; no per-branch state file written; signal user with explicit `(no git repo — using user-global state)` note
- Error path (R22 violation surfaced from U4): `/mode:set bad-mode` where bad-mode.yaml omits claude-modes → exit 2 with clear error per AE5 wording
- Error path (mode YAML missing): `/mode:set ghost` → exit non-zero with `mode 'ghost' not found at ~/.claude/modes/ghost.yaml`
- Integration (R26 crash recovery): SIGTERM `/mode:set delivery` after sentinel written but before symlink rebuild → sentinel persists → re-run `/mode:set delivery` (or `/mode:status`) detects orphaned sentinel → re-applies → end state matches non-interrupted run
- Integration (R26 idempotency): Run `/mode:set delivery` twice in a row → second run is a no-op (filesystem and live settings unchanged); audit log records both swap events

**Verification:**
- `/mode:set <name>` succeeds for valid modes, fails clearly for invalid modes
- `~/.claude/modes/.live-settings.json` reflects the new mode's mechanism merged with preserved keys
- `<repo>/.claude/modes/<slug>.mode` records the active mode
- Audit log appends a swap event with mode name + timestamp
- Crash-recovery test (kill after sentinel) re-converges to correct end state
- Idempotency test (run twice) produces no diff after the second run

---

- U6. **`/mode:setup` first-time install flow (F1)**

**Goal:** Implement the install wizard. Capture `~/.claude/settings.json.pristine`; build `~/.claude/modes/claude.yaml` from the user's current settings (Claude Mode baseline); offer to symlink `~/.claude/settings.json` → `~/.claude/modes/.live-settings.json` (or conservative mode = manual apply); move user-authored commands/agents into `.user-catalog/` via single atomic `mv` each, symlink back; seed example modes; archive any V1 `schema_version: 1` YAMLs to `.v1-archive/`.

**Requirements:** R3 (move + symlink), R4 (user-catalog manifest framework), R9 (V1 archival), R12 (plugin only writes inside `~/.claude/modes/`), R13 (no destructive verbs on user paths), R18 (pristine recovery anchor), R21 (conservative vs opt-in symlink), R24 (0600 on pristine + claude.yaml).

**Dependencies:** U3 (schema validator + write-mode-yaml.sh for Claude Mode); U4 (live-settings merge engine, used at install-time to produce initial live settings); U8 (symlink-rebuild library, called for first-time symlink construction).

**Files:**
- Create: `scripts/setup.sh` (orchestrator)
- Create: `commands/setup.md` (slash-command body: prose + single-line invocation)
- Extend: `tests/integration/install-uninstall-roundtrip.test.sh` (install path; U7 adds the uninstall path)

**Approach:**
- **Crash-safety contract** (extends R26 to /mode:setup): U6 writes `~/.claude/modes/.setup.in-progress` sentinel as the FIRST mutation, before any file moves. Each subsequent step is idempotent (each `mv` checks "is target already at destination?" before acting; each `chmod` re-asserts; each `ln -s` checks "is symlink already correct?"). On startup, presence check is downgraded: if sentinel exists, log "previous /mode:setup was interrupted; resuming" and re-apply each step idempotently; if `~/.claude/modes/claude.yaml` exists without sentinel, refuse with "already installed." Sentinel cleared as the LAST mutation.
- Steps in order (each idempotent — re-running converges):
  1. **Presence check.** If `~/.claude/modes/claude.yaml` exists AND `.setup.in-progress` sentinel is absent, refuse with `claude-modes is already installed; run scripts/unmodes.sh to uninstall first.` If sentinel exists, log "resuming previous /mode:setup" and continue (idempotent re-apply).
  1a. **Write sentinel.** `touch ~/.claude/modes/.setup.in-progress` (atomic via `(umask 077 && touch ...)`).
  2. **Pristine capture.** **Born-at-0600 pattern (per V1 atomic-write idiom):** `(umask 077 && tmp=$(mktemp ~/.claude/settings.json.pristine.XXXXXX) && cp ~/.claude/settings.json "$tmp" && mv "$tmp" ~/.claude/settings.json.pristine)`. The `umask 077` in the subshell ensures the file is created with mode 0600; no TOCTOU window between mv and chmod. NO retroactive `chmod 0600` — the file is BORN at 0600. Test in U13's `settings-file-perms.test.sh` verifies pristine has mode 0600 atomically post-mv with no intervening chmod.
  3. **Build Claude Mode YAML.** Read `~/.claude/settings.json` via Python; extract `enabledPlugins`, `env`, `permissions`, `mcpServers` into a synthesized `mechanism:` block. Write `~/.claude/modes/claude.yaml` via U3's `write-mode-yaml.sh` (validates R22 — claude-modes must be in enabledPlugins; if not, ADD it before writing, with a one-time `<system-reminder>` informing the user).
  4. **Move user catalog.** For each file in `~/.claude/commands/*.md` and `~/.claude/agents/*.md`: single atomic `mv` into `~/.claude/modes/.user-catalog/commands/` (or `.../agents/`), then `ln -s` back to the original path. Pre-flight per-file checks:
    - **Symlinks** (`[ -L "$file" ]` true): preserve in place — alien-symlink protection per R7. Not moved into staging.
    - **Hard-linked files** (`stat -f %l "$file"` > 1 on macOS, `stat -c %h "$file"` > 1 on Linux): **HARD-FAIL the install** with explicit remediation: `~/.claude/commands/<file> is hard-linked to another inode (link count: N). claude-modes V2.0 does not support hard-linked user-catalog files because the move-to-staging mechanism would break the link. Remediation: (a) un-link the file (cp → rm + cp back to break the hard link), then re-run /mode:setup; OR (b) add the file path to ~/.claude/modes/.setup-skip-list (one path per line) to leave it in place as a regular global file (visible in every mode, never scoped to any mode).` Surface this as a setup-time decision the user must make explicitly; do NOT silently leave hard-linked files unmanaged (the "log warning + skip" pattern silently breaks the every-user-file-is-a-symlink invariant).
    - **Regular files**: proceed with mv + ln -s.
  5. **Validate same-filesystem.** Before any `mv`, check `stat -f %d ~/.claude/commands` vs `stat -f %d ~/.claude/modes/.user-catalog` to confirm same filesystem. If different, fall back to `cp + verify (sha256) + rm` with explicit error handling.
  6. **Seed examples.** Copy `examples/*.yaml` to `~/.claude/modes/`.
  7. **Archive V1 modes.** If any `~/.claude/modes/*.yaml` has `schema_version: 1` (other than the just-written claude.yaml), move to `~/.claude/modes/.v1-archive/`. Emit one-time `<system-reminder>` (via R25 mechanism after U10 lands).
  8. **Settings symlink (R21 opt-in).** Prompt: `Symlink ~/.claude/settings.json → ~/.claude/modes/.live-settings.json? This lets /mode:set actually swap your settings on /reload-plugins. (Recommended: Y) [Y/n]`. On Y → symlink. On N → conservative mode (user manually copies after `/mode:set`).
  9. **Initial live settings.** Call U4 merge with claude.yaml → write initial `.live-settings.json` matching the user's pre-install state.
  10. **Audit.** Append install event.
  11. **Clear sentinel.** `rm ~/.claude/modes/.setup.in-progress` as the final mutation. /mode:setup is now complete.
- Permissions: pristine and claude.yaml at 0600 (R24). `.user-catalog/` at 0700.

**Execution note:** Test-first for the install's no-data-loss invariant. Write a failing test that creates a `~/.claude/commands/foo.md` with known content, runs setup, asserts `cat ~/.claude/commands/foo.md` returns the same content via the symlink, then asserts `readlink ~/.claude/commands/foo.md` resolves to `.user-catalog/commands/foo.md`.

**Patterns to follow:**
- V1 `scripts/install-examples.sh` (idempotent seeding + 0600 + mkdir -m 0700)
- V1 `scripts/install-statusline.sh` (Python-based mutation of user files, with pre-write assertions and size-grew checks)
- V1 `lib/audit.sh` for install-event recording

**Test scenarios:**
- Happy path: Fresh `~/.claude/commands/{a,b,c}.md` and `~/.claude/agents/x.md`; run setup; assert each file's content is byte-identical via the symlink path AND the file is now a symlink (`[ -L ]` returns true)
- Happy path (covers AE1 install half): SHA-256 of each file's content matches pre-install
- Happy path: `~/.claude/modes/claude.yaml` is written with `schema_version: 2`, contains the user's pre-install enabledPlugins/env/permissions
- Happy path: `~/.claude/settings.json.pristine` exists with `mode 0600`
- Edge case (V1 archival): Pre-existing `~/.claude/modes/old-v1.yaml` with `schema_version: 1` → moved to `~/.claude/modes/.v1-archive/old-v1.yaml`; warning surfaced
- Edge case (alien symlinks): `~/.claude/commands/external.md` is a symlink to `~/vault/external.md` (existing user setup) → setup leaves it untouched (R7 alien-symlink protection)
- Edge case (cross-filesystem): If `~/.claude` and `~/.claude/modes` are on different filesystems → setup falls back to cp+verify+rm with audit log warning
- Error path (already installed — no sentinel): Run setup twice; second run exits with clear error, no destructive action
- Error path (no `~/.claude/commands/`): Run setup with no user catalog dirs → setup creates empty `.user-catalog/` dirs and succeeds (no-op move section)
- Integration (crash recovery — covers R26 extension to /mode:setup): SIGTERM /mode:setup after step 4 (mid-move-loop, some files moved, some not). Sentinel persists. Re-run /mode:setup → detects orphaned sentinel, logs "resuming previous /mode:setup," idempotently re-applies each step (already-moved files are no-ops, remaining files complete the move), clears sentinel on success. End state SHA-256-identical to non-interrupted run.
- Integration (crash recovery — SIGKILL): same as above with SIGKILL (no chance to clean up). Re-run /mode:setup → detects orphaned sentinel, recovers identically. (Kernel-level FD cleanup releases any open files; the sentinel file persists across kills.)
- Integration (R21 conservative mode): User selects N at the symlink prompt → `~/.claude/settings.json` is unchanged; `.live-settings.json` is written; user must manually replace
- Integration (R21 opt-in): User selects Y → `~/.claude/settings.json` becomes a symlink to `~/.claude/modes/.live-settings.json`; `/reload-plugins` reflects the live file

**Verification:**
- Install completes without modifying any file content
- All symlinks resolve to byte-identical content (SHA-256 match)
- Pristine + claude.yaml at 0600; .user-catalog/ at 0700
- V1 YAMLs archived; no migration attempted
- Audit log shows install event
- Conservative vs opt-in symlink mode correctly applied based on user response

---

- U7. **`scripts/unmodes.sh` drift-aware uninstall (R17 + R18 + R21)**

**Goal:** Implement the uninstall script. Diff `settings.json.pristine` vs current live; surface non-plugin-owned divergences; prompt user to preserve post-install edits (default Y); restore only plugin-owned keys from pristine; move user-catalog files back to `~/.claude/commands/` and `~/.claude/agents/`; remove plugin-owned symlinks; delete `~/.claude/modes/`. Two-branch round-trip test covers clean (byte-identical) and drifted (preserved-edits) paths.

**Requirements:** R13 (no destructive verbs lint), R17 (drift-aware uninstall), R18 (pristine recovery anchor), R21 (handle conservative vs opt-in symlink mode), AE1 (clean round-trip), AE4 (lint catches destructive verbs).

**Dependencies:** U6 (install produces the pristine, claude.yaml, user-catalog that uninstall reverses); U4 (merge engine, used for non-owned-keys preservation during partial restore).

**Files:**
- Create: `scripts/unmodes.sh` (orchestrator)
- Create: `scripts/restore-claude-modes.sh` (smaller recovery — re-enable claude-modes in live settings without full uninstall, for the R22 wedge case)
- Create: `lib/drift-diff.sh` + `lib/drift-diff.py` (pristine vs live diff helper)
- Create: `tests/unit/drift-diff.test.sh`
- Extend: `tests/integration/install-uninstall-roundtrip.test.sh` (uninstall path — both clean and drifted branches)

**Approach:**
- Steps in order:
  1. **Drift check.** Read `~/.claude/settings.json.pristine` and `~/.claude/modes/.live-settings.json` (or `~/.claude/settings.json` if non-symlinked, R21 conservative mode). Diff via `lib/drift-diff.py`: classify each TOP-LEVEL key as plugin-owned (always restored from pristine) vs non-owned (preserved or restored based on user choice). **Caveat (per adversarial F2): the diff is at the top-level-key granularity, not deep.** If the user added a deeply nested key INSIDE a plugin-owned key (e.g., `permissions.allowedExtensions: [".sh"]` post-install), uninstall classifies the ENTIRE `permissions` block as plugin-owned and restores from pristine — silently destroying the user's nested addition. This is a known limitation of V2.0; README's "How V2 handles your files" section explicitly documents that "additions made INSIDE claude-modes-managed settings sections (enabledPlugins, env, permissions, mcpServers) are not preserved on uninstall." V2.1 candidate: deep-merge semantics with sub-key drift surfacing.
  2. **Surface drift.** If any non-owned key differs (e.g., user added `statusLine` config post-install, installed an MCP server, etc.), print named diff and prompt `preserve these post-install changes? [Y/n]` (default Y).
  3. **Restore settings.** On Y → atomic write to `~/.claude/settings.json` (or `.live-settings.json` based on R21 mode) the merge `pristine.plugin_owned_keys + live.non_owned_keys`. On N → byte-identical pristine restore.
  4. **Move user catalog back.** For each file in `~/.claude/modes/.user-catalog/commands/*.md` and `.../agents/*.md`: remove the plugin-owned symlink at the original path (only if it resolves into `.user-catalog/` — never touch alien symlinks or regular files), then `mv` the file back to its original location. Same filesystem check; cp+verify+rm fallback for cross-filesystem.
  5. **Remove modes dir.** `rm -rf ~/.claude/modes/` (the ONLY rm on a plugin-owned tree — user paths are never `rm`'d, only mv'd back; R13 lint enforces this).
  6. **Audit.** Append uninstall event (to a file outside `~/.claude/modes/` since that's about to be removed — perhaps `~/.claude/.claude-modes-uninstall.log`).
- `scripts/restore-claude-modes.sh` (R22 wedge recovery): smaller — just re-enable `claude-modes@*` in `enabledPlugins` of the current live settings via Python parse + mutate + atomic write. No file moves; no `~/.claude/modes/` deletion. For users who wedged themselves by editing `.live-settings.json` to disable claude-modes.

**Execution note:** Test-first for both branches. Write failing tests for: (a) clean round-trip (install then immediate uninstall → SHA-256 byte-identical of every regular file), (b) drifted round-trip (install, edit settings post-install with a new statusLine config, uninstall with Y choice → settings has the new statusLine + pristine's plugin-owned keys), (c) R13 lint catches `rm` on `~/.claude/commands/*.md` in the script source.

**Patterns to follow:**
- V1 `lib/audit.sh` for uninstall event recording (write target shifts since `~/.claude/modes/` is being deleted)
- V1 `tests/integration/r19-lint.test.sh` for the destructive-verb lint pattern
- V1 atomic-write idiom for the settings restore step

**Test scenarios:**
- Happy path (clean — covers AE1 second half): install, no post-install edits, uninstall → SHA-256 of every file in `~/.claude/` matches pre-install
- Happy path (drifted — Y choice): install, edit `~/.claude/settings.json` to add `statusLine: {...}`, uninstall with Y → settings has the new statusLine + plugin-owned keys from pristine
- Edge case (drifted — N choice): install, edit settings, uninstall with N → byte-identical pristine restore (settings's statusLine reverted to pre-install value)
- Edge case (alien symlink preserved): user's pre-install `~/.claude/commands/external.md` symlink to vault → uninstall leaves it untouched
- Edge case (no drift): no post-install settings edits → diff is empty, no prompt fires, byte-identical restore proceeds silently
- Error path (no install present): run unmodes.sh without prior install → exit clearly with `claude-modes not installed (no ~/.claude/modes/)`
- Error path (corrupted pristine): pristine JSON unparseable → exit non-zero, do not destroy current settings
- Integration (R13 lint — covers AE4): tests/integration/no-destructive-rm.test.sh checks scripts/*.sh and lib/*.sh; positive fixture (`rm "$HOME/.claude/commands/foo.md"`) catches; negative fixture (`rm "$HOME/.claude/modes/.live-settings.json.tmp"`) does not false-positive (rm on plugin-owned tree is allowed)
- Integration (restore-claude-modes.sh): user manually edits `.live-settings.json` to set `enabledPlugins.claude-modes@dev: false`; runs `bash ~/.claude/plugins/claude-modes/scripts/restore-claude-modes.sh`; assertion: live settings now has `claude-modes@dev: true` and no other key changed

**Verification:**
- Two-branch round-trip test passes (clean + drifted)
- R13 lint test catches all enumerated destructive shapes (`rm`, `unlink`, `find -delete`, `> file`, `: > file`, `truncate -s 0`, `cp /dev/null`, in-place sed without explicit allowlist of plugin paths)
- restore-claude-modes.sh recovers the R22 wedge case without destroying user data

---

*(Note on phase placement: U8 below is Phase-2 work — it's listed in this position only because the conceptual chapter heading reads more naturally with all user-catalog-touching work together. Per the dependency graph and Phased Delivery section, U8 lands after U4 and parallel with U5, before U6. The Phase 3 heading applies starting at U9.)*

- U8. **User-catalog manifest + symlink rebuild + R7 path-traversal validation** (Phase 2 — see note above)

**Goal:** Implement the symlink-rebuild library that U5 calls on every `/mode:set`. Read the active mode YAML's `mechanism.user_catalog` manifest; enumerate which files in `.user-catalog/commands/` and `.../agents/` should be visible; rebuild symlinks at `~/.claude/commands/` and `~/.claude/agents/` to match. Enforce R7 path-traversal validation via `realpath` mechanically.

**Requirements:** R3 (user-catalog directory structure), R4 (per-mode manifest), R7 (path-traversal validation), R12 (only writes inside `~/.claude/modes/`, exception for symlinks at user-catalog paths).

**Dependencies:** U3 (YAML reader); U4 (called by `/mode:set` after U4 merge succeeds — symlink rebuild is its own step in U5's orchestration).

**Files:**
- Create: `lib/symlink-rebuild.sh` (orchestrator — reads manifest, calls validator, calls Python helper)
- Create: `lib/symlink-validate.py` (realpath-based path-traversal check)
- Create: `tests/unit/symlink-validate.test.sh`
- Create: `tests/integration/symlink-path-traversal.test.sh`

**Approach:**
- Steps in `lib/symlink-rebuild.sh` for `/mode:set <name>`:
  1. Read mode YAML's `mechanism.user_catalog.commands` + `.agents` manifest
  2. For each entry, validate via `lib/symlink-validate.py`: compute `target = realpath(~/.claude/modes/.user-catalog/<category>/<entry>)`; assert `target.startswith(realpath(~/.claude/modes/.user-catalog/) + "/")`. Refuse if not.
  3. Enumerate current plugin-owned symlinks at `~/.claude/commands/` and `~/.claude/agents/` (symlinks whose readlink target is under `.user-catalog/`)
  4. Compute diff: (target_set − current_set) → create; (current_set − target_set) → remove; intersection → no-op
  5. Apply diff
- R7 mechanical enforcement: a user-catalog manifest entry like `../../../.ssh/id_rsa` MUST fail validation at step 2 with exit non-zero and stderr matching `path traversal detected in user_catalog manifest entry`. This is the load-bearing security mechanism.
- Alien-symlink protection: when removing symlinks at user-catalog paths, check `readlink` resolves under `.user-catalog/`; if not (alien symlink, user pre-install setup), leave untouched.
- Regular-file protection: NEVER `rm` or `unlink` a regular file at `~/.claude/commands/*.md` or `~/.claude/agents/*.md`. Only the corresponding symlink (if plugin-owned) is removed.
- Empty manifest (Claude Mode = include everything by default per R4): special case — include all files currently in `.user-catalog/commands/` and `.../agents/`.

**Execution note:** Test-first for the path-traversal cases. Write attack fixtures FIRST: manifest with `../../.ssh/id_rsa`, manifest with `commands/../../etc/passwd`, manifest with absolute path `/etc/shadow`. Each must fail validation with explicit error.

**Patterns to follow:**
- V1's `lib/mode-yaml.sh` for the manifest read (extend `get_field` for `mechanism.user_catalog.commands`)
- V1's `lib/audit.sh` for symlink-rebuild events (mostly for diagnostics; rebuild events are high-frequency)
- macOS-Linux portable realpath: `python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path"` (avoids `realpath` not being in macOS POSIX defaults)
- V1's symlink validation in `lib/mode-yaml.sh`'s repo-mode-dir-override scope check (extend the pattern)

**Test scenarios:**
- Happy path: manifest `[a.md, b.md]` and `.user-catalog/commands/` contains `a.md, b.md, c.md` → after rebuild, `~/.claude/commands/` has symlinks for `a.md` and `b.md` only; `c.md` is not symlinked
- Happy path: empty manifest with Claude Mode default (include everything) → all files in `.user-catalog/commands/` are symlinked
- Edge case (no diff): rebuild with manifest matching current symlinks → no fs mutations occur (verify via `find ~/.claude/commands -newer <timestamp>` returns empty)
- Edge case (file missing from .user-catalog): manifest entry `phantom.md` not in `.user-catalog/` → warning logged, skipped (don't fail rebuild for one missing file)
- Edge case (alien symlink preserved): user's `~/.claude/commands/external.md` is a symlink to `~/vault/external.md` (pre-install setup) → rebuild leaves it untouched
- Error path (R7 path traversal — covers AE3 partially): manifest with `../../.ssh/id_rsa` → exit non-zero with `path traversal detected`; no symlink created
- Error path (R7 absolute path): manifest with `/etc/passwd` → same rejection
- Error path (R7 sneaky traversal): manifest with `commands/../../etc/passwd` (relative but escapes) → same rejection (realpath resolves the escape)
- Error path (R7 symlink-in-staging escape attempt): user manually creates `~/.claude/modes/.user-catalog/commands/escape.md` as a symlink to `/etc/passwd`; manifest entry `escape.md` → validate resolves the symlink chain; rejected because final target is not under `.user-catalog/`
- Integration (mode swap covers AE3): set delivery (with manifest `[strict-deploy.md]`); set discovery (with manifest `[explore.md]`); after each swap, `ls ~/.claude/commands/` reflects only the active mode's manifest entries

**Verification:**
- All R7 attack fixtures rejected with clear errors
- Symlink rebuild is idempotent (running with no manifest change → no fs mutations)
- Alien symlinks preserved
- No regular file ever destroyed (R13 lint catches; runtime never rm's regular files at user-catalog paths)
- AE3 acceptance: in delivery mode with manifest `[strict-deploy.md]`, `/help` shows `/strict-deploy` and NOT the other user commands; in Claude Mode (manifest empty = include all), `/help` shows everything

---

### Phase 3: Hooks + UX + wrap-up

- U9. **R27 worktree reconciliation (SessionStart hook + flock + no-op fast path + divergence toast)**

**Goal:** Implement the SessionStart hook that reconciles per-branch mode intent with per-machine symlink mechanism. Acquire flock on `~/.claude/modes/.symlink-lock`; compare current symlink set to target; skip rebuild if match (no-op fast path); rebuild if mismatch; if divergence detected (active symlink-set's mode differs from this session's recorded branch mode), surface a one-time divergence toast via R25's UserPromptSubmit mechanism.

**Requirements:** R6 (per-branch state, read at session start), R27 (reconciliation mechanism). Open question Q4 (programmatic /reload-plugins trigger) may simplify this if U1 confirms.

**Dependencies:** U8 (symlink-rebuild library used for the rebuild step), U10 (R25 prose-injection hook used for the toast — but U9 can write a marker file that U10 reads on next prompt, decoupling).

**Files:**
- Extend: `scripts/on-session-start.sh` (carry V1 stub; add a single invocation: `exec python3 "${CLAUDE_PLUGIN_ROOT}/lib/reconcile-symlinks.py"`)
- Create: `lib/reconcile-symlinks.py` (**Python orchestrator** — opens lock file with `O_CREAT|O_RDWR`, acquires `fcntl.flock(LOCK_EX | LOCK_NB)`, blocking fallback on `EWOULDBLOCK`. Holds the FD for the entire reconciliation process: enumerate current symlinks, compute target, no-op fast path, subprocess.run() to invoke `lib/symlink-rebuild.sh` if needed, divergence detection, marker write, audit append. Lock releases on process exit. NO `os.execvp` — the FD lives for the lifetime of the Python orchestrator, which IS the critical section. Adopted-with-modification from slate-weekly-gist pattern: original calls for execvp because it bridges Python → bash; V2 keeps Python as orchestrator throughout, eliminating the bridge.)
- Create: `tests/integration/worktree-mode-reconciliation.test.sh`
- Extend: `tests/integration/perf.test.sh` (baseline for flock-acquire latency + no-op-fast-path latency; Python startup ~25-40ms cold-cache is the dominant cost)

**Approach:**
- `scripts/on-session-start.sh` is a thin shim: presence gate, then `exec python3 lib/reconcile-symlinks.py` (no error propagation, V1 rel-001 contract).
- `lib/reconcile-symlinks.py` is the orchestrator (single process, holds the lock for its lifetime):
  1. **Presence gate**: confirm `~/.claude/modes/` exists; else exit 0 silently.
  2. **Resolve branch intent**: `git -C "$PWD" symbolic-ref HEAD 2>/dev/null` via subprocess; if fails (detached HEAD or no repo), graceful degrade (no per-branch state; use current user-global active mode from `.live-settings.json`).
  3. **Slugify**: invoke V1's `claude_modes::slugify_branch` (bash function) via subprocess or reimplement the pipeline (`LC_ALL=C tr -c 'A-Za-z0-9_-' '-'`, collapse, strip, reject empty/dot-traversal); detached HEAD → `detached-<short-sha>`.
  4. **Read per-branch state**: `<repo>/.claude/modes/<slug>.mode` for branch intent. If missing → use current active mode as default (most-recent-set).
  5. **Acquire flock**: open `~/.claude/modes/.symlink-lock` with `os.open(path, O_CREAT|O_RDWR, 0o644)` (NEVER `rm + create` — TOCTOU bug). Then `fcntl.flock(fd, LOCK_EX | LOCK_NB)`; if `BlockingIOError`, fall back to blocking `fcntl.flock(fd, LOCK_EX)`. The lock is held by the Python process for the entire reconciliation; releases on process exit (kernel-level cleanup even on SIGKILL).
  6. **No-op fast path**: enumerate current plugin-owned symlinks at `~/.claude/commands/` and `~/.claude/agents/` via `os.scandir + os.readlink`. Compute target set from the branch intent's mode YAML manifest. If equal → close fd (releases lock), exit 0. Target: <50ms cold-cache for this path.
  7. **Rebuild** (only if no-op fast path miss): `subprocess.run(["bash", "lib/symlink-rebuild.sh", mode_name])`. Mutations are serialized by the flock the Python process is still holding.
  8. **Divergence detection**: if BEFORE the rebuild the symlink-set's implied mode (which mode YAML's manifest matches the current symlinks) differs from this branch's recorded intent, write a one-time toast marker: `~/.claude/modes/.sessions/<session-id>.divergence-toast` containing the toast text (current symlink-set mode, branch's recorded mode, `/mode:set <branch-mode>` command). U10's UserPromptSubmit hook reads this on next prompt and injects via `<system-reminder>`, then deletes the marker.
  9. **Audit + close fd**: append reconciliation event; close fd (releases lock); exit 0.
- **Architectural note**: V2 keeps Python as the orchestrator throughout the critical section rather than `os.execvp`-ing into bash. The canonical slate-weekly-gist pattern calls for execvp because it bridges Python → bash holding the FD; V2 eliminates the bridge by making the Python process the FD holder for its entire lifetime. Net effect (kernel-level FD lifetime contract): identical. Net code: simpler. Perf cost: ~25-40ms Python startup, acceptable at session-open frequency.
- **Timeout degradation strategy** (SessionStart hook has 5s budget per hooks.json `timeout: 5`): the flock-acquire blocking path can wait on a concurrent worktree mid-rebuild. Apply timeout to the flock acquire itself: `fcntl.flock(fd, LOCK_EX | LOCK_NB)` first, on `BlockingIOError` use `signal.alarm(3)` + blocking `LOCK_EX` (3-second budget — leaves 2s for the rest of the hook + Python startup). On timeout, log "reconciliation timed out waiting for concurrent worktree; symlinks may be stale until next SessionStart" to `~/.claude/modes/.session-start.log` (per V1 adv-11 contract-anchor pattern), write a `.divergence-toast` marker for U10 to surface, exit 0. Honor SessionStart's "never block" contract — the user's session opens with whatever symlinks are currently on disk; reconciliation will retry on next session start.
- Hook never propagates errors (V1 `rel-001` pattern): Python's main wrapped in `try/except: pass; sys.exit(0)`. SessionStart's "never block" contract honored.

**Execution note:** Test-first for the race. Write the failing test FIRST: simulate two concurrent worktrees opening sessions, each invoking the reconciliation hook. Assert the flock serializes them (timestamps in audit log are non-overlapping in the critical section). Without flock, both rebuilds clobber each other.

**Patterns to follow:**
- `Slate/plugins/docs/solutions/architecture-patterns/silent-failure-when-singleton-assumption-breaks-2026-05-09.md` — canonical flock pattern (`O_CREAT|O_RDWR`, `fcntl.flock LOCK_EX|LOCK_NB`, FD-lifetime-equals-critical-section). V2 adopts the FD-lifetime contract verbatim but eliminates the `os.execvp` bridge by keeping Python as the orchestrator for the entire critical section (see Approach + Architectural note). The TOCTOU-safe `O_CREAT|O_RDWR` (never `rm + create`) and `LOCK_EX|LOCK_NB → blocking fallback` patterns carry over unchanged.
- V1 `scripts/on-session-start.sh` for the SessionStart hook shim shape + presence gate
- V1 `lib/active-mode.sh` for the slug-collision warning shape — R27's divergence toast mirrors this (detect cheaply, surface once, never auto-resolve)
- V1 `lib/audit.sh` for reconciliation events (informational only)

**Test scenarios:**
- Happy path (same-mode concurrent open): worktree A on `feature/x` with branch-mode `delivery`; worktree B on `feature/y` with branch-mode `delivery`; both open Claude sessions concurrently; reconciliation runs in both; second flock-acquire blocks; first completes (rebuild not needed — already in delivery, no-op fast path skips); flock released; second runs (same no-op fast path); no toast fired
- Happy path (different-mode concurrent open): worktree A on `feature/x` with branch-mode `delivery`; worktree B on `feature/y` with branch-mode `discovery`; B opens first → rebuilds to discovery → release flock; A opens next → flock acquired → detects current symlinks = discovery but branch wants delivery → diverge case → toast marker written; A does NOT auto-rebuild (per origin's stance: divergence is surfaced, not silently resolved); A's user sees toast on next prompt
- Edge case (no per-branch record): SessionStart on a branch with no `<repo>/.claude/modes/<slug>.mode` file → defaults to current active mode (most-recent-set); no toast
- Edge case (no git repo): SessionStart in `/tmp` → graceful degrade; no reconciliation attempted; exit 0
- Edge case (detached HEAD): SessionStart with HEAD = `abc1234` → slug `detached-abc1234`; reconciliation proceeds with this synthetic slug
- Edge case (no-op fast path latency): perf test asserts reconciliation completes in under 50ms when current symlinks match target (NO rebuild path)
- Error path (corrupted lock file): manually corrupt `.symlink-lock` (e.g., chmod 000) → reconciliation logs warning, exits 0, never crashes the session
- Error path (concurrent kill during rebuild): worktree A starts rebuild; kill -9 mid-rebuild; flock is released by kernel on process exit; worktree B's session acquires flock; sees orphaned `.mode-set.in-progress` sentinel (set by U5's `/mode:set` path); re-applies idempotently
- Integration (branch checkout within a worktree): user on `feature/x` (delivery mode); `git checkout feature/y` (discovery mode); new Claude session opens → reconciliation detects branch change, rebuilds to discovery; no toast (different worktree's mode didn't change; just this worktree switched branches)

**Verification:**
- Same-mode concurrent worktree sessions: zero contention, zero toasts, no fs mutations
- Different-mode concurrent worktree sessions: deterministic convergence on last-session-started's mode; divergence toast fires in the other session
- Flock-acquire latency under perf baseline
- No deadlocks under concurrent stress test (10 concurrent sessions)
- Branch checkout within a worktree correctly re-reconciles

---

- U10. **R25 UserPromptSubmit prose-injection hook**

**Goal:** Extend the UserPromptSubmit hook to inject the active mode's prose layer (philosophy, scope, lens, constraints, command_heuristics) into Claude's `<system-reminder>` on every user prompt. Also surface one-time markers written by U9 (divergence toast) and U6 (V1-archival notice) and U11 (untagged-new-file notice).

**Requirements:** R25 (UserPromptSubmit hook), Key Decision (V2 retains one small hook — this one).

**Dependencies:** U3 (YAML reader for active mode's prose layer); U9 (writes divergence toast markers); U11 (writes untagged-file markers).

**Files:**
- Extend: `scripts/on-prompt-submit.sh` (carry V1 stub; route to lib/inject-prose.sh)
- Create: `lib/inject-prose.sh` (reads active mode YAML's prose layer; reads pending `<system-reminder>` markers from `~/.claude/modes/.sessions/<session-id>.*`; emits combined systemMessage via JSON-on-stdout)
- Create: `tests/integration/prose-injection.test.sh`

**Approach:**
- Hook contract: stdin = JSON event from Claude Code with `session_id`, `prompt`, etc.; stdout = JSON `{systemMessage: "..."}` to inject (or empty stdout to inject nothing); exit 0 always (V1 rel-001 contract — never block prompt)
- First-injection-per-session marker (V1 carry): `~/.claude/modes/.sessions/<session-id>.injected` — on first prompt of a session, inject `Active mode: <name>\n<prose>` plus any pending markers; on subsequent prompts, inject ONLY the prose layer (lighter) plus any new markers
- Pending markers consumed:
  - `~/.claude/modes/.sessions/<session-id>.divergence-toast` (from U9 R27) — display + delete
  - `~/.claude/modes/.sessions/<session-id>.untagged-files` (from U11 R20) — display + delete
  - `~/.claude/modes/.first-install.notice` (from U6 if V1 archival happened — display once, then delete)
- Empty session_id fallback to `ppid-${PPID:-noppid}` (V1 carry — adv-3 pattern)
- 7-day marker pruning attached to U9's SessionStart hook (V1 carry — `find ~/.claude/modes/.sessions -mtime +7 -delete`)
- PROSE_INJECTION_DISABLED env-var escape hatch: `[ "${PROSE_INJECTION_DISABLED:-}" = "1" ] && exit 0` near the top

**Execution note:** Default (not test-first). The hook contract is well-specified and V1 has a working precedent.

**Patterns to follow:**
- V1 `lib/inject-heuristic.sh` (UserPromptSubmit consumer with stdin-JSON extraction via Python temp-file pattern, never propagate Python rc per rel-001, first-injection marker, PPID fallback)
- V1 `scripts/on-prompt-submit.sh` (hook shim shape)
- V1 `lib/mode-yaml.sh::get_field` (argv-not-interpolation for prose-layer reads)

**Test scenarios:**
- Happy path: first prompt of session in `delivery` mode → systemMessage contains `Active mode: delivery` + delivery's philosophy + scope + lens + constraints
- Happy path: subsequent prompt in same session → systemMessage contains delivery's prose only (no "Active mode" header — already announced this session)
- Happy path (Claude Mode): first prompt in `claude` mode (baseline) → systemMessage may be empty or contain just `Active mode: claude` (since Claude Mode prose is minimal or absent)
- Edge case (no active mode): no `~/.claude/modes/.live-settings.json` or no current mode → exit 0 with empty stdout; no systemMessage emitted
- Edge case (PROSE_INJECTION_DISABLED=1): hook exits 0 immediately, no read of any YAML
- Edge case (empty session_id): hook uses `ppid-<ppid>` fallback for marker filename; first-injection marker created correctly
- Edge case (divergence-toast marker present): systemMessage contains the toast text on this prompt; marker file deleted after consumption
- Edge case (multiple markers): if both divergence-toast and untagged-files markers exist, both are included; both deleted
- Error path (malformed mode YAML): hook logs warning to stderr, exits 0 with empty stdout (never blocks prompt)
- Error path (Python exception): wrapped in `|| true; exit 0`; rc never propagates to harness

**Verification:**
- Hook always exits 0 (verified via `bash -c 'echo "{}" | scripts/on-prompt-submit.sh; echo "rc=$?"'`)
- systemMessage shape is valid JSON when non-empty (`{systemMessage: "..."}`); empty stdout when nothing to inject
- First-injection marker correctly debounces subsequent prompts in the same session
- Pending markers are consumed and deleted after first use

---

- U11. **R20 new-file adoption (PostToolUse + /mode:adopt + SessionStart scan)**

**Goal:** Implement the three adoption paths for new user-catalog files. (a) Manual `/mode:adopt <file>` slash command (load-bearing). (b) PostToolUse Write hook offers immediate consent prompt when Claude writes a file to `~/.claude/commands/*.md` or `~/.claude/agents/*.md`. (c) SessionStart scan detects untagged files from editor writes; writes a marker that U10's prose hook surfaces on next prompt.

**Requirements:** R20 (three adoption paths), R12 (only writes inside `~/.claude/modes/`, except symlink rebuild at user-catalog paths).

**Dependencies:** U6 (`.user-catalog/` directory structure must exist); U8 (symlink-rebuild called after `mv` to materialize the new file as a symlink); U10 (prose-injection hook reads U11's markers).

**Files:**
- Create: `lib/adopt-file.sh` (mechanism — `mv` user file to staging, symlink back, update active mode's user_catalog manifest)
- Create: `commands/adopt.md` (slash-command body)
- Create: `scripts/on-post-tool-use.sh` (PostToolUse hook shim for Write matcher; offers consent prompt for new files at user-catalog paths)
- Extend: `scripts/on-session-start.sh` (add the untagged-file scan; write `.untagged-files` markers)
- Create: `tests/integration/mode-adopt.test.sh`

**Approach:**
- **`/mode:adopt <file>` (path a):**
  - Validate path: must be a regular file (not yet symlinked into `.user-catalog/`) under `~/.claude/commands/` or `~/.claude/agents/`
  - Validate path-traversal: realpath check (R7 mechanism — reuse U8's validator)
  - Single atomic `mv` to `~/.claude/modes/.user-catalog/<category>/<basename>`
  - `ln -s` back to original path
  - Update active mode YAML's `mechanism.user_catalog.<category>` to include the basename (via U3 `write-mode-yaml.sh` for validation)
  - Audit event
- **PostToolUse Write (path b):**
  - Hook receives JSON event with `tool_input` containing the file path
  - Check: is `file_path` under `~/.claude/commands/*.md` or `~/.claude/agents/*.md`? If not, exit 0
  - Check: is it already a symlink into `.user-catalog/`? If yes (e.g., the user wrote to an existing managed file), exit 0
  - Check: is current session interactive? Detect via `[ -t 0 ]` (stdin TTY) OR check for env-var `CLAUDE_NON_INTERACTIVE=1` (set by CE fan-out wrappers). Non-interactive → default to "skip" silently (file stays global; user runs `/mode:adopt` later if desired)
  - Interactive: prompt `Tag /<basename> as a <active-mode>-mode <commands|agent>? [y/N]` (default N — safer). On y → invoke `lib/adopt-file.sh`. On N → no-op.
- **SessionStart scan (path c — handled in U9's SessionStart hook extension):**
  - On SessionStart, after R27 reconciliation, enumerate regular files (not symlinks) at `~/.claude/commands/*.md` and `~/.claude/agents/*.md`. Compare to last-scan snapshot at `~/.claude/modes/.last-file-scan.json`. New files since last scan → write a `<session-id>.untagged-files` marker for U10's prose hook to surface
  - Snapshot updated after scan

**Execution note:** Test-first for the consent flow. Write failing tests for: (a) `/mode:adopt` rejects non-regular files (already symlinked), (b) `/mode:adopt` rejects path traversal, (c) PostToolUse default in non-interactive is N (file stays global), (d) SessionStart scan detects new regular file added between sessions.

**Patterns to follow:**
- V1's atomic-write idiom for the `mv` step (single same-filesystem mv is atomic)
- V1's `write-mode-yaml.sh` for the manifest update step (must validate R22 still holds after the edit)
- Slash-command arg substitution convention: `commands/adopt.md` is prose + single-line `"${CLAUDE_PLUGIN_ROOT}/lib/adopt-file.sh" "$ARGUMENTS"`
- V1's PostToolUse hook shim shape (V1 used Write matcher for cache eviction; V2 reuses the shim for consent — different consumer logic)

**Test scenarios:**
- Happy path AE6a (manual): user creates `~/.claude/commands/strict-deploy.md` via vim; runs `/mode:adopt strict-deploy.md`; file is `mv`'d to `.user-catalog/commands/`, symlinked back; current active mode's YAML's manifest contains `strict-deploy.md`; `cat ~/.claude/commands/strict-deploy.md` returns the original content
- Happy path AE6b (Claude Write + Y): in `delivery` mode, Claude writes `~/.claude/commands/strict-deploy.md`; PostToolUse hook prompts with default N; user answers y → `mv` + symlink + manifest update
- Happy path AE6c (non-interactive default N): same scenario in a CE fan-out subagent (CLAUDE_NON_INTERACTIVE=1 env-var); hook defaults to N silently; file stays global; user can `/mode:adopt` later
- Edge case (already adopted): `/mode:adopt foo.md` when `foo.md` is already a symlink into `.user-catalog/` → exit clearly with `foo.md already managed by mode <X>`
- Edge case (file not in user-catalog path): `/mode:adopt /tmp/foo.md` → reject with `file must be in ~/.claude/commands/ or ~/.claude/agents/`
- Edge case (R7 path traversal): `/mode:adopt ../../etc/passwd` → reject (realpath check from U8)
- Edge case (SessionStart scan baseline): first session ever → last-file-scan.json doesn't exist → snapshot taken without any "new file" markers (all files are baseline)
- Edge case (SessionStart scan detects editor write): session 1 ends with snapshot `[a.md, b.md]`; user authors `c.md` via vim between sessions; session 2 starts → scan detects `c.md` as new → writes `.untagged-files` marker; U10 surfaces toast on first prompt
- Edge case (SessionStart scan ignores symlinks): user has a symlink `~/.claude/commands/external.md` (alien) → not flagged as untagged (it's not a regular file)
- Error path (manifest update would violate R22): adopting a file requires updating the active mode YAML; if mode YAML was tampered with to remove claude-modes, write fails (R22 in write-mode-yaml.sh) → adopt fails atomically (no mv occurred; symlink not yet created)
- Integration (covers AE6 a/b/c)

**Verification:**
- `/mode:adopt` works for editor-authored files
- PostToolUse consent prompt fires for Claude-tool writes; defaults to N
- SessionStart scan catches editor writes between sessions; surface via U10's prose hook
- All R7 path-traversal checks honored
- Audit log records adoption events

---

- U12. **Mode-author skill V2 + `/mode:status` + `/mode:registry`**

**Goal:** Port V1's `.claude/skills/mode-author/SKILL.md` to V2. Extend Phase 2.5 ("orientation") to ask which axes the mode shapes (plugin catalog / user catalog / context injection / none). Route the write through U3's V2-aware `write-mode-yaml.sh`. Implement `/mode:status` (active mode + plugin catalog + user catalog — no drift detection per R23 deferral). Implement `/mode:registry` (list modes, optionally invoke skill for new-mode authoring).

**Requirements:** R10 (conversational authoring), R14 (`/mode:status` — drift detection REMOVED per V2.1 deferral), R15 (axes-orientation question).

**Dependencies:** U3 (V2 schema + write-mode-yaml.sh); U4 (status reads live settings + computes plugin catalog).

**Files:**
- Extend: `.claude/skills/mode-author/SKILL.md` (V2 — add Phase 2.5 axes question; update Phase 6 write to route through V2 `write-mode-yaml.sh`)
- Create: `lib/status.sh` (status command mechanism)
- Create: `lib/registry.sh` (registry command mechanism — list modes from `~/.claude/modes/*.yaml`)
- Create: `commands/status.md` (slash-command body: prose + single-line invocation)
- Create: `commands/registry.md` (slash-command body: prose + single-line invocation)

**Approach:**
- **mode-author SKILL.md (V2):**
  - Phase 1: Intent capture (V1 carry — name, description, why this mode exists)
  - Phase 2: Definition synthesis (V1 carry — write philosophy + scope + lens + constraints)
  - **Phase 2.5 NEW: Axes orientation.** Ask via AskUserQuestion (or numbered fallback) which axes this mode shapes:
    - Plugin catalog (enabledPlugins — which third-party plugins are loaded)
    - User catalog (which user-authored commands and agents are visible)
    - Context injection (philosophy/scope/lens/constraints injected via R25 prose hook)
    - None (minimal mode — full catalog visible; mode-name annotation only)
  - Phase 3: Mechanism declaration (per selected axes — gather enabledPlugins, user_catalog manifest, etc.)
  - Phase 4: Validation (R22 — claude-modes must be in enabledPlugins; offer to add automatically if missing). **Cross-reference `installed_plugins.json`** (per security-lens F3, mitigates prompt-injection-during-authoring vector): for each `enabledPlugins` entry the skill produced, check `~/.claude/plugins/installed_plugins.json` for a matching key. If a key is in the mode YAML but NOT in installed_plugins.json, surface a warning to the user: `"<plugin-name>@<marketplace>" is not currently installed. Mode YAMLs can reference uninstalled plugins (they'll be loaded if/when installed), but this may be unintentional. Keep, remove, or look up the plugin? [k/r/l]`. Warn-not-block — user makes the call. Mode YAML still passes the validator if the user confirms keep.
  - Phase 5: Write via U3's `write-mode-yaml.sh` (mechanically enforces R22 + schema_version: 2)
  - Phase 6: Offer to `/mode:set` immediately or later
- **`/mode:status`:**
  - Read `~/.claude/modes/.live-settings.json` and resolve which mode's mechanism matches (most-recent-set via audit log query, or by matching `.user-catalog` symlinks)
  - Report:
    - Active mode name + path
    - Plugin catalog (count + names from live's `enabledPlugins`)
    - User catalog (count + names of files in `~/.claude/commands/` and `.../agents/` that are plugin-owned symlinks)
    - Per-branch state file content (if in a git repo)
  - No drift detection (R23 deferred — note in output: `Drift detection ships in V2.1`)
- **`/mode:registry`:**
  - List all modes at `~/.claude/modes/*.yaml`
  - For each: name, schema_version, axes used (heuristic — empty mechanism.user_catalog and empty enabledPlugins narrowing = none; etc.)
  - If invoked with `--new` or with no args and user wants a new mode → launch mode-author skill via the Skill mechanism

**Execution note:** Default (not test-first). Skill content + status/registry are mostly read-only mechanisms; failure modes are low-severity.

**Patterns to follow:**
- V1 `.claude/skills/mode-author/SKILL.md` for the phased conversation flow
- Slash-command arg convention: status.md + registry.md are prose + single-line invocations
- V1 `lib/audit.sh` for `/mode:set` event queries (status reads it to determine most-recent-set)

**Test scenarios:**
- Happy path (`/mode:status` after install): reports `Active mode: claude`, plugin catalog count matches `len(enabledPlugins)`, user catalog count matches install-time inventory
- Happy path (`/mode:status` after `/mode:set delivery`): reports `Active mode: delivery`, plugin catalog reflects delivery's enabledPlugins, user catalog reflects delivery's manifest
- Happy path (`/mode:registry`): lists all modes from `~/.claude/modes/*.yaml`; shows axes summary per mode
- Happy path (mode-author skill creates a new mode with all axes selected): produces a valid `schema_version: 2` YAML with mechanism + prose layers; passes U3 validation
- Edge case (no current mode — fresh install before `/mode:setup` completes): `/mode:status` reports `claude-modes not yet installed (run /mode:setup)` and exits 0
- Edge case (mode-author skill — user selects "none" axis): produces a minimal YAML with name + description + empty mechanism; passes U3 validation (claude-modes still required in enabledPlugins for R22)
- Error path (mode-author skill — user attempts to omit claude-modes): U3's `write-mode-yaml.sh` rejects; skill offers to add automatically; user accepts → write succeeds

**Verification:**
- `/mode:status` reports accurate state for both Claude Mode and named modes
- `/mode:registry` lists modes accurately
- Mode-author skill produces V2-valid YAMLs for all 4 axis selections
- Skill's Phase 2.5 axes question is interactive (uses AskUserQuestion or numbered fallback)

---

- U13. **README, lint, cross-cutting tests, statusline carry-forward, docs/solutions/ seed**

**Goal:** Carry-forward the statusline scripts unchanged from V1. Write the V2 README with brisk install, "How V2 handles your files" section, and uninstall reference. Extend R13 lint (`tests/integration/no-destructive-rm.test.sh`) with V2 destructive-verb patterns. Add R24 permissions test (`settings-file-perms.test.sh`). Seed `docs/solutions/` for institutional learnings per the learnings-researcher recommendation. Bump plugin manifest version to ship-ready.

**Requirements:** R13 (lint enforcement — generalized destructive verbs), R16 (statusline carry), R19 (publishable marketplace V2.x), R24 (0600 perms test).

**Dependencies:** All other units (U1–U12) — U13 is the wrap-up unit that hardens cross-cutting invariants and ships the docs.

**Files:**
- Create: `README.md` (V2 — brisk install path, "How V2 handles your files" section explaining mv+symlink + 0600 + pristine, "Uninstalling" pointing at `scripts/unmodes.sh`)
- Create: `docs/architecture.md` (V2 hook surface table + key mechanism diagrams — settings.json merge contract, worktree reconciliation flowchart)
- Create: `docs/solutions/` directory (seed for V2 institutional learnings — `mode-as-settings-overlay-2026-05-XX.md`, `flock-symlink-rebuild-2026-05-XX.md` to be filled post-ship via `/ce-compound`)
- Create: `tests/integration/no-destructive-rm.test.sh` (R13 lint — positive + negative fixtures per V1 r19-lint pattern, expanded for V2 destructive verbs)
- Create: `tests/integration/settings-file-perms.test.sh` (R24 — stat every settings-derived file after creation, assert mode 0600)
- Carry verbatim from `v0.1.0-experiment` tag: `scripts/statusline.sh`, `scripts/install-statusline.sh`, `scripts/uninstall-statusline.sh`, `lib/statusline-dispatcher.sh`, `commands/statusline.md`
- **Modify `tests/run.sh` $HOME isolation hash scope (per adversarial F6):** V1's `tests/run.sh` hashes ONLY `~/.claude/modes/` in the real $HOME before+after the suite to detect tests that leak isolation. V2 mutates a broader surface — `~/.claude/commands/`, `~/.claude/agents/`, `~/.claude/settings.json`, `~/.claude/settings.json.pristine`. Expand the hash check to cover ALL paths V2 can touch: `find ~/.claude/{modes,commands,agents} -type f -print0 | xargs -0 sha256sum` PLUS `sha256sum ~/.claude/settings.json ~/.claude/settings.json.pristine 2>/dev/null` (errors-OK for files that may not exist). Mismatch = P0 fail. This catches tests that forget `claude_modes_test::setup` or that spawn subprocesses inheriting real $HOME.
- Modify: `.gitignore` (add `.live-settings.json`, `.symlink-lock`, `.user-catalog/`, `.sessions/`, `.audit.log`, `.mode-set.in-progress`, `.setup.in-progress`, `.last-file-scan.json` patterns where appropriate)

**Approach:**
- **R13 lint (no destructive verbs):** the lint scans `scripts/*.sh`, `lib/*.sh`, AND `lib/*.py` (Python helpers introduced in V2). Pattern set covers both bash and Python destructive verbs. Positive fixtures — must catch:
  - `\brm\s+["']?\$\{?HOME\}?/\.claude/(commands|agents)/[^/]*\.md`
  - `\bunlink\s+["']?\$\{?HOME\}?/\.claude/(commands|agents)/`
  - `\bfind\s+["']?\$\{?HOME\}?/\.claude/(commands|agents).*-delete`
  - `>\s*["']?\$\{?HOME\}?/\.claude/(commands|agents)/[^/]*\.md` (truncation)
  - `:\s*>\s*["']?\$\{?HOME\}?/\.claude/(commands|agents)/`
  - `\btruncate\s+-s\s+0\s+["']?\$\{?HOME\}?/\.claude/(commands|agents)/`
  - `\bcp\s+/dev/null\s+["']?\$\{?HOME\}?/\.claude/(commands|agents)/`
  - `\btee\s+["']?\$\{?HOME\}?/\.claude/(commands|agents)/[^/]*\.md\s+<\s*/dev/null`
  - `\bsed\s+-i\s+.*\$\{?HOME\}?/\.claude/(commands|agents)/`
  - **Python patterns** (new for V2):
  - `os\.remove\s*\(\s*.*\.claude/(commands|agents)/`
  - `os\.unlink\s*\(\s*.*\.claude/(commands|agents)/`
  - `shutil\.rmtree\s*\(\s*.*\.claude/(commands|agents)`
  - `pathlib\.Path\s*\(\s*.*\.claude/(commands|agents)/.*\)\.unlink\(\)`
  - Negative fixtures (must NOT catch — false-positive guards): `rm "$HOME/.claude/modes/.live-settings.json.tmp.XXXXXX"` (rm on plugin-owned tmp file is OK), `rm "$HOME/.claude/modes/"` (rm on the entire plugin-owned tree during uninstall is OK), `os.remove(tmp_path)` where tmp_path is a `~/.claude/modes/*.tmp.*` (plugin-owned), comments containing the literal strings
- **R24 perms test:** drive `/mode:setup`, then stat each of: `~/.claude/settings.json.pristine`, `~/.claude/modes/claude.yaml`, `~/.claude/modes/.live-settings.json`, `~/.claude/modes/.audit.log`. Assert mode `0600` for each. Drive `/mode:set delivery`, re-stat `.live-settings.json` (rewrites happen), assert 0600 again.
- **README sections:**
  - What is claude-modes (one paragraph)
  - Install (`/mode:setup`)
  - Usage (`/mode:set`, `/mode:status`, `/mode:registry`, `/mode:adopt`)
  - How V2 handles your files (the trust-disarming section — explains the `mv` + symlink mechanism, the pristine recovery anchor, the 0600 permissions, the `unmodes.sh` round-trip test that proves recovery)
  - Uninstalling (`bash ~/.claude/plugins/claude-modes/scripts/unmodes.sh`)
  - Known limitations (multi-worktree per-branch is intent-not-mechanism; drift detection ships in V2.1; etc.)
- **docs/architecture.md:** V2 hook surface table + diagrams. References this plan and the brainstorm for source-of-truth.
- **docs/solutions/ seed:** create the directory with a README pointing at `/ce-compound` for future learnings capture.

**Execution note:** Default (not test-first) for most of U13 — README is prose, statusline is verbatim carry-forward. Test-first for the lint extensions and the R24 perms test (both have specific positive + negative fixtures that should drive the implementation).

**Patterns to follow:**
- V1 `tests/integration/r19-lint.test.sh` for the positive+negative lint pattern (extend, don't replace)
- V1 README pattern (brisk install + "What it does" + "How it works" sections)
- V1 docs/architecture.md (carry the shape — hook surface table, decision matrix, hook contract)

**Test scenarios:**
- Happy path (R13 lint clean): scan V2's scripts/*.sh and lib/*.sh → no destructive-verb matches
- Edge case (positive fixture catch): planted file `tests/fixtures/r13-positive/has-rm-on-commands.sh` containing `rm "$HOME/.claude/commands/foo.md"` → lint catches with non-zero exit
- Edge case (negative fixture pass): planted file `tests/fixtures/r13-negative/has-rm-on-tmp.sh` containing `rm "$HOME/.claude/modes/.live-settings.json.tmp"` → lint does NOT false-positive
- Edge case (R24 — fresh install): after `/mode:setup`, `stat -f %A` on pristine/claude.yaml/live-settings.json/audit.log all return `600`
- Edge case (R24 — after rewrite): after `/mode:set delivery`, `.live-settings.json` is rewritten → re-stat returns `600` (chmod re-asserted post-write per V1 sec-004 pattern)
- Integration (README links resolve): every linked file path in README exists in repo
- Integration (statusline carry-forward verbatim): `tests/run.sh` invokes statusline tests from V1; all pass unchanged

**Verification:**
- R13 lint catches all enumerated destructive shapes; no false-positives in scan of V2 source
- R24 perms test passes for fresh install + post-`/mode:set` rewrites
- README is internally linked and externally accurate (no broken paths)
- Statusline tests carry forward green
- `docs/solutions/` exists for future `/ce-compound` learnings capture

---

## System-Wide Impact

- **Interaction graph:** V2 introduces three hooks (UserPromptSubmit for R25 prose, SessionStart for R27 reconciliation + R20 scan, PostToolUse Write for R20 consent). PreToolUse is DROPPED entirely (V1's R28-violating PreToolUse(Task|Skill|Agent) matcher disappears). Each hook's failure mode is "log warning, exit 0" — no hook may block tool dispatch or prompt submission.

- **Error propagation:** V1's rel-001 pattern (never propagate Python rc through hook scripts) carries forward. Every hook script wraps mutations in `|| true` and ends with explicit `exit 0`. CLI commands (`/mode:set`, `/mode:status`, etc.) propagate errors normally (non-zero exit + stderr message) since they're user-driven and the user expects feedback.

- **State lifecycle risks:** `~/.claude/modes/.mode-set.in-progress` sentinel handles partial-write during `/mode:set` (R26). `~/.claude/modes/.symlink-lock` handles concurrent-rebuild races across worktrees (R27). `~/.claude/modes/.sessions/<session-id>.*` markers handle one-time UX surfacing (R10's prose, R20's untagged-files, R27's divergence) without persisting beyond a session (7-day pruning in SessionStart). Atomic-write idiom (`mktemp + mv`) handles partial-write for every settings-derived file.

- **API surface parity:** `/mode:set <name>`, `/mode:setup`, `/mode:status`, `/mode:adopt <file>`, `/mode:registry`, `/mode:statusline {install|uninstall|status}` — 6 slash commands total. All follow the `.md` body = prose + single-line `lib/*.sh` invocation convention. Mode-author skill is the only authoring surface — direct YAML editing is supported but discouraged for new users.

- **Integration coverage:** Round-trip install/uninstall test (`install-uninstall-roundtrip.test.sh`) exercises the cross-layer install → use → uninstall lifecycle with both clean and drifted branches. Worktree reconciliation test (`worktree-mode-reconciliation.test.sh`) exercises concurrent SessionStart races. Mode-set crash-recovery test (`mode-set-crash-recovery.test.sh`) exercises kill-mid-mutation. R7 path-traversal test (`symlink-path-traversal.test.sh`) exercises all known attack shapes.

- **Unchanged invariants:**
  - `~/.claude/settings.json` non-plugin-owned keys (`statusLine`, `worktree`, `plugins`, `outputStyle`, etc.) — preserved verbatim through every `/mode:set` merge. R5's plugin-owned set is a 4-key minority of the 21-key real-world settings shape.
  - User's `~/.claude/commands/*.md` and `~/.claude/agents/*.md` content — byte-identical (SHA-256) before and after install (via `mv` + symlink, not copy). R17 round-trip test proves this.
  - V1 statusline mechanism — read-only, carries forward unchanged (R16).
  - Test harness $HOME isolation + macOS PYTHONPATH leak escape — carries forward unchanged (V1 substrate).
  - `~/.claude/plugins/installed_plugins.json` — V2 reads it (for R22 self-identification) but never writes to it. Plugin installation is the marketplace's job.

---

## Risks & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| U1 reload-matrix Row 1 reveals `/reload-plugins` doesn't purge model-context descriptors | Med | High (thesis-test fail) | Surface to Shawn before continuing planning; reframe V2 as "use Claude Mode in long sessions; restrictive modes only at session start" if confirmed. Documented in U1's verification step. |
| `mcpServers` requires restart per U1 row 5/6, breaking the swap-and-reload UX | Med | Med | Drop `mcpServers` from `PLUGIN_OWNED_KEYS_V2`; defer to V2.0.x dot-release once a workaround is settled. |
| Multi-worktree race condition under flock contention produces user-visible delay | Low | Low | Perf test baseline for flock-acquire latency; no-op fast path avoids the rebuild when not needed. |
| User's `~/.claude/commands/` files are silently destroyed by a subtle move-then-symlink failure | Low | Critical | Test-first install path (U6) with SHA-256 verification of every file's content post-install. R13 lint enforces no destructive verbs at user paths. R17 round-trip test catches any destruction. |
| Path-traversal exploit slips through R7 validation | Low | Critical | Test-first U8 with attack fixtures (`../`, absolute paths, symlink-in-staging escape). Lint extension covers any `realpath`-bypass attempt. |
| R28 violated by a future maintainer adding `hooks` to `PLUGIN_OWNED_KEYS_V2` | Low | Critical (RCE vector) | Lint test asserts `hooks` is NOT in the merge engine's key list; written into `tests/integration/r19-lint.test.sh`. Comment in `lib/live-settings-merge.py` constant declaration cites R28 with rationale. |
| Drift-aware uninstall (R17) restores pristine over user's important post-install settings | Low | High (user data loss) | Default to Y (preserve) at the prompt; explicit named diff before any restore; never silently overwrite. Test covers both branches. |
| Claude Code harness drops a relied-upon contract (PostToolUse JSON shape, UserPromptSubmit env, SessionStart shim) | Med | Med (V2 breaks) | SessionStart contract anchor logged to `~/.claude/modes/.session-start.log` per V1's adv-11 pattern — gives a discoverable surface for diagnosing future harness changes. |
| Slash-command arg substitution silently corrupts an inline `$1` in a `.md` body | Med | Med (silent feature breakage) | Project-standard: `.md` bodies contain only prose + single-line `lib/*.sh` invocations. R13 lint extended to catch `$[0-9]` or `$ARGUMENTS` in `commands/*.md` outside the canonical invocation line. |

### Dependencies / Prerequisites

- **macOS-specific.** V2 inherits V1's macOS pin (`/usr/bin/python3` with PyYAML; APFS same-filesystem mv atomicity; flock semantics). Linux portability is best-effort but not gated; tests run on macOS.
- **Bash 3.2.** V1 pinned to macOS-shipped bash; V2 inherits. No bash 4+ features (associative arrays, `${var,,}`, etc.).
- **Claude Code 2.1.x harness contracts.** `enabledPlugins` Zod schema (verified — `Record<plugin-name@marketplace, true|false>`), `/reload-plugins` mid-session reload (verified empirically for settings.json file changes; U1 matrix confirms scope for plugin-owned keys), PostToolUse JSON shape (verified — `{tool_input, tool_response}` env), UserPromptSubmit JSON shape (verified — `{session_id, prompt}` env).
- **Local-only git repo.** Per `feedback_ce_worktree_no_remote`, V2 implementation cannot use `isolation: "worktree"` for parallel subagent dispatch — must downgrade to shared-directory with no-stage/no-commit constraints.

---

## Phased Delivery

### Phase 1: Foundation (U1, U2, U3)
- Empirical reload-matrix (U1) is Day-1 empirical work; produces a results artifact that U4 references
- U2 (hook registration + manifest restructure) and U3 (YAML schema v2 + validator + examples) do NOT consume U1 results — all three units are parallel-safe from Day 1
- No user-facing functionality yet; foundation for everything that follows

### Phase 2: Core mechanism + user-catalog substrate (U4, U5, U6, U7, U8)
- Merge engine (U4) is the Phase-2 gate; depends on U1 results (final PLUGIN_OWNED_KEYS_V2) and U3 (schema reader)
- After U4 lands: U5 (`/mode:set` orchestration) and U8 (symlink rebuild + R7) are parallel-safe — both depend on U4 + U3 and don't block each other
- U6 (install) depends on U4 + U8 (install-time symlink construction uses U8's validated rebuild library)
- U7 (uninstall) depends on U4 + U8 (move-back uses U8's path-traversal validator) and U6 (round-trip test in U7 exercises U6's install path)
- After Phase 2, `/mode:set` works end-to-end for both plugin-catalog AND user-catalog scoping; install + uninstall are usable

### Phase 3: Hooks + UX + wrap-up (U9, U10, U11, U12, U13)
- U9 (worktree reconciliation R27) depends on U8 (rebuild library)
- U10 (prose injection R25) depends on U3 only — parallel-safe with U9
- U11 (adoption paths R20) depends on U8 (`/mode:adopt` calls symlink-rebuild's validator) and U10 (markers consumed by prose hook)
- U12 (mode-author skill + status + registry) depends on U3 (schema + validator) and U4 (live settings reader) — parallel-safe with U9/U10/U11
- U13 (README + lint + perms test + statusline carry + docs/solutions seed) is the wrap-up; depends on U1–U12 for the lint scan + perms test scope

**Parallelism analysis for ce-work fan-out:**
- **Day 1**: U1 + U2 + U3 all parallel (U2 and U3 do not consume U1 results, despite both being labeled "Phase 1"; the only thing U1 gates is U4's PLUGIN_OWNED_KEYS_V2 constant). Three concurrent agents.
- **After U1 + U3 land**: U4 (sequential; depends on both).
- **After U4 lands**: U5 + U8 parallel (two concurrent agents).
- **After U8 lands**: U6 (sequential; needs U4 + U8). Once U6 lands: U7 (sequential; needs U6).
- **After U8 lands**: U9 + U10 + U12 parallel (three concurrent agents, all depend on U8 or U3 or U4).
- **After U8 + U10 land**: U11 (sequential).
- **After U1–U12 all land**: U13 (sequential wrap-up).
- **Realistic critical path**: U1 → U3 → U4 → U8 → U6 → U7 → U13. U1 alone may take a full day (7 fresh sessions for the matrix). Total: implementer-estimated 5-8 working days for a single implementer.

---

## Documentation Plan

- `README.md` — V2 install + usage + safety section (U13)
- `docs/architecture.md` — V2 hook surface table + mechanism diagrams (U13)
- `docs/plans/2026-05-XX-reload-matrix-results.md` — empirical artifact from U1
- `docs/solutions/` — seed directory for post-ship `/ce-compound` captures (flock pattern, mode-as-settings-overlay pattern, drift-aware-uninstall pattern)
- `docs/brainstorms/2026-05-17-v2-modal-harness-requirements.md` — origin (preserved verbatim, plan references it throughout)

---

## Operational / Rollout Notes

- **Single-user, single-machine rollout.** V2.0 is Shawn's V0 install + marketplace publication. No staged rollout; the publication itself is the rollout event.
- **Pre-publication self-identification fallback.** Per Q2 resolution, the plugin self-identifies via `installed_plugins.json` installPath-match during development + private installs. The canonical `claude-modes@<official-marketplace>` identifier is hardcoded once known.
- **Empirical reload-matrix runs as Day 1.** Per U1 — results dictate `PLUGIN_OWNED_KEYS_V2` and may surface a thesis-reframing trigger.
- **Test harness preserves V1 isolation contract.** Every new V2 test under `tests/integration/*` MUST `claude_modes_test::setup` before touching anything (V1 carry — hash-before-vs-after verification in `tests/run.sh`).
- **Code review loop per `feedback_review_loop_catches_narrowing`.** V2 PR runs `/ce-code-review` in a loop until verdict is green. Security-critical units (U4, U7, U8, U9, U11) get extra scrutiny.
- **Post-ship learnings capture.** Per `feedback_review_loop_catches_narrowing` adjacent + learnings-researcher recommendation, run `/ce-compound` after V2 ships to seed `docs/solutions/` with the flock pattern, the mode-as-settings-overlay pattern, and the drift-aware-uninstall pattern.

---

## Alternative Approaches Considered

- **Lean V2.0 (settings-swap only; defer user-catalog to V2.1).** Considered + rejected during ce-plan Phase 0 scope check. Justification: AE3 (the load-bearing user-facing acceptance example) requires user-catalog scoping; deferring it leaves V2.0 without a stranger-adoption story for users who care about command-scoping per mode. Shawn confirmed full V2.0 scope.
- **Hybrid V2.0 (settings-swap + manual `/mode:adopt`).** Considered + rejected. Same justification as lean — without the install-time move-then-symlink (R3), there's no user-catalog mechanism for `/mode:adopt` to operate on. Half-measure that doesn't close any success criterion.
- **`hooks` as plugin-owned with a diff/confirm gate (alternative to R28).** Considered + rejected during doc-review gate 3. Justification: V2.0's example modes don't demonstrate a need for mode-scoped hooks; the injection surface (shared YAML → RCE) outweighs the demonstrated value. V2.1 may revisit with a diff/confirm or allowlist mechanism if a use case emerges.
- **Modes as user-global (drop R6 entirely; per-branch is a documentation footnote).** Considered + rejected during doc-review gate 1. Justification: Shawn's actual workflow (parallel worktree CE fan-out across feature branches) benefits from per-branch mode intent. R27's flock+reconciliation reconciles per-branch intent with per-machine mechanism without requiring a Claude Code harness change.
- **PreToolUse blocking + UserPromptSubmit injection (V1 mechanism extended).** Rejected as origin Key Decision. Justification: V1's parasitic gate is structurally limited to block-after-attempt because the harness exposes a flat catalog. V2's settings-swap shrinks the catalog at the harness level — different solution shape, not an extension.

---

## Success Metrics

(carried verbatim from origin's Success Criteria)

- **Public adoption signal:** within 6 months of V2.0 marketplace publication, at least one non-Shawn user has installed V2 and reports it useful (marketplace install count + retention, or direct testimonial). If zero non-Shawn users adopt, the abstraction's universal appeal is wrong — but Shawn keeps using it personally as the V0 user.
- **Shawn V0 adoption:** Shawn has reached for `/mode:set` (any mode, including switches between non-Claude modes) on at least one real project within 30 days post-install.
- **/doctor pressure dissolves:** in a non-Claude mode, `/doctor` no longer reports descriptor-budget truncation. Gated on U1's Row 1 result.
- **Downstream handoff — planning:** this plan (you're reading it) was produced by `/ce-plan` from the requirements doc without inventing product behavior. Met.
- **Downstream handoff — uninstall credibility:** `tests/integration/install-uninstall-roundtrip.test.sh` proves byte-identical recovery for the clean branch and preserved-edits behavior for the drifted branch.

(See origin: docs/brainstorms/2026-05-17-v2-modal-harness-requirements.md, Success Criteria)

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-17-v2-modal-harness-requirements.md](../brainstorms/2026-05-17-v2-modal-harness-requirements.md)
- **V1 origin:** [docs/brainstorms/2026-05-15-modes-as-infrastructure-requirements.md](../brainstorms/2026-05-15-modes-as-infrastructure-requirements.md)
- **V1 plan:** [docs/plans/2026-05-15-001-feat-modes-as-infrastructure-plan.md](2026-05-15-001-feat-modes-as-infrastructure-plan.md)
- **V1 substrate:** git tag `v0.1.0-experiment` (this repo) — access via `git show v0.1.0-experiment:<path>`
- **Canonical flock pattern:** `Slate/plugins/docs/solutions/architecture-patterns/silent-failure-when-singleton-assumption-breaks-2026-05-09.md` (slate-weekly-gist origin) — adopted verbatim for U9 R27 reconciliation
- **Relevant institutional learnings:** `~/.claude/projects/-Users-shawnroos/memory/feedback_slash_command_arg_substitution.md`, `feedback_predicted_bugs_need_tests_not_conventions.md`, `feedback_deterministic_over_probabilistic_v1.md`, `feedback_subagent_write_verification.md`, `feedback_ce_worktree_no_remote.md`, `feedback_review_loop_catches_narrowing.md`
- **Runtime ground truth:** `~/.claude/settings.json` (21-key shape), `~/.claude/plugins/installed_plugins.json` (R22 self-identification source)
