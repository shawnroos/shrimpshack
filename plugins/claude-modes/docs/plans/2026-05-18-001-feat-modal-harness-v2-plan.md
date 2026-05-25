---
title: "feat: claude-modes V2 — Modal Harness (Cascade Architecture)"
type: feat
status: active
date: 2026-05-18
origin: docs/brainstorms/2026-05-17-v2-modal-harness-requirements.md
supersedes: docs/plans/2026-05-17-001-feat-modal-harness-v2-plan.md
---

# claude-modes V2 — Modal Harness (Cascade Architecture)

## Overview

> **Scope amendment 2026-05-18 (post-binary-verification):** Empirical inspection of Claude Code 2.1.143's `/reload-plugins` implementation (`refreshActivePlugins`) confirms it mutates the harness's React `appState` in-session — BUT only for the plugin layer (`enabledPlugins` + plugin-sourced skills/agents/commands/hooks/MCP/LSP). Non-plugin settings (`permissions`, `env`, `mcpServers` from `.mcp.json`, hooks declared at userSettings/projectSettings/localSettings layers) do NOT hot-reload; changes require a new session. **V2.0 therefore narrows `PLUGIN_OWNED_KEYS_V2` to `["enabledPlugins"]` only.** The cascade architecture survives; the cascade payload narrows to the one key /reload-plugins actually applies in-session. Other keys (hooks/permissions/env/mcpServers) drop from V2.0's plugin-owned set and remain user-managed via direct `~/.claude/settings.json` editing. This scope cut simplifies U4 (cascade engine has one key to merge), eliminates R28's runtime assertion concern (hooks aren't in the cascade), and dissolves several P0/P1 doc-review findings about non-enabledPlugins behavior. References to hooks/permissions/env/mcpServers below should be read as "deferred to V2.0.1 or later."

V2 ships a **cascading configuration system** rather than a single settings overlay. Modes are one tier in a 5-tier cascade (V2.0):

1. `~/.claude/settings.json` — user-owned, untouched by plugin
2. `~/.claude/modes/_global.yaml` — machine-wide baseline; hooks live here
3. `~/.claude/modes/<mode>.yaml` — global mode definitions; cannot declare hooks
4. `<repo>/.claude/modes/_repo.yaml` — per-repo baseline (optional); hooks permitted
5. `<repo>/.claude/modes/<branch-slug>.mode` — per-branch active-mode pointer

(V2.1 will add `<repo>/.claude/modes/<mode>.override.yaml` as tier 5; current tier 5 is reserved.)

`/mode:set` cascades these tiers (add-by-default; `disable:` blocks for subtract) and writes the result to `<repo>/.claude/settings.local.json`. Claude Code's native cascade (`~/.claude/settings.json` → `<repo>/.claude/settings.json` → `<repo>/.claude/settings.local.json`) then applies the repo-local override for this session — concurrent repos in different modes are filesystem-disjoint by construction.

V1 (parasitic PreToolUse block-after-attempt) is archived at git tag `v0.1.0-experiment`. This plan supersedes `docs/plans/2026-05-17-001-feat-modal-harness-v2-plan.md`, which assumed a single-overlay-per-machine mechanism and got two structural concerns wrong: it provided no way for "hooks that apply across all modes" and no isolation between concurrent repos in different modes.

---

## Problem Frame

Claude Code exposes a single flat descriptor surface. Every plugin's agents, skills, and commands compete for the same context budget regardless of work mode. V1 blocked dispatch via PreToolUse hooks but couldn't reshape what the model saw. V2's earlier draft fixed this with a settings-overlay-per-mode approach, but assumed one user with one repo. Real users work across many repos in different states; hooks/MCP servers/env vars that apply "always" don't fit cleanly into per-mode YAMLs.

V2's cascade resolves both: a single `_global.yaml` carries always-active config (including hooks); each repo gets its own compiled settings.local.json; Claude Code's existing cascade does the heavy lifting at session-start without claude-modes needing to own the user's machine-global settings.json.

(See origin: docs/brainstorms/2026-05-17-v2-modal-harness-requirements.md, Problem Frame + Cascading Configuration Model.)

---

## Requirements Trace

Origin: 32 requirements (R1–R32), 6 actors (A1–A6), 5 flows (F1–F5), 10 acceptance examples (AE1–AE6 a/b/c, AE8–AE10; AE7 deferred to V2.1 with R23).

**Active in V2.0:** R1–R20, R22, R24–R30, R32. (28 active requirements.)
**Deferred:** R21 (superseded by cascade — content redistributed), R23 (drift detection — V2.1), R31 (override.yaml — V2.1).

**Origin actors:** A1 (mode user, Shawn V0), A2 (mode author), A3 (stranger adopter), A4 (Claude model), A5 (Claude Code harness), A6 (Anthropic).
**Origin flows:** F1 (install — U6, U8), F2 (set mode — U5, U8, U9), F3 (author mode — U12), F4 (return to Claude Mode = clear mode — U5), F5 (uninstall — U7).
**Origin AEs:** AE1 (R3, R12, R17), AE2 (R2, R8), AE3 (R5, R7, R11), AE4 (R13, R17 — lint), AE5 (R22), AE6 a/b/c (R20), AE8 (R29 + cross-repo isolation), AE9 (R1 disable + R29), AE10 (R32 + multi-repo uninstall).

---

## Scope Boundaries

### Deferred for later (carried from origin)

- Repo mode override (R31 — `<mode>.override.yaml`)
- Drift detection in `/mode:status` (R23)
- Snapshot mode capture (`/mode:snapshot`)
- Compositional modes (stacking) and mode inheritance
- Per-mode hook overrides beyond cascade-tier semantics
- Convention-driven mode inference (auto-suggest by branch name)
- Usage telemetry / coverage weighting
- Shared / team-level modes
- Mount/unmount semantics for individual agents within an enabled plugin
- `/mode:rollback` first-class command (vs. `unmodes.sh` full uninstall)
- Auto-reload on settings file change
- Per-mode color in statusline
- User-catalog manifest glob patterns (V2.0 ships filename-list only)

### Outside this product's identity (carried from origin)

- Not a workflow enforcement engine
- Not a plugin manager
- Not a memory or personalization system
- Not a state machine for project lifecycle
- Not multi-user or multi-tenant
- Not a replacement for skills
- Not a way to write to third-party plugin files (R19 invariant generalized to "no destructive verbs on user paths")

### Deferred to Follow-Up Work

- V2.0 ships in a single PR off `feat/modes-v2` (branch reused from previous plan). No work intentionally split across other repos.
- Post-publication marketplace name resolution for R22 (synthetic identifier strategy ships in V2.0; canonical identifier hardcoded post-publication).

---

## Context & Research

### Relevant Code and Patterns

V1 substrate at git tag `v0.1.0-experiment`. Access via `git show v0.1.0-experiment:<path>`. Carry-forward (mostly verbatim, occasionally lightly revised):

- `lib/validate-mode-name.sh` — slugifier + name validator; reserve `claude`, `_global`, `_repo` as reserved tokens
- `lib/mode-yaml.sh` — Python sys.argv heredoc contract; update `validate_schema_version` to accept `2`; extend `get_field` for cascade tier paths and `disable:` blocks
- `lib/write-mode-yaml.sh` — mechanical validation before write; extended for cascade tier validation (refuse hooks in tier 3)
- `lib/audit.sh` — append-only with 0600 chmod-on-append; pattern unchanged
- `lib/inject-heuristic.sh` + `scripts/on-prompt-submit.sh` — UserPromptSubmit hook contract; carry forward for R25 prose injection
- `scripts/on-session-start.sh` — SessionStart shim with presence gate; carry forward and extend for R20 + R27
- `scripts/statusline.sh` family — yellow segment + OSC 2 title; carry verbatim
- `tests/helpers/test-helpers.sh` — `$HOME` isolation + macOS PYTHONPATH leak; carry verbatim; extend hash-check scope per previous plan-review finding
- `tests/run.sh` — hash-before-vs-after isolation check; extend scope to `~/.claude/{modes,commands,agents}` + `~/.claude/settings.json` + `~/.claude/settings.json.pristine`
- `tests/integration/r19-lint.test.sh` — positive+negative fixture lint pattern; V2 extends to Python destructive verbs

### Institutional Learnings

- `Slate/plugins/docs/solutions/architecture-patterns/silent-failure-when-singleton-assumption-breaks-2026-05-09.md` — canonical flock pattern. V2 adopts the FD-lifetime-equals-critical-section contract, but Python is the orchestrator throughout (no `os.execvp` bridge). See U9 architectural note.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_slash_command_arg_substitution.md` — slash-command `.md` bodies pre-substitute `$0/$1/$ARGUMENTS`; every V2 slash command's `.md` body is prose + single-line `"${CLAUDE_PLUGIN_ROOT}/lib/<verb>.sh" "$ARGUMENTS"`.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_predicted_bugs_need_tests_not_conventions.md` — security-critical test fixtures named in plan are non-negotiable; may not be downgraded to "convention-enforced" during code review.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_deterministic_over_probabilistic_v1.md` — load-bearing security enforcements are mechanical, not text-based grep alone. Applies to R28 (runtime assert in cascade engine) and R7 (realpath check, not regex).
- `~/.claude/projects/-Users-shawnroos/memory/feedback_subagent_write_verification.md` — every install/uninstall integration test must read back filesystem (stat, readlink, sha256) after the operation.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_ce_worktree_no_remote.md` — claude-modes is local-only git; parallel subagent dispatch must downgrade to shared-directory with no-stage/no-commit constraints.
- `~/.claude/projects/-Users-shawnroos/memory/feedback_review_loop_catches_narrowing.md` — loop `/ce-code-review` to green; security-critical paths get extra scrutiny.

### External References

None used. Local research surfaced sufficient direct examples for every pattern.

---

## Key Technical Decisions

- **5-tier cascade with add-by-default and explicit `disable:` blocks.** Compile order: tier 1 (user settings, read-only) → tier 2 (`_global.yaml`) → tier 3 (active mode YAML) → tier 4 (`_repo.yaml`, optional) → tier 6 (per-branch pointer; selects tier 3). Tier 5 reserved for V2.1 (R31 override.yaml). Each tier ADDS; tiers 3 and 4 may carry `disable:` to subtract from prior tiers. **V2.0 narrowed scope: only `enabledPlugins` flows through the cascade per the binary-verified reload contract. Other keys (hooks/permissions/env/mcpServers) are user-managed outside the plugin's awareness in V2.0.**

- ~~Hooks-permitted tiers: 2 and 4 only.~~ **Moot under the V2.0 scope cut.** `hooks` is not in `PLUGIN_OWNED_KEYS_V2`; the cascade engine doesn't read or write hooks. Users manage hooks via `~/.claude/settings.json` directly, same as without claude-modes installed. R28's runtime assertion concern dissolves (no hook injection vector through the cascade at all). The trusted-repos.txt mechanism remains useful as defense-in-depth for foreign repos enabling malicious plugins via `_repo.yaml`'s enabledPlugins, but no hooks-in-_repo.yaml RCE vector exists in V2.0.

- **Compiled cascade output writes to `<repo>/.claude/settings.local.json`.** Claude Code's native cascade (`~/.claude/settings.json` → `<repo>/.claude/settings.json` → `<repo>/.claude/settings.local.json`) applies the repo-local file as override. **The plugin never writes to `~/.claude/settings.json`** — the user owns that file from install through uninstall. Eliminates the trust-ask of "let an unknown plugin manage your machine-global settings." Under V2.0 scope cut, the only key actually modified in settings.local.json is `enabledPlugins`.

- **`_global.yaml` is auto-generated at install from `~/.claude/settings.json`'s `enabledPlugins` key only.** Under V2.0 scope cut, `_global.yaml` carries only the user's pre-install `enabledPlugins`. Other settings (hooks, env, permissions, mcpServers) stay in `~/.claude/settings.json` untouched. Users edit `_global.yaml` to set machine-wide enabledPlugins baseline; everything else stays where they already manage it. Day-zero behavior is observationally identical to pre-install (tier 1's settings.json keeps all keys; tier 2's _global.yaml adds the enabledPlugins baseline; cascade output only changes enabledPlugins).

- **"Claude Mode" is the no-modes-active state.** When tier 6's per-branch pointer says nothing (or doesn't exist for this branch), the cascade applies only tiers 1, 2, and 4 — no tier-3 contribution. `/mode:clear` removes the per-branch pointer. There is no static `~/.claude/modes/claude.yaml` file (resolves the frozen-vs-dynamic ambiguity from the previous plan's coherence review).

- **Install registry at `~/.claude/modes/.installed-repos.txt`** tracks which repos have had `<repo>/.claude/settings.local.json` written by claude-modes. Append-only during plugin lifetime. On uninstall: registry is read, each listed repo's settings.local.json is removed (only if content matches cascade-engine signature). Per-repo cleanup is comprehensive.

- **Per-repo isolation is automatic.** Two repos open simultaneously each write their own `<repo>/.claude/settings.local.json` — filesystem-disjoint. R27 worktree reconciliation scope narrows to within-a-repo (worktrees of the same repo share the same settings.local.json + user-catalog symlinks); cross-repo concurrent sessions never contend.

- **User-catalog (`~/.claude/commands/`, `~/.claude/agents/`) remains user-global.** Claude Code provides no repo-level command override path. The move-then-symlink mechanism (R3, R7) stays user-global; mode-scoping of user commands applies across all sessions on the machine. Cross-repo mode-scoping of commands is deferred to V2.1 (would require either a harness change or session-isolated symlink set).

- **Slash-command argument substitution: `.md` body holds NO `$`-bearing bash.** Every V2 slash command `.md` file is prose + single-line `"${CLAUDE_PLUGIN_ROOT}/lib/<verb>.sh" "$ARGUMENTS"`. All `$1`, `$@`, `${var:-default}` logic in `lib/*.sh`.

- **0600 permissions via born-at-0600 atomic-write idiom.** `(umask 077 && mktemp ... && write ... && mv ...)`. Eliminates TOCTOU window between mv and retroactive chmod. Files covered: `_global.yaml`, `settings.json.pristine`, `.installed-repos.txt`, `.trusted-repos.txt` (per the new tier-4 trust gate), `<repo>/.claude/settings.local.json`, `<repo>/.claude/modes/.cascade-meta.json` (the cascade output sidecar with content-hash fingerprint), `.audit.log`. (Note: `<repo>/_repo.yaml` is user-authored; plugin reads it 0600-permission-agnostic. Plugin does NOT chmod user-authored files.)

- **chmod failure is fail-closed.** If a re-assert chmod 0600 fails (e.g., NFS without chmod support), the write is FAILED — rollback the mv, audit the failure, exit non-zero.

- **`/mode:set` is idempotent and crash-safe** (R26). Sentinel `.mode-set.in-progress` plus deterministic re-apply.

- **`/mode:setup` is also idempotent and crash-safe.** Sentinel `.setup.in-progress`; each install step is re-runnable; resume-on-orphaned-sentinel.

- **U9 worktree reconciliation: Python orchestrator holding flock for entire critical section.** No `os.execvp` bridge. Same correctness as slate-weekly-gist canonical pattern but cleaner architecture given V2's bash-heavy substrate. Python startup ~25-40ms is acceptable at session-open frequency.

- **Test posture: test-first for security-critical units** (U4 cascade engine with R28 + disable + tier ordering, U7 drift-aware uninstall, U8 path-traversal, U9 flock race, U11 adoption).

---

## Open Questions

### Resolved During Planning

- **Q1: schema_version 1 vs 2 collision.** V1 YAMLs archived to `~/.claude/modes/.v1-archive/` at V2 install with one-time `<system-reminder>`.
- **Q2: marketplace identifier for R22 self-check.** Three-tier strategy: post-publication hardcoded canonical; pre-publication with `installed_plugins.json` listing the plugin → parse and match `realpath(installPath)` against `realpath(CLAUDE_PLUGIN_ROOT)`; pre-publication first-run where registry doesn't yet list → synthesize `claude-modes@local-dev`.
- **Q3: user-catalog manifest YAML shape.** Filename list for V2.0; globs are V2.1 extension. Shape: `user_catalog: { commands: [str], agents: [str] }`.
- **Q5: detached HEAD / no-branch / no-repo behavior.** Detached HEAD slugs to `detached-<short-sha>`; no-repo falls back to "user-global active mode, no per-branch record"; R27 reconciliation gracefully degrades.
- **Cascade merge semantics**: add-by-default; `disable:` blocks for subtract. Tier 3 and tier 4 may carry disable blocks.
- **Claude Mode**: no-modes-active state. No static `claude.yaml`. `/mode:clear` removes per-branch pointer.
- **Hooks ownership**: tiers 2 and 4 only; mode YAMLs cannot declare hooks.
- **Per-repo isolation**: automatic via Claude Code's native settings cascade; no plugin-side cross-repo locking needed.

### Deferred to Implementation

**Original planning-time deferrals:**

- **Q4: Can `/reload-plugins` be programmatically triggered from a hook?** Empirically deferred — U1 matrix surfaces this.
- **Exact `disable:` block YAML schema.** Sketched in brainstorm; final shape (per-key list vs per-key object) decided during U3.
- **How `_global.yaml` reflects updates from later Claude Code versions adding new top-level settings.json keys.** Cascade silently works around staleness (Claude Code's native cascade applies user's settings.json key since settings.local.json doesn't override it). Worth documenting in README so users don't think the plugin is silently dropping their newly-added top-level settings.

**Surfaced by plan-doc-review (2026-05-18). RESOLVED per research:**

- ~~Exact format of cascade engine's signature for repo settings.local.json verification (P0).~~ **Resolved 2026-05-18:** sidecar file `<repo>/.claude/modes/.cascade-meta.json` with content-hash fingerprint, direnv pattern. JSONC comment rejected (Claude Code parser is strict JSON per issues #29370/#17968/#12688); embedded `$claude_modes` key rejected (Claude Code v1.0.82+ rejects unknown top-level fields per issue #5886). Sidecar is the only mechanism compatible with Claude Code's settings parser AND provides content-integrity discrimination for uninstall.

**P2 — manual decisions for the implementer:**

- [Affects U5 / mode:clear][coherence] Tier-4 inclusion semantics after `/mode:clear`. Plan states tiers 1+2+4 apply after clear (mode-clear-with-_repo.yaml = different state from mode-clear-without). This is INTENTIONAL — `_repo.yaml` represents "always-on while in this repo regardless of mode," so it persists. Documented in F4 brainstorm revision. Implementer should not "fix" this asymmetry without product check-in.
- [Affects U9][coherence + feasibility] SessionStart hook's `$PWD` repo-detection: use `git -C "$PWD" rev-parse --show-toplevel`. On failure (no-repo case), reconciliation degrades to user-catalog-only (no settings.local.json reconciliation), audit log records `no-repo session — tier 4 skipped`. U1 reload-matrix should verify the `$PWD` contract at hook invocation time empirically.
- [Affects U4 permissions diff/confirm gate][adversarial F7] Permissions revocation foot-gun. Under additive-by-default cascade, a mode wanting to RESTRICT permissions cannot do so via positive declaration — must use `disable:` block. README + U12 mode-author skill MUST include a worked permissions-revocation example with the callout: "you can only EXPAND with positive declarations; SUBTRACT requires `disable:`." Otherwise mode authors silently broaden privilege.
- [Affects pristine settings.json][security-lens 6] Stale-credential exposure window. Pristine carries pre-install creds for entire install lifetime at 0600. If user rotates credentials post-install, pristine carries stale values. Implementer adds to U6 a one-time notice: "A copy of your settings.json will be saved as settings.json.pristine for forensic comparison. If it contains API keys or tokens you've since rotated, you may want to delete it with `rm ~/.claude/settings.json.pristine` after verifying the install." Default behavior unchanged.

**P3 — clarifications:**

- [Affects Overview][coherence] Tier numbering in Overview reads "5-tier cascade" followed by items 1,2,3,4,(5 reserved),6. Either restate as "5 active tiers (1,2,3,4,6); tier 5 reserved for V2.1" or revise the list to avoid the visible numbering gap.
- [Affects multiple sections][coherence] Terminology: standardize on "cascade engine" throughout; "merge engine" appears once in U4's "Replaces the previous plan's 'live-settings merge engine.'" historical reference only.
- [Affects Risks table][scope-guardian F1] Move "User commits settings.local.json to source control" from risks table to U13 README guidance (folds with the `_repo.yaml` gitignore note). Risk row is low-cosmetic; mitigation is documentation.
- [Affects test naming][scope-guardian F2] Clarify cross-repo-isolation.test.sh shape: filesystem-only validation (two tmpdir repos, run cascade in each, assert distinct settings.local.json paths with distinct content), NOT spawning live Claude sessions. Add this to the test scenario description.
- [Affects U6 R32 install registry][coherence + feasibility] Install registry de-dup semantics: append-only at write; read-time dedup (uninstall iterates with set semantics). Worst-case duplicate entries are idempotent on read; the registry grows unboundedly but bounded by repo count. Document explicitly in U6's narrative.
- [Affects U5 mode-set crash recovery test][coherence] Add explicit test: cascade compile mid-write is interrupted; re-run /mode:set converges; settings.local.json is either pre-write or post-write atomic state, never partial (verifies the atomic mv contract under crash).

---

## Output Structure

```text
claude-modes/
├── .claude-plugin/
│   └── plugin.json                         # U2 (bump to 0.2.0)
├── .claude/
│   ├── hooks/
│   │   └── hooks.json                      # U2 (drop PreToolUse, add PostToolUse Write)
│   └── skills/
│       └── mode-author/
│           └── SKILL.md                    # U12 (cascade-aware Phase 2.5)
├── lib/
│   ├── audit.sh                            # carry from v0.1.0-experiment
│   ├── validate-mode-name.sh               # carry; reserve _global, _repo
│   ├── mode-yaml.sh                        # U3 (schema v2 + disable: block reader)
│   ├── write-mode-yaml.sh                  # U3 (cascade-tier-aware validation)
│   ├── set-mode.sh                         # U5 (cascade engine call + sentinel)
│   ├── active-mode.sh                      # U5 (cascade tier-6 reader)
│   ├── cascade-engine.sh                   # U4 NEW — orchestrates 5-tier compile
│   ├── cascade-engine.py                   # U4 NEW — Python helper for tier merge
│   ├── apply-mode.sh                       # U5 NEW — /mode:apply (rarely used post-cascade)
│   ├── symlink-rebuild.sh                  # U8 — user-catalog rebuild
│   ├── symlink-validate.py                 # U8 — realpath path-traversal check (R7)
│   ├── adopt-file.sh                       # U11 — /mode:adopt
│   ├── install-registry.sh                 # U6 NEW — append-only repo tracking
│   ├── reconcile-symlinks.py               # U9 — SessionStart Python orchestrator + flock
│   ├── inject-prose.sh                     # U10 — R25 prose injection
│   ├── status.sh                           # U12 — /mode:status w/ cascade tier visibility
│   ├── registry.sh                         # U12 — /mode:registry
│   └── statusline-dispatcher.sh            # carry
├── scripts/
│   ├── on-post-tool-use.sh                 # U11 NEW — Write matcher consent (R20)
│   ├── on-prompt-submit.sh                 # U10 (R25 prose injection)
│   ├── on-session-start.sh                 # U9 + U11 (Python invocation)
│   ├── setup.sh                            # U6 NEW — /mode:setup with cascade
│   ├── unmodes.sh                          # U7 NEW — registry-driven uninstall
│   ├── restore-claude-modes.sh             # U7 NEW — R22 wedge recovery
│   ├── statusline.sh                       # carry
│   ├── install-statusline.sh               # carry
│   └── uninstall-statusline.sh             # carry
├── commands/
│   ├── set.md                              # U5
│   ├── clear.md                            # U5 NEW — /mode:clear (return to no-modes-active)
│   ├── status.md                           # U12
│   ├── setup.md                            # U6
│   ├── adopt.md                            # U11
│   ├── registry.md                         # U12
│   └── statusline.md                       # carry
├── examples/
│   ├── example-discovery.yaml              # U3 (schema_version: 2; tier-3 shape)
│   ├── example-delivery.yaml               # U3 (schema_version: 2; tier-3 shape)
│   ├── example-_global.yaml                # U3 NEW — example _global.yaml with hooks
│   └── example-_repo.yaml                  # U3 NEW — example _repo.yaml
├── tests/
│   ├── run.sh                              # carry + hash-scope extension
│   ├── helpers/
│   │   └── test-helpers.sh                 # carry
│   ├── unit/
│   │   ├── cascade-engine.test.sh          # U4
│   │   ├── symlink-validate.test.sh        # U8
│   │   ├── install-registry.test.sh        # U6
│   │   └── schema-version.test.sh          # U3
│   └── integration/
│       ├── install-uninstall-roundtrip.test.sh   # U6, U7 — clean + drifted + multi-repo
│       ├── cross-repo-isolation.test.sh           # U4, U5 — AE8
│       ├── cascade-disable-block.test.sh          # U4 — AE9
│       ├── symlink-path-traversal.test.sh         # U8 — R7
│       ├── settings-file-perms.test.sh            # U13 — R24 0600
│       ├── mode-set-crash-recovery.test.sh        # U5 — R26
│       ├── mode-setup-crash-recovery.test.sh      # U6 — /mode:setup idempotency
│       ├── worktree-mode-reconciliation.test.sh   # U9 — R27 (within-repo)
│       ├── mode-adopt.test.sh                     # U11 — R20
│       ├── prose-injection.test.sh                # U10 — R25
│       ├── no-destructive-rm.test.sh              # U13 — R13 lint (bash + Python)
│       ├── r22-self-enforcement.test.sh           # U4 — R22 + AE5
│       ├── r28-hooks-forbidden-in-mode.test.sh    # U4 — R28 cascade-engine assert
│       ├── multi-repo-uninstall.test.sh           # U7 — AE10 + R32
│       ├── perf.test.sh                           # carry + flock-acquire baseline
│       └── r19-lint.test.sh                       # extend
├── docs/
│   ├── brainstorms/
│   │   ├── 2026-05-15-modes-as-infrastructure-requirements.md
│   │   └── 2026-05-17-v2-modal-harness-requirements.md
│   ├── plans/
│   │   ├── 2026-05-15-001-feat-modes-as-infrastructure-plan.md
│   │   ├── 2026-05-17-001-feat-modal-harness-v2-plan.md       # SUPERSEDED by this plan
│   │   ├── 2026-05-18-001-feat-modal-harness-v2-plan.md       # this plan
│   │   └── 2026-05-XX-reload-matrix-results.md                # U1 artifact
│   ├── architecture.md                     # U13 — cascade tier diagram + hook surface
│   └── solutions/                          # U13 — seed for /ce-compound captures
└── README.md                               # U13 — cascade tiers + safety section
```

---

## High-Level Technical Design

> *Directional guidance for review, not implementation specification.*

**The cascade compile flow (U4):**

```text
/mode:set delivery (in <repoA>)
  │
  ├─ acquire flock(<repoA>/.claude/modes/.cascade-lock, LOCK_EX)
  ├─ write <repoA>/.claude/modes/.mode-set.in-progress sentinel
  │
  ├─ validate mode name; resolve tier-3 YAML
  ├─ read tier 1: load ~/.claude/settings.json (read-only; reference only)
  ├─ read tier 2: parse ~/.claude/modes/_global.yaml
  ├─ read tier 3: parse ~/.claude/modes/delivery.yaml
  │     │  validate R28: refuse if tier-3 declares `hooks`
  │     │  validate R22: assert claude-modes is in enabledPlugins (cascade total)
  ├─ read tier 4 (optional): if <repoA>/.claude/modes/_repo.yaml exists, parse
  ├─ read tier 6: <repoA>/.claude/modes/<branch-slug>.mode
  │     │  (here selects delivery as tier-3)
  │
  ├─ merge:
  │     start = {}
  │     start = apply_tier(start, tier_2_global)      # adds
  │     start = apply_tier(start, tier_3_mode)        # adds, applies disable:
  │     start = apply_tier(start, tier_4_repo)        # adds, applies disable:
  │     # result = compiled cascade output
  │
  ├─ permissions diff vs previous <repoA>/.claude/settings.local.json
  │     if new permissions added → prompt [y/N]
  │
  ├─ atomic write: tmp = mktemp <repoA>/.claude/(umask 077) → JSON → mv tmp settings.local.json
  ├─ append to ~/.claude/modes/.installed-repos.txt if repoA not already listed
  ├─ symlink-rebuild user-catalog (per active mode's user_catalog manifest)
  ├─ write per-branch state: <repoA>/.claude/modes/<branch-slug>.mode
  │
  ├─ audit: append swap event
  ├─ clear sentinel
  ├─ release flock
  │
  └─ signal user: "mode set to delivery — run /reload-plugins to apply"
```

**The merge contract:**

```text
For each tier in order [2, 3, 4]:
  For each key k in PLUGIN_OWNED_KEYS_V2:                 # enabledPlugins, env, permissions, mcpServers
    if k in tier:
      cascade[k] = cascade[k] ∪ tier[k]                   # add (deep-merge for objects, append for lists)
  For each k in tier.get('disable', {}):
    cascade[k] = cascade[k] − disable[k]                  # subtract specified keys

For 'hooks':
  Only tiers 2 and 4 may contribute hooks.
  Cascade engine enforces: hooks key not present in tier 3.
  Runtime enforcement in cascade-engine.py: `if "hooks" in tier_3: raise SecurityError("R28: ...")` → fail with R28 message.
  (NOT `assert` — `assert` is stripped by `python3 -O` / `PYTHONOPTIMIZE=1`. The explicit conditional raise survives the optimizer flag and is the mechanical R28 enforcement per feedback_deterministic_over_probabilistic_v1.)
```

**Key invariants enforced mechanically:**
- Mode YAMLs (tier 3) never contribute hooks (R28)
- Every symlink target passes `realpath` check before creation (R7)
- Every settings-derived write born at 0600 (R24)
- `/mode:set` idempotent — re-running converges (R26)
- `/mode:setup` idempotent — partial install resumes safely
- flock serializes within-repo concurrent cascade compiles (R27)

---

## Implementation Units

### Phase 1: Foundation

- U1. **Reload-semantics matrix (empirical, Day-1).** No code; produces `docs/plans/2026-05-XX-reload-matrix-results.md`. 7-row matrix per origin's "Resolve Before Planning" recipe. Same as previous plan. Gates U4's PLUGIN_OWNED_KEYS_V2 constant.

- U2. **Plugin manifest + hooks restructure.** Drop PreToolUse(Task|Skill|Agent); add PostToolUse(Write); keep UserPromptSubmit + SessionStart. Version → 0.2.0. Parallel-safe with U1.

- U3. **YAML schema v2 + cascade-aware validator + examples.** Update `validate_schema_version` to accept `2`. Extend `get_field` for `mechanism.*`, `disable.*`, and the `user_catalog` manifest. `write-mode-yaml.sh` enforces R22 (claude-modes in enabledPlugins) AND R28 (refuse `hooks` in tier-3 mode YAMLs at write time, as a first line of defense). Author `example-_global.yaml` and `example-_repo.yaml` showing the new tiers. Test fixtures: validator rejects schema_version 1 + V1 archive path; rejects hooks-in-mode-tier YAML at write; accepts well-formed cascade YAMLs. Parallel-safe with U1, U2.

### Phase 2: Core mechanism + user-catalog substrate

- U4. **Cascade engine (R5 + R28 + R29 + R30).** The heart of V2. Replaces the previous plan's "live-settings merge engine." Reads tiers 1, 2, 3, 4 (optional), 6 in order; applies add-by-default with `disable:` block subtract; writes compiled output to `<repo>/.claude/settings.local.json` via atomic born-at-0600 mv.

  **Files:**
  - Create: `lib/cascade-engine.sh` (orchestrator — flock, sentinel, write target)
  - Create: `lib/cascade-engine.py` (Python merge logic — sys.argv contract; runtime assert on R28)
  - Create: `tests/unit/cascade-engine.test.sh`
  - Create: `tests/integration/cascade-disable-block.test.sh` (AE9)
  - Create: `tests/integration/cross-repo-isolation.test.sh` (AE8)
  - Create: `tests/integration/r22-self-enforcement.test.sh` (AE5)
  - ~~tests/integration/r28-hooks-forbidden-in-mode.test.sh~~ — dropped (R28 enforcement moot under V2.0 scope cut; hooks aren't in cascade).
  - Create: `tests/integration/r30-hostile-repo-trust-gate.test.sh` (NARROWED scope: covers first-encounter prompt + hash-change re-prompt + N branch skips tier 4 + Y branch persists consent. Tests planted `_repo.yaml` with malicious enabledPlugins entry, not malicious hooks.)
  - Create: `tests/integration/v20-scope-cut-non-plugin-keys-ignored.test.sh` (verifies V2.0 contract: mode YAML with env/permissions/hooks/mcpServers in mechanism: section → cascade engine silently ignores those keys; only enabledPlugins flows through to settings.local.json).

  **Approach:**
  - **V2.0 narrowed scope:** `PLUGIN_OWNED_KEYS_V2 = ["enabledPlugins"]` — single key. The empirical binary inspection confirmed `/reload-plugins` only hot-reloads the plugin layer (via `refreshActivePlugins` mutating the harness's React appState); other keys (env, permissions, mcpServers, hooks) require a new session to take effect. Putting them in the cascade payload would create a misleading user contract — the user runs `/mode:set` + `/reload-plugins` expecting changes to apply, but only enabledPlugins actually does. V2.0 limits the cascade to what genuinely hot-reloads. Other keys are V2.0.1+ candidates contingent on harness improvements or a different reload mechanism. **The split `TIER_3_OWNED_KEYS` vs `TIER_2_4_OWNED_KEYS` is also moot under this scope cut** — there's only one key, and the R28 hooks-not-in-mode-tier invariant is enforced by absence (no hooks key in the cascade at all).
  - **Symlink-safety on tier-4 read** (still applies under V2.0 scope cut — `_repo.yaml` can still contain `enabledPlugins` with disable: blocks, so the symlink-attack-via-foreign-YAML-content vector remains). Before opening `<repo>/.claude/modes/_repo.yaml`, the cascade engine calls `os.lstat(path)` and refuses if the file is a symlink: `if stat.S_ISLNK(os.lstat(repo_yaml).st_mode): raise SecurityError("R30: _repo.yaml must not be a symlink — content must be in the repo's tree directly")`. Test fixture in `tests/integration/symlink-path-traversal.test.sh`: planted symlink `_repo.yaml` → fails with R30 SecurityError; regular file → succeeds.
  - **R28 hooks-enforcement is moot under V2.0 scope cut.** Hooks aren't in `PLUGIN_OWNED_KEYS_V2`; the cascade engine never reads or writes a `hooks` key from any tier. A mode YAML can declare `hooks: {...}` but the cascade engine ignores it (not in the owned-keys set), so it never reaches settings.local.json. No runtime assertion needed because the data path doesn't exist. **Static lint still extends to bash + Python files** per R13 — that's about destructive verbs on user-authored paths, separate from R28 hooks handling. The earlier "Python `assert` stripped by -O" concern is moot here because there's no assert at all.
  - Merge logic: for each tier in [tier_2, tier_3, tier_4], for each key in TIER_n_OWNED_KEYS, union into cascade result. For each tier's `disable:` block, subtract specified keys from cascade.
  - **Repo-root resolution (NEW per feasibility finding 2026-05-18):** every reference to `<repo>` in cascade engine logic resolves via `git -C "$PWD" rev-parse --show-toplevel`. If the command fails (no git repo, detached HEAD without a repo, running in `/tmp` etc.), the cascade compiles only tiers 1, 2, and 3 — tier 4 read is skipped (no `<repo>/.claude/modes/_repo.yaml` to read) and the compiled output is NOT written to a per-repo settings.local.json (instead, user-global behavior applies; the user-catalog symlink rebuild still proceeds since it's user-global). This is the "no-repo case" from Q5; previously underspecified for tier-4 read. Audit log records `no-repo session — tier 4 skipped, settings.local.json not written`.
  - **V2.0 simplified merge:** with `PLUGIN_OWNED_KEYS_V2 = ["enabledPlugins"]`, the cascade merges a single object — Claude Code's `enabledPlugins` is `Record<plugin-name@marketplace, true|false>`. Merge rule: **for each tier in [tier_2, tier_3, tier_4], merge enabledPlugins by key, later tiers overriding the boolean value for matching keys.** Tier 3 and tier 4 may carry `disable: { enabledPlugins: ["plugin-name@marketplace", ...] }` to subtract specific keys (after merge, those keys are removed entirely from the result, not set to false). This is the only merge semantic V2.0 needs.
  - **Why not the more general merge rules from earlier draft?** Earlier draft specified deep-merge for nested objects, append+dedupe for lists of scalars, append+dedupe-by-tuple for lists of dicts, etc. — to handle hooks/permissions/env/mcpServers. Under V2.0 scope cut, none of those types are in the cascade. The single-key payload (a flat object of `name@marketplace -> bool`) needs only key-merge + disable. Future V2.0.1+ scope expansion can reintroduce the richer rules as needed.
  - **Permissions diff/confirm gate:** after cascade computes, diff resulting `permissions` block vs existing `<repo>/.claude/settings.local.json`. If new permissions added (not in existing), surface named diff and prompt `add these permissions on swap? [y/N]` (default N). On N → cascade aborts; settings.local.json not written; user must re-author the mode or accept the new permissions.
  - **Tier-4 trust gate (NARROWED under V2.0 scope cut).** Under V2.0, `_repo.yaml` only contributes `enabledPlugins` to the cascade. The hostile-repo RCE vector (attacker plants hooks in `_repo.yaml`) is moot in V2.0 — hooks aren't in the cascade payload. **A reduced threat remains:** an attacker plants `enabledPlugins: {"malicious-plugin@evil-marketplace": true}` in `_repo.yaml`; user clones; runs `/mode:set`; cascade enables the malicious plugin, which is then loaded into the model's context on /reload-plugins. The plugin itself can declare hooks via its own manifest. So the trust gate still matters, just for a narrower content set.

    Before merging tier 4 (`_repo.yaml`) into the cascade, the engine consults `~/.claude/modes/.trusted-repos.txt` (one line per accepted repo: `<absolute-repo-path>:<sha256-of-_repo.yaml>:<accepted-at-iso-timestamp>`). If `<repo>` has no entry, OR if the current `_repo.yaml`'s sha256 differs from the recorded hash, the cascade surfaces a named diff of every `enabledPlugins` entry in `_repo.yaml` and prompts: `install tier 4 configuration from <repo>/.claude/modes/_repo.yaml? Plugins listed will be loaded into Claude on next /reload-plugins. [y/N]` (default N). On Y → tier 4 merged + record appended to `.trusted-repos.txt`. On N → tier 4 skipped entirely; cascade proceeds with tiers 1+2+3 only; warning logged to audit. Pattern adopted from direnv's `.envrc` consent model. Trusted-repos file is mode 0600 (R24).
  - Atomic write: `(umask 077 && tmp=$(mktemp <repo>/.claude/settings.local.json.XXXXXX) && write JSON && mv tmp <repo>/.claude/settings.local.json)`. Re-assert chmod 0600 (defensive — born-at-0600 already correct but defense-in-depth). On chmod failure: rollback mv, audit failure, exit non-zero (fail-closed).
  - **Sidecar metadata file (LOCKED per cross-persona finding + dual research 2026-05-18).** `settings.local.json` is plain strict JSON with no embedded marker. Plugin writes a sidecar at `<repo>/.claude/modes/.cascade-meta.json` with `{tool: "claude-modes", version: "2.0", fingerprint: "<sha256 of settings.local.json contents>", compiled_at: "<iso timestamp>", source_modes: ["<active mode name>", "_global.yaml", "_repo.yaml-if-present"]}`. Sidecar is mode 0600 per R24.

    **Decision rationale** (two research agents, contradictory evidence reconciled):
    - JSONC `// comment` headers BREAK Claude Code's settings parser (verified empirically via binary probe of `cli.js`: parser is strict `JSON.parse` with only BOM-stripping; no comment stripping; no JSON5 or `strip-json-comments` library imported). Confirmed by Claude Code GitHub issues #29370, #17968, #12688 requesting JSONC support.
    - Embedded `$claude_modes` top-level key is ACCEPTED by the current parser (Zod schema uses `.passthrough()` mode at byte 880793 of cli.js v2.1.34; unknown keys preserved across read/merge/write cycle). The convention-research finding that this would be rejected per issue #5886 was contradicted by the binary inspection — issue #5886 may have been addressed or refer to a different code path.
    - **Sidecar chosen despite embedded being viable today** because: (i) **forward-compat**: the `.passthrough()` choice is one parser version's decision; a future Claude Code version could revert to `.strip()` and silently drop the marker on any write-back, breaking uninstall. (ii) **Write-back staleness hazard**: Claude Code's own write-back path (`Z7` function) preserves `$claude_modes` through merges, meaning if any other plugin or UI flow modifies settings.local.json after our cascade write, our `fingerprint` becomes stale while the marker key survives — uninstall would then see mismatch and refuse deletion, even though the "edit" was actually a benign Claude Code write-back. (iii) **Atomic-write chicken-and-egg**: writing settings.local.json with an embedded fingerprint requires either two writes (write without fingerprint → compute hash → rewrite with fingerprint) or an immutable hash-of-content-minus-fingerprint algorithm. Sidecar lets us write settings.local.json once, then write the sidecar with the fingerprint atomically after. (iv) **Convention alignment**: direnv (`.envrc` allow registry), npm (`package-lock.json`), Terraform (`.terraform.lock.hcl`), git hooks (`.sample` suffix) — every well-established tool that solved this problem uses filename-based signatures, not embedded markers. Filenames are the cheapest universal signature in any ecosystem.

    **Uninstall semantic (U7):** re-hash `<repo>/.claude/settings.local.json`; if hash matches sidecar's `fingerprint` → safe to delete both files (plugin-authored, unedited); if hash mismatch → user (or another plugin / Claude Code itself) edited settings.local.json post-cascade, delete only the sidecar, surface "we noticed local edits to settings.local.json — review and clean up manually"; if no sidecar → settings.local.json is not plugin-authored, preserve. Pattern adopted from direnv's `.envrc` allow mechanism.

  **Execution note:** Test-first. Failing tests first for: (a) hooks-in-tier-3 rejected with R28 message, (b) disable: block correctly subtracts, (c) cross-repo writes are filesystem-disjoint, (d) permissions diff prompt fires on addition, (e) statusLine (an object) preserved verbatim from tier 1.

  **Patterns to follow:** V1 `lib/mode-yaml.sh::__claude_modes::py_yaml_query` for the argv contract; V1 atomic-write idiom; V1 `lib/audit.sh` for swap-event recording.

  **Test scenarios** (V2.0 narrowed — only enabledPlugins flows through cascade; hooks/env/permissions/mcpServers test scenarios deferred to V2.0.1+):
  - Happy path (AE3 cascade): `_global.yaml` enabledPlugins {A, B}; `delivery.yaml` enabledPlugins {D}; cascade result {A, B, D}.
  - Happy path (AE9 disable): `_global.yaml` enabledPlugins {A, B}; `writing.yaml` disable.enabledPlugins [A]; cascade result {B}.
  - Edge case (preserve tier 1 settings.json verbatim): tier 1 has `statusLine`, `env`, `permissions`, `hooks`, `mcpServers`, `worktree`, `outputStyle`, etc.; no tier touches any of these; settings.local.json does NOT contain them (Claude Code's native cascade applies tier 1's full settings to the session). settings.local.json contains ONLY the compiled enabledPlugins and the cascade-meta-json sidecar reference.
  - Edge case (V2.0 scope cut — non-enabledPlugins keys in mode YAML are IGNORED): mode YAML declares `mechanism: {enabledPlugins: {...}, env: {FOO: "1"}, permissions: {allow: [...]}}`. Cascade engine reads only the `enabledPlugins` key from `mechanism:`; the other keys (env, permissions) are not in `PLUGIN_OWNED_KEYS_V2` and are silently ignored. Test asserts: cascade compile succeeds (no error), settings.local.json contains only enabledPlugins changes, no env/permissions/hooks/mcpServers keys in settings.local.json output.
  - Edge case (R22 cascade-total): if no tier supplies claude-modes in enabledPlugins → exit non-zero, refuse to write, error matches AE5 wording.
  - Edge case (R22 satisfied by tier 2 only): mode YAML omits claude-modes but `_global.yaml` includes it → cascade total has claude-modes → write proceeds.
  - Edge case (cross-repo isolation — AE8): two repos with different active modes; concurrent `/mode:set` invocations write filesystem-disjoint settings.local.json files; neither sees the other.
  - ~~Edge case (permissions diff)~~ — moot under V2.0 scope cut (permissions not in cascade).
  - Error path (corrupted tier YAML): malformed `_global.yaml` → exit non-zero with clear error; no partial write.
  - Error path (chmod failure simulated): fault-injection wrapper makes chmod fail → write rolled back; audit log records failure; cascade exits non-zero.
  - Atomicity: kill engine mid-write → no partial file at target; tmp file cleaned by trap.

  **Verification:** All test cases pass. R28 lint extended to assert `"hooks"` not in TIER_3_OWNED_KEYS source declaration (static defense). Manual smoke: `/mode:set delivery` in two test repos produces filesystem-disjoint settings.local.json with cascade comment header.

- U5. **`/mode:set` + `/mode:clear` + `/mode:apply` orchestration with R26 crash-safety.** `/mode:set` orchestrates U4 cascade + U8 symlink rebuild + per-branch state + install registry append. **`/mode:clear`** removes per-branch pointer + re-runs cascade with no tier-3 contribution → settings.local.json reflects tier 1+2+4 only (no-modes-active state, i.e., "Claude Mode"). **`/mode:clear` ALSO explicitly invokes U8 user-catalog symlink rebuild with the empty active-mode manifest** (per feasibility + adversarial finding 2026-05-18) — restores the day-zero symlink topology (all `.user-catalog/` files linked back). Without this explicit invocation, user-catalog symlinks would be sticky from the previous mode's manifest, contradicting the no-modes-active invariant. `/mode:apply` is a thin helper for users who want to re-apply the current branch's mode after manual edits.

  **Files:**
  - Modify: `lib/set-mode.sh` (extend skeleton from v0.1.0-experiment; call U4 cascade engine instead of writing live-settings.json directly; sentinel for R26)
  - Modify: `lib/active-mode.sh` (read tier 6 per-branch pointer; resolve "Claude Mode = no pointer")
  - Create: `commands/set.md`, `commands/clear.md`, `commands/apply.md` (slash-command bodies)
  - Create: `lib/apply-mode.sh`
  - Create: `tests/integration/mode-set-crash-recovery.test.sh`

  **Test scenarios:**
  - Happy path (AE2 Claude Mode): `/mode:setup` produces a `_global.yaml` reflecting pre-install state; no tier-3 mode active; cascade result preserves all behavior.
  - Happy path: `/mode:set delivery` → cascade engine runs → settings.local.json written → user signaled to /reload-plugins.
  - Happy path: `/mode:clear` after `/mode:set delivery` → cascade engine runs with no tier-3 → settings.local.json now reflects tier 1+2+4 only.
  - Edge case (detached HEAD): branch slug = `detached-<short-sha>`; per-branch state file uses that name.
  - Edge case (no git repo): /mode:set in /tmp → user-global active mode, no per-branch pointer; user-catalog symlink rebuild proceeds (still user-global).
  - Integration (R26 crash recovery): SIGTERM mid-mode-set → sentinel persists → re-run mode:set <same-target> → idempotent re-apply → end state matches non-interrupted run.

- U6. **`/mode:setup` install with cascade-aware bootstrap.** New responsibilities vs. previous plan: generates `_global.yaml` from user's settings.json (not `claude.yaml` — Claude Mode is no-modes-active). Creates install registry. Does NOT symlink `~/.claude/settings.json` (R21 superseded). Still moves user-catalog files into staging + symlinks back.

  **Files:**
  - Create: `scripts/setup.sh`
  - Create: `lib/install-registry.sh` (append-only repo tracking)
  - Create: `commands/setup.md`
  - Extend: `tests/integration/install-uninstall-roundtrip.test.sh`
  - Create: `tests/integration/mode-setup-crash-recovery.test.sh`
  - Create: `tests/unit/install-registry.test.sh`

  **Approach (idempotent steps with `.setup.in-progress` sentinel — R26 extension):**
  1. **Presence check.** If `~/.claude/modes/_global.yaml` exists AND sentinel absent, refuse with "already installed." If sentinel exists, log "resuming previous setup" and re-apply each step idempotently.
  1a. **Write sentinel.** `(umask 077 && touch ~/.claude/modes/.setup.in-progress)`.
  2. **Pristine capture.** Born-at-0600 cp of `~/.claude/settings.json` to `~/.claude/settings.json.pristine` (forensic anchor only; never used for restore).
  3. **Generate `_global.yaml`** (NARROWED under V2.0 scope cut). Read pristine; extract `enabledPlugins` ONLY into YAML form. Other keys (env, permissions, mcpServers, hooks) stay in `~/.claude/settings.json` untouched — they're not in the cascade. Born-at-0600 write to `~/.claude/modes/_global.yaml`. **R22 enforcement at install:** the cascade engine asserts claude-modes is in enabledPlugins of the cascade total. If user's pre-install settings.json didn't have claude-modes (typical pre-publication case), the synthetic identifier `claude-modes@local-dev` is added to `_global.yaml`'s enabledPlugins with a one-time `<system-reminder>` informing the user.
  4. **Move user catalog.** Per-file: pre-flight (symlinks preserved in place; hard-linked files trigger hard-fail with remediation per previous plan's P1 fix); same-filesystem check; atomic mv + ln -s back.
  5. **Seed examples.** Copy `examples/*.yaml` to `~/.claude/modes/`.
  6. **Archive V1 modes.** Any `~/.claude/modes/*.yaml` with `schema_version: 1` (other than examples) → move to `~/.claude/modes/.v1-archive/`.
  7. **Create install registry.** `touch ~/.claude/modes/.installed-repos.txt` (initially empty; `/mode:set` appends repos).
  8. **Audit + clear sentinel.** Append install event; `rm ~/.claude/modes/.setup.in-progress`.

  **Note on `~/.claude/settings.json`:** Never symlinked or modified. Read once at step 2 for the pristine; never touched again.

  **Test scenarios:** All prior plan's U6 scenarios for content preservation + crash recovery + V1 archival + hard-link hard-fail. Plus: AE8 setup half — install in repoA + install in repoB → both have independent `<repo>/.claude/settings.local.json` after first `/mode:set` in each.

- U7. **`scripts/unmodes.sh` registry-driven uninstall.** Reads `~/.claude/modes/.installed-repos.txt`; for each listed repo: removes `<repo>/.claude/settings.local.json` (only if signature header matches — never delete user-authored files at that path) and `<repo>/.claude/modes/`. Moves user-catalog files back. Deletes `~/.claude/modes/`. **Never restores `~/.claude/settings.json` from pristine** — plugin never owned it.

  **Files:**
  - Create: `scripts/unmodes.sh`
  - Create: `scripts/restore-claude-modes.sh` (R22 wedge recovery — smaller scope: re-enable claude-modes in `_global.yaml` for users who manually disabled it)
  - Extend: `tests/integration/install-uninstall-roundtrip.test.sh`
  - Create: `tests/integration/multi-repo-uninstall.test.sh` (AE10)

  **Approach:**
  1. Read install registry. For each listed repo (absolute path):
     - Verify repo still exists; if not, audit "repo gone — skipping" and continue
     - **Path-class verification (NEW per cross-persona finding 2026-05-18):** verify the path is a git work-tree root via `git -C "$path" rev-parse --show-toplevel` AND the result matches `$path` exactly (no traversal). If the check fails (not a git repo, path is a subdirectory of a repo, command errors), audit `registry entry $path is not a git work-tree root — skipping` and continue. Closes the attack where a malicious registry entry points at `/etc/cron.d` or any non-repo path; uninstall refuses to act on non-repo paths regardless of signature.
     - **Sidecar-based deletion gate (LOCKED per research 2026-05-18):** check `<repo>/.claude/modes/.cascade-meta.json` exists. If absent → settings.local.json is not plugin-authored → preserve; audit "no cascade-meta sidecar — settings.local.json preserved." If present → re-hash current `<repo>/.claude/settings.local.json` contents (sha256); compare to sidecar's `fingerprint` field. If match → both files are plugin-authored, unedited — safe to delete both. If mismatch → user edited settings.local.json post-cascade; delete only the sidecar, preserve settings.local.json, surface "claude-modes detected local edits to <repo>/.claude/settings.local.json — review and clean up manually" via the audit log. Direnv-pattern content-hash discrimination; matches the validation mechanism the cascade engine writes at compile time.
     - Remove `<repo>/.claude/modes/` directory entirely (this is a plugin-owned path; R12 permits rm on plugin-owned trees).
  2. Move user-catalog files back per pre-flight checks (symmetric to U6's pre-flight).
  3. Delete `~/.claude/modes/` directory.
  4. **Forensic preservation:** before deletion, copy `~/.claude/modes/.audit.log` to `~/.claude/.claude-modes-uninstall.log` (the ONE R12 exception, with explicit comment).
  5. Audit-log the uninstall event itself to the preserved log.

  **Note on settings.json:** untouched. The pristine remains as a forensic anchor in case the user wants to manually compare; uninstall never restores from it.

  **Test scenarios:**
  - Happy path AE1 (clean round-trip): install in repoA; no post-install edits anywhere; uninstall → `~/.claude/commands/*.md` SHA-256 match pre-install; `~/.claude/settings.json` SHA-256 match pre-install (never touched); no `<repoA>/.claude/settings.local.json` survives; no `<repoA>/.claude/modes/` survives; `~/.claude/.claude-modes-uninstall.log` exists with audit history.
  - Happy path AE10 (multi-repo): install in repos A, B, C across time; uninstall → all three repos' settings.local.json removed; all three `<repo>/.claude/modes/` removed.
  - Edge case (user-authored settings.local.json at same path): user manually wrote `<repoX>/.claude/settings.local.json` before installing claude-modes; uninstall detects signature absence → preserves the file → audit "preserved user-authored settings.local.json in repoX."
  - Edge case (registry entry for missing repo): user moved/deleted repoB after install; uninstall reads registry, finds repoB path no longer exists → audit "repo gone, skipping" → continues.

### Phase 3: Hooks + UX + wrap-up

- U8. **User-catalog symlink rebuild + R7 path-traversal.** Unchanged from previous plan in structure; mechanism is user-global (not repo-scoped) per the scoping decision. Phase 2 placement (U8 is called by U6 install).

- U9. **R27 worktree reconciliation (Python orchestrator + flock).** Same as previous plan's revised U9 — Python is the orchestrator holding flock for the entire critical section (no `os.execvp` bridge). Scope narrows: cross-repo concurrent sessions don't contend (each has its own settings.local.json); same-repo concurrent worktrees contend on the within-repo cascade lock `<repo>/.claude/modes/.cascade-lock` and user-global `~/.claude/modes/.symlink-lock` (for user-catalog symlinks). SessionStart hook timeout-degradation strategy per previous plan's P1 fix.

- U10. **R25 UserPromptSubmit prose injection.** Unchanged from previous plan. Reads tier-3 active mode's prose layer + pending markers (R27 divergence toast, R20 untagged-files, V1 archival notice) and emits `systemMessage`. Always exits 0.

- U11. **R20 new-file adoption (three paths).** Manual `/mode:adopt <file>`, PostToolUse Write hook for Claude-tool writes, SessionStart scan for editor writes. Default to N in non-interactive (TTY detection via `[ -t 0 ]` or `CLAUDE_NON_INTERACTIVE=1` env-var). Path-filter excludes `.tmp-*`, `*.backup`, `.draft-*`.

- U12. **Mode-author skill V2 + `/mode:status` + `/mode:registry`.** Skill carries forward V1 phased flow; **Phase 2.5 cascade-aware: when user describes a hooks-related need, skill redirects them to edit `_global.yaml` directly (or `_repo.yaml` if they're in a repo) — provides the relevant file path and shows the edit pattern.** Mode YAML output remains tier-3 only (never hooks). `/mode:status` reports active mode + cascade tiers visible (tier 1 always, tier 2 always, tier 3 if mode set, tier 4 if `_repo.yaml` present) + plugin catalog + user catalog. `/mode:registry` lists modes globally available.

- U13. **README + lint + perms test + statusline carry + docs/solutions/ seed.** Same shape as previous plan. README adds a **Cascading Configuration Tiers** section explaining tiers 1-4 + 6 with worked examples (a `_global.yaml` snippet, a `_repo.yaml` snippet, a tier-3 mode YAML snippet with `disable:` block). README adds explicit guidance: "**Secrets in `_repo.yaml`:** because `_repo.yaml` lives in your repo, committing it shares hooks/env/MCP creds with anyone who can read the repo. Add `_repo.yaml` to `.gitignore` or use env-var references for secrets." R13 lint extended to bash + Python destructive verbs. R24 perms test covers `_global.yaml`, `_repo.yaml`, `settings.json.pristine`, `<repo>/.claude/settings.local.json`, `.installed-repos.txt`, `.audit.log`.

---

## Phased Delivery

### Phase 1: Foundation (U1, U2, U3) — parallel from Day 1
- U1, U2, U3 all parallel (U2, U3 do not consume U1 results)
- U4 sequential after U1 + U3

### Phase 2: Core mechanism + user-catalog substrate (U4, U5, U6, U7, U8)
- U4 sequential (depends on U1 + U3)
- After U4: U5 + U8 parallel
- After U8: U6 sequential (install needs U8's symlink-rebuild)
- After U6: U7 sequential (uninstall round-trip test exercises U6's install path)

### Phase 3: Hooks + UX + wrap-up (U9, U10, U11, U12, U13)
- After U8: U9 + U10 + U12 parallel
- After U8 + U10: U11 sequential
- After U1–U12: U13 wrap-up

**Realistic critical path:** U1 → U3 → U4 → U8 → U6 → U7 → U13. U1 alone may take a full day (7 fresh sessions for the matrix). Total: implementer-estimated **6-9 working days** for a single implementer (slightly longer than previous plan due to cascade engine + tier 4 handling + install registry).

---

## System-Wide Impact

- **Interaction graph:** Three hooks — UserPromptSubmit (R25), SessionStart (R27 + R20 scan), PostToolUse Write (R20 consent). PreToolUse from V1 is dropped. Each hook's failure mode is "log warning, exit 0."
- **Error propagation:** V1's rel-001 pattern carries forward. CLI commands propagate errors; hooks never.
- **State lifecycle risks:**
  - `~/.claude/modes/.mode-set.in-progress` (R26 cascade-engine sentinel)
  - `~/.claude/modes/.setup.in-progress` (R26 extended to /mode:setup)
  - `<repo>/.claude/modes/.cascade-lock` (R27 within-repo flock)
  - `~/.claude/modes/.symlink-lock` (R27 user-catalog flock — still user-global)
  - `~/.claude/modes/.sessions/<session-id>.*` (one-time markers; 7d pruning)
- **API surface parity:** 7 slash commands (`/mode:set`, `/mode:clear`, `/mode:apply`, `/mode:setup`, `/mode:status`, `/mode:registry`, `/mode:adopt`, `/mode:statusline`).
- **Integration coverage:** Cross-repo isolation test (AE8), multi-repo uninstall test (AE10), cascade-disable-block test (AE9), within-repo worktree reconciliation, install/uninstall round-trip with multi-repo.
- **Unchanged invariants:** `~/.claude/settings.json` non-plugin-owned keys untouched (now: ALL keys, since plugin never writes to settings.json). User's `~/.claude/commands/*.md` and `~/.claude/agents/*.md` byte-identical via mv + symlink. V1 statusline mechanism unchanged. Test harness `$HOME` isolation unchanged. `~/.claude/plugins/installed_plugins.json` read-only (used for R22 self-identification).

---

## Risks & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| U1 reload-matrix Row 1 fails (V2 thesis breaks) | Med | High | Surface to Shawn before continuing planning; reframe per matrix decision rules. |
| ~~Tier 4 (`_repo.yaml`) hooks committed to source control expose creds~~ | Moot under V2.0 scope cut | n/a | `_repo.yaml` only contains `enabledPlugins` under V2.0; no credentials in scope. Re-introduce row if V2.0.1+ adds hooks/env/mcpServers to cascade. |
| `_global.yaml` regeneration on Claude Code upgrade (new settings.json keys) | Low | Low | Implementation deferred; `/mode:status` may flag missing keys. Acceptable risk for V2.0. |
| Multi-repo write race: two repos' `/mode:set` invocations mutate user-global `~/.claude/modes/.installed-repos.txt` concurrently | Low | Low | Append-only writes with O_APPEND (atomic per POSIX). Worst case: an entry duplicated; idempotent reads handle this. |
| Cascade engine produces unexpected merge result (e.g., deep-merge vs. replace) | Med | Med | Test-first; specific test scenarios for each merge type (object deep-merge, list append+dedupe, scalar replace). |
| chmod 0600 fails on network FS | Low | High | Fail-closed per previous plan: rollback the mv, audit, exit non-zero. |
| User commits `<repo>/.claude/settings.local.json` to source control | Med | Low (cosmetic) | README guidance: `.gitignore` the file. The signature header makes it obvious it's machine-generated. Most VCS conventions already gitignore `*.local.*` files. |
| Claude Code drops `enabledPlugins` Zod schema in a future version | Low | Critical (V2 breaks) | SessionStart contract anchor logged to `~/.claude/modes/.session-start.log`. |

### Dependencies / Prerequisites

- macOS bash 3.2, /usr/bin/python3 with PyYAML, JSON tools.
- Claude Code 2.1.x harness with stable settings.json cascade contract (verified empirically; assumption documented in U1 matrix).
- Local-only git repo for development; subagent parallel dispatch uses shared-directory mode per feedback_ce_worktree_no_remote.

---

## Phased Delivery Notes

V2.0 ships as a single PR off `feat/modes-v2` (branch reused from previous plan; new commit graph since cascade rebuild). Previous plan's branch state is preserved; this plan supersedes the previous plan's unit definitions but reuses the same branch.

**Day 1 of `/ce-plan` MUST execute the reload-semantics matrix** before any V2 code is written. Results dictate which plugin-owned keys remain at tiers 2/3/4 and whether V2's central thesis is sound. If row 1 fails, V2 reframes — cascade architecture may stay (the thesis is independent of `/reload-plugins`-purges-context, since cross-repo isolation works regardless) but `/doctor pressure dissolves` criterion needs reframing.

---

## Alternative Approaches Considered

- **Single-overlay-per-machine (previous plan's approach).** Rejected: hooks repetition + multi-repo isolation problems surfaced as load-bearing concerns post-doc-review.
- **Repo-tier-only cascade (no `_global.yaml`).** Rejected: addresses multi-repo isolation but not hooks repetition; users would have to duplicate hooks across every repo's `_repo.yaml`.
- **Global-tier-only cascade (no `_repo.yaml`).** Considered. Per scope-guardian's argument: V2.0's two stated motivations (hooks repetition + multi-repo isolation) are solvable with R29 + per-repo output alone. User decision 2026-05-18: include R30 (`_repo.yaml`) in V2.0 because real workflows have repo-specific baseline needs (MCP servers, env vars, hooks that vary by repo). R31 (override.yaml) remains deferred to V2.1.
- **Symlinking `~/.claude/settings.json` to plugin-managed file (V1 + previous plan's opt-in path).** Rejected: cascade model eliminates the need for plugin to own settings.json; trust ask is dramatically smaller when plugin only writes to repo-local files.

---

## V2.0 Scope Cut Summary (post-binary-verification 2026-05-18)

**What V2.0 ships:**
- Cascade architecture (5 tiers: user-settings → _global.yaml → mode YAML → _repo.yaml → per-branch pointer; tier 5 reserved)
- Cascade payload limited to **`enabledPlugins` ONLY** — the one key Claude Code's `/reload-plugins` actually hot-reloads in-session
- Per-repo isolation via `<repo>/.claude/settings.local.json` write target
- User-catalog mechanism (move user commands/agents to staging, symlink back, per-mode manifest)
- Mode-author skill (simpler: asks which plugins to enable/disable, which user commands to scope, what prose to inject)
- Worktree reconciliation (R27) for cross-worktree `enabledPlugins` swaps
- Trusted-repos.txt consent gate for foreign `_repo.yaml` (narrowed to enabledPlugins changes only)
- Born-at-0600 file permissions; install/uninstall round-trip
- /mode:set, /mode:clear, /mode:status, /mode:setup, /mode:adopt, /mode:registry slash commands
- Prose injection via UserPromptSubmit hook (R25)

**What V2.0 does NOT ship (deferred to V2.0.1+ or V2.1):**
- Mode-scoped hooks (require new session per harness contract — not worth the misleading UX)
- Mode-scoped env vars (process env captured at startup — architecturally not hot-reloadable)
- Mode-scoped permissions (not picked up by /reload-plugins per binary verification)
- Mode-scoped non-plugin MCP servers (require new session)
- R28 runtime assertion for hooks-in-mode-tier (moot — hooks aren't in cascade at all)
- Permissions diff/confirm gate (moot — permissions not in cascade)

**Why this scope cut:** binary inspection of Claude Code 2.1.143 confirmed `/reload-plugins` calls `refreshActivePlugins`, which mutates the harness React appState for the plugin layer ONLY. Hooks/permissions/env/non-plugin-mcpServers at the settings layer don't hot-reload. Putting them in the cascade payload would create a misleading user contract.

**Adoption story:** "Set modes to shape which plugins are loaded; restart Claude Code to change hooks/env/permissions." Honest, narrow, ships.

---

## Success Metrics

(Carried verbatim from origin.)

- Public adoption signal: ≥1 non-Shawn user installs V2 within 6 months of marketplace publication and reports it useful.
- Shawn V0 adoption: `/mode:set` reached on a real project within 30 days post-install.
- `/doctor pressure dissolves` in a non-Claude mode (gated on U1 row 1).
- Downstream handoff: this plan produced by `/ce-plan` without inventing product behavior — met.
- Uninstall credibility: `tests/integration/install-uninstall-roundtrip.test.sh` proves byte-identical recovery for clean branch; preserved-edits behavior for multi-repo uninstall.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-17-v2-modal-harness-requirements.md](../brainstorms/2026-05-17-v2-modal-harness-requirements.md) (with cascade-update revisions 2026-05-18)
- **Previous plan (superseded):** [docs/plans/2026-05-17-001-feat-modal-harness-v2-plan.md](2026-05-17-001-feat-modal-harness-v2-plan.md)
- **V1 origin:** [docs/brainstorms/2026-05-15-modes-as-infrastructure-requirements.md](../brainstorms/2026-05-15-modes-as-infrastructure-requirements.md)
- **V1 substrate:** git tag `v0.1.0-experiment` (this repo)
- **Canonical flock pattern:** `Slate/plugins/docs/solutions/architecture-patterns/silent-failure-when-singleton-assumption-breaks-2026-05-09.md` (Python-orchestrator adaptation; no execvp bridge)
- **Institutional learnings:** Per Context & Research section above.
- **Runtime ground truth:** `~/.claude/settings.json` (21-key shape), `~/.claude/plugins/installed_plugins.json` (R22 self-identification source).
