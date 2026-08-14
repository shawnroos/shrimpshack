# Residual Review Findings — reflect embed-index fix

Branch: `bugfix/reflect-embed-indexes-new-memories`
Head at record time: `f770af7`
Date: 2026-08-14

Source: `ce-code-review mode:agent` over `origin/main...HEAD`, run
`20260814-162258-982c2954`. Six findings were applied in `f770af7`; what follows
is everything that was **not** applied, recorded here because there is no tracker
configured for this repo and an unrecorded residual is indistinguishable from one
that was never found.

## Not applied

### P2 — `harness.sh` has grown past comfortable single-file size
**File:** `plugins/reflect/tests/harness.sh:81` · **Reviewer:** maintainability ·
`advisory` / human

The file is now ~1330 lines and this diff added ~150 without decomposition. The
reconciler block (stub heredoc, three ledger files, thirteen scenarios) is
self-contained — its only coupling to the rest of the harness is `$SCRIPTS` and
`$ROOT` — so it is a natural extraction into `plugins/reflect/tests/reconciler.sh`.
Not done here because it would mix a structural move into a bug-fix diff and make
the mutation-proof evidence harder to read against the change. Worth doing before
the next change to either subsystem.

### Stub indexes non-recursively; the real memory dir nests
**Reviewers:** correctness, adversarial (both as residual risk)

The stub's `index_collection` walks `"$2"/*` only. Real `qmd update` is recursive,
and the live memory dir nests bodies under `_scope/<project-slug>/*.md`. No stub
assertion covers a nested memory file, so the stub is a narrower model than the
thing it stands for. Not a production defect — the production path delegates to
real qmd, which handles nesting — but it is a coverage boundary worth closing when
the reconciler block is next touched.

### The hoisted global `qmd update` is unbounded
**Reviewer:** adversarial (residual)

Every other qmd call in this plugin is timeout-bounded (`SEEDED_RECALL_TIMEOUT`).
The new `qmd update` is not, and it is global: `qmd status` on this machine reports
~26.9k documents across foreign collections. reflect auto-triggers on PR
create/merge, ExitPlanMode, and all-todos-done, so every trigger now pays a full
global rescan with no ceiling, and a wedged qmd stalls Pass 8 indefinitely.

The cost is disclosed in the script header and in SKILL.md, and the call is
best-effort so a *failure* is survivable — but a *hang* is not bounded. There is
prior art on wedged-qmd handling at
`plugins/reflect/docs/plans/2026-07-17-001-fix-recall-wedged-qmd-guard-plan.md`.
Deliberately out of scope for this fix; a real candidate for the next one.

### A stale-path `claude-memory` is treated as satisfied
**Reviewer:** adversarial (residual) · **pre-existing**

`reconcile_one` matches an existing collection by NAME only and never verifies the
registered path still equals `QMD_RECONCILE_MEMORY_DIR`. A `claude-memory`
registered against a stale path is counted as `existing`, embedded, and reported
clean, while the real memory dir goes unindexed. Unchanged by this diff, and the
new global `update` does not repair it — `update` reindexes the *registered* path,
which is the wrong one. Same family as the bug this branch fixes.

### `embedded=` field type change has no verified consumer
**Reviewer:** correctness (residual) · **agent-native (observation)**

The field went from always-numeric to `0|unknown`. A repo-wide search found no code
that parses `REFLECT.log`; the only references are prose. So nothing breaks today,
but the search was scoped to this repo and cannot rule out an external consumer.
SKILL.md now documents the two valid values.

### Real `qmd update` partial-failure semantics unverified
**Reviewer:** correctness (residual)

If real `qmd update` exits 0 after failing to index a *subset* of paths, the
applied fix still reports a confident `embedded=0` for that run. The fix covers
the case where update exits non-zero. Bounding this would need a way to make real
qmd partially fail, which the suite cannot currently produce.

## Coverage gaps in the review itself

Stated rather than implied, because a gap that is not named reads as coverage.

- **Cross-model adversarial pass: not run.** The change is a silent-pass
  verification mechanism, so the adversarial lens is mandatory — but no
  attestably-different provider CLI is installed on this machine (`codex`, `grok`,
  `cursor-agent` all absent; host family is `claude`). The lens ran in-process
  instead. It found both P1s, but its agreement with the correctness reviewer is
  *not* independent-model corroboration.
- **`project-standards`: not run.** No `CLAUDE.md` or `AGENTS.md` governs any
  changed path (empty successful search, not a failed one).
- **`shellcheck`: not available** on this machine. Shell syntax was checked with
  `bash -n` only.
- **Deliberate-fail flags were not used as evidence anywhere.** Every load-bearing
  claim in this branch was proven by mutating production code and observing the
  assertion go red.

## Note for the next person

The exit-code-as-proxy-for-effect defect is now documented **twice** in
`plugins/reflect` inside one week:
`docs/solutions/logic-errors/default-allow-regex-projection-gate-silently-drops-nudges.md`
(2026-08-11, a test asserting `rc == 0`) and this branch's `embedded` counter.
Both times the check reported success because a command exited zero rather than
because the effect happened. This is a class, not a coincidence, and it is worth a
`docs/solutions/` entry of its own once this lands.
