---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: docs/handoff.md
created: 2026-07-01
type: fix
---

# fix: Spinoff doc-carry completeness + kickoff truncation

> Directional where noted: pseudo-code and command sketches communicate intent, not literal implementation. The code is the source of truth.

## Summary

Two independent defects in the spinoff launcher `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` strand briefed sessions. **Doc-carry** currently drops most referenced docs (a `find` filter gated on 6h-recency, name patterns, and top-level-only), and a fresh git worktree only materializes committed content — so uncommitted WIP docs the handoff points at simply aren't there. **Kickoff** sends a ~1080-char single-line prompt that overruns the Claude TUI paste line, so the launched session gets a truncated instruction.

Fix both: copy the entire `docs/` tree recursively (no-clobber), carry a conservative dotfile allowlist with a local secret-guard, and collapse the kickoff to a short pointer (the directional prose already lives authoritatively in every generated handoff). Then bump the plugin version and republish so the installed mirror `~/.claude/skills/cmux-spinoff/` regenerates.

**Product Contract preservation:** n/a — solo plan, no upstream brainstorm. Origin is the directional handoff at `docs/handoff.md`.

---

## Problem Frame

`spinoff.sh` runs in a background agent to fork work into a fresh worktree + briefed Claude session. Both defects surfaced live during real spinoffs this session:

- **Defect 1 — doc-carry misses real content** (`spinoff.sh:236-247`). The filter `find … -maxdepth 1 -type f -mmin -360 \( -iname '*plan*' -o -iname '*brainstorm*' -o -iname '*requirement*' -o -iname '*notes*' \)` drops (a) anything older than 6h, (b) anything not matching those name patterns (an "assessment", a spec, a diagram), and (c) anything nested (`docs/plans/…`, `docs/assessments/…`). Compounding this, a git worktree only checks out **committed** content — uncommitted/gitignored docs in the source repo never exist in the new worktree unless explicitly copied. Net effect from the live report: `docs: 0 carried`, and the handoff referenced a "U5 assessment" + parent plan that were never copied in.

- **Defect 2 — kickoff truncated on send** (`KICKOFF` def `spinoff.sh:255`, send site `279`). The ~1080-char single-line string overruns the TUI input line on paste, so the launched session receives a cut-off instruction. A resubmit-guard at `285-289` (matching `*"Read docs/handoff.md"*`) only re-sends Enter — it does not fix body truncation.

**Boundary:** fix only the canonical script `plugins/spinoff/skills/spinoff/scripts/spinoff.sh`. The installed mirror `~/.claude/skills/cmux-spinoff/` is regenerated on publish — never hand-edit it.

---

## Requirements

- **R1** — Carry the full `docs/` tree recursively into the new worktree, preserving subdirectories, so a handoff can reference `docs/plans/…` / `docs/assessments/…` and the receiving session can actually read them.
- **R2** — Never re-copy `handoff.md` (the script writes that itself at `docs/handoff.md`), and never clobber a file already present in the worktree — committed content wins over an older source copy.
- **R3** — Carry a conservative root-level dotfile allowlist (`.env`, `.env.*`, `.envrc`, `.tool-versions`, `.nvmrc`) from `$REPO_ROOT` into `$WORKTREE` so the briefed session runs against real config. Never touch `.git`; never blanket-copy dotfiles (no `.DS_Store` noise).
- **R4** — Guard carried secrets: a carried `.env` must not be accidentally committable from the worktree, regardless of whether the repo's `.gitignore` covers it. Append a one-line security footnote to the generated handoff **only when** a dotfile was actually carried.
- **R5** — Collapse `KICKOFF` to a short pointer that fits a single safe TUI paste; keep the resubmit-guard's match string in sync with the new first line.
- **R6** — Report carry counts honestly, split into docs vs dotfiles, in both the inline `step` message and the final summary.
- **R7** — Bump `plugins/spinoff/.claude-plugin/plugin.json` (0.7.0 → 0.7.1) and republish so the installed mirror picks up the new script (publish is version-gated).
- **R8** — Extend the canonical smoke-test `plugins/spinoff/skills/spinoff/scripts/smoke.sh` with fixture assertions covering doc-carry completeness, dotfile carry + exclude-guard, and kickoff brevity. (The installed mirror's `evals/evals.json` is not the target — it's mirror-only and regenerated on publish; see KTD7.)

---

## Key Technical Decisions

- **KTD1 — Full recursive `docs/` copy over a widened name filter.** The name-pattern filter is the root cause of dropped content; widening it only chases the next oddly-named doc. Copy the whole tree. Decision confirmed with Shawn.
- **KTD2 — No-clobber precedence: committed wins.** Copy source docs only where the destination does not already exist. A worktree file is committed content that is definitionally at-or-newer than the branch point; an uncommitted source copy is WIP that should not overwrite it. Implement with a per-file existence check (e.g. `cp` with a guard, or `cp -n` — but verify `cp -n` behavior on macOS/BSD, which is the runtime; `cp -n` is supported on BSD `cp` and is the simplest no-clobber primitive). Directional sketch, validate the flag against the target `cp`.
- **KTD3 — Conservative dotfile allowlist, not a blanket `cp .[^.]*`.** Explicit list: `.env`, `.env.*`, `.envrc`, `.tool-versions`, `.nvmrc`. A blanket copy risks `.git`, `.DS_Store`, editor state, and other noise. Confirmed with Shawn.
- **KTD4 — Secret guard via `git info/exclude`, not the committed `.gitignore`.** The root `.gitignore` in this very repo does **not** list `.env`; a worktree shares the repo's committed `.gitignore`, so relying on it is unsafe for repos that don't already ignore `.env`. Appending the carried dotfile names to the git exclude guarantees they can never be `git add`'d, without editing any committed file. Resolve the path via `git -C "$WORKTREE" rev-parse --git-path info/exclude` (in a linked worktree, `.git` is a file pointing at the real gitdir — never hardcode `$WORKTREE/.git/info/exclude`). **Scope caveat (verified):** in a linked worktree this resolves to the repo's **common** git dir (`…/<repo>/.git/info/exclude`), which is **shared** across the main repo and all sibling worktrees — it is NOT per-worktree. That is acceptable for the accidental-commit goal (the carried dotfiles are the exact basenames we want ignored everywhere), but the framing and the handoff footnote must say "kept out of git via the repo's shared exclude," not "per-worktree." True per-worktree exclusion isn't achievable this way; there is no standard per-worktree gitignore.
- **KTD5 — Kickoff pointer-collapse, not chunked-send or kickoff-to-file.** The long "treat the handoff as directional…" prose already lives verbatim in every generated handoff (banner injected idempotently by the script, SKILL.md:115-116; handoff assembly `203-233`). The kickoff needs only to point at `docs/handoff.md` and ask for the recommend-next-step behavior. Simplest fix, keeps the directional framing authoritative in the handoff.
- **KTD6 — Security footnote is conditional and script-appended.** Append to the worktree handoff only when a dotfile was carried (avoids a stale "secrets carried" note on runs that carried none). The banner mechanism already appends to the handoff idempotently, so this follows an established pattern.
- **KTD7 — Verify via the existing canonical `smoke.sh`, not the mirror `evals.json`.** A real assertion runner already exists: `plugins/spinoff/skills/spinoff/scripts/smoke.sh` (127 lines) spins up a git fixture and asserts on `spinoff.sh` output. It is canonical (survives publish) and is the natural home for mechanical checks of the two fixes. The mirror's `evals/evals.json` is prompt→`expected_output` skill-behavior prose that lives **only** in `~/.claude/skills/cmux-spinoff/` (no canonical copy) and is regenerated on publish — editing it both violates the never-edit-mirror boundary and risks being clobbered. So coverage moves to `smoke.sh`. Decision confirmed with Shawn (supersedes the earlier "extend evals.json" choice, made before `smoke.sh` was known to exist). Consume/extend the existing harness rather than rebuilding.

---

## Implementation Units

### U1. Recursive `docs/` carry with no-clobber

**Goal:** Replace the `find`-based filter with a full recursive `docs/` copy that preserves subdirs, skips `handoff.md`, and never overwrites an existing worktree file (R1, R2).

**Requirements:** R1, R2, R6 (docs count).

**Dependencies:** none.

**Files:** `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` (block `236-247`; docs portion of summary line `386`).

**Approach:** Replace the `while … find …` loop with a recursive walk of `$REPO_ROOT/docs` that, for each file, computes its path relative to `docs/`, skips the top-level `handoff.md`, creates the destination subdir under `$WORKTREE/docs/`, and copies only if the destination does not already exist (KTD2). Increment a `CARRIED` (docs) counter per file actually copied. Preserve the existing `set -uo pipefail` safety and the `2>/dev/null` tolerance. Directional sketch:

```sh
if [ -d "$REPO_ROOT/docs" ]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$REPO_ROOT/docs/"}"
    [ "$rel" = "handoff.md" ] && continue          # script writes this itself
    dst="$WORKTREE/docs/$rel"
    [ -e "$dst" ] && continue                       # no-clobber: committed wins
    mkdir -p "$(dirname "$dst")"
    cp "$f" "$dst" 2>/dev/null && CARRIED=$((CARRIED+1))
  done < <(find "$REPO_ROOT/docs" -type f -print0 2>/dev/null)
fi
```

**Patterns to follow:** the existing null-delimited `while IFS= read -r -d '' f` loop already in the block; keep that idiom.

**Test scenarios:**
- Happy path: source `docs/plans/foo.md` and `docs/assessments/bar.md` exist → both land at the same relative paths in the worktree; docs count reflects them.
- Skip: `docs/handoff.md` in source is not re-copied (worktree keeps the script-generated one).
- No-clobber: a committed `docs/plans/foo.md` already in the worktree is NOT overwritten by an older source copy.
- Edge: `docs/` absent in source → block is a no-op, count stays 0, no error.
- Edge: nested empty dirs / unreadable file → `2>/dev/null` tolerance, loop continues, no crash under `set -u`.

**Verification:** After a spinoff whose source has nested + oddly-named + stale docs, every non-`handoff.md` file under source `docs/` exists at the same relative path in the worktree; the summary reports the correct docs count.

---

### U2. Conservative dotfile carry with secret guard + handoff footnote

**Goal:** Carry the allowlisted root dotfiles into the worktree, guard them from accidental commit, and append a conditional security footnote to the generated handoff (R3, R4).

**Requirements:** R3, R4, R6 (dotfiles count).

**Dependencies:** U1 (shares the carry region and counting/summary wiring).

**Files:** `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` (new block after the docs carry; dotfiles portion of the `step` message and summary line `386`; conditional handoff-footnote append near the handoff finalization at `199-233`).

**Approach:** After the docs carry, iterate an explicit, fully-qualified allowlist against `$REPO_ROOT` root only (not recursive). Fully-qualify each glob as `"$REPO_ROOT"/.env` etc. rather than looping a bare `$pat` — a bare `.env.*` pattern pre-expands against the shell's cwd and can miss the real root-level files. For each existing regular file, copy into `$WORKTREE` if the destination does not already exist (same no-clobber rule), increment a separate `DOTS` counter, and record the basename for the exclude guard. Under `set -u`, guard against non-matching globs (an unmatched glob stays literal — the `[ -e "$f" ]` test skips it). After the loop, if `DOTS > 0`: (a) append the carried basenames to the git exclude resolved via `git -C "$WORKTREE" rev-parse --git-path info/exclude` (idempotent — skip names already present), and (b) append the one-line security footnote to `$HANDOFF_DST`. Directional sketch:

```sh
DOTS=0; CARRIED_DOTS=""
for f in "$REPO_ROOT"/.env "$REPO_ROOT"/.env.* "$REPO_ROOT"/.envrc \
         "$REPO_ROOT"/.tool-versions "$REPO_ROOT"/.nvmrc; do
  [ -f "$f" ] || continue                 # skips unmatched literal globs under set -u
  base="$(basename "$f")"
  dst="$WORKTREE/$base"
  [ -e "$dst" ] && continue               # no-clobber: committed wins
  cp "$f" "$dst" 2>/dev/null && { DOTS=$((DOTS+1)); CARRIED_DOTS="$CARRIED_DOTS $base"; }
done
if [ "$DOTS" -gt 0 ]; then
  excl="$(git -C "$WORKTREE" rev-parse --git-path info/exclude 2>/dev/null)"
  for base in $CARRIED_DOTS; do
    [ -n "$excl" ] && ! grep -qxF "$base" "$excl" 2>/dev/null && printf '%s\n' "$base" >> "$excl"
  done
  printf '\n> **Security note:** carried local config (%s) into this worktree — secrets now live in a second on-disk location. Kept out of git via the repo'"'"'s shared git exclude (info/exclude); never commit them.\n' \
    "$(echo "$CARRIED_DOTS" | xargs)" >> "$HANDOFF_DST"
fi
```

Note: `"$REPO_ROOT"/.env.*` also matches `.env.` and could match `.env.example` — validate the expansion; if a repo commits a `.env.example` you do NOT want carried, tighten the allowlist. The `[ -f ]` guard (regular files only) avoids copying a directory that happens to match.

**Patterns to follow:** the conditional-append idiom already used for the handoff banner / `Source session` safety-net (`grep -q … || { printf … >> "$HANDOFF_DST"; }`).

**Test scenarios:**
- Happy path: source has `.env` and `.env.local` → both land in worktree root; `DOTS=2`; both names appear in `.git/info/exclude`; footnote appended once naming them.
- Guard: after carry, `git -C "$WORKTREE" status --porcelain` does NOT list the carried dotfiles (excluded).
- No-clobber: a committed `.tool-versions` already in the worktree is not overwritten.
- Conditional footnote: source has no allowlisted dotfiles → `DOTS=0`, no footnote appended, no exclude edit.
- Edge: allowlist pattern matches nothing → literal-glob guard (`[ -e ]`) prevents copying a literal `.env.*` path; no crash under `set -u`.
- Edge: `.git` is never a copy candidate (not in allowlist); confirm no allowlist glob can reach it.
- Idempotence: re-running the exclude-append does not duplicate lines (`grep -qxF` guard).

**Verification:** After a spinoff from a repo whose `.gitignore` does not cover `.env`, the carried `.env` exists in the worktree, `git status` is clean of it, and the handoff ends with the security note listing the carried files.

---

### U3. Collapse KICKOFF to a pointer + sync resubmit-guard

**Goal:** Replace the ~1080-char `KICKOFF` with a short pointer that fits a single safe paste, and keep the resubmit-guard match string aligned with the new first line (R5).

**Requirements:** R5.

**Dependencies:** none (independent of U1/U2).

**Files:** `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` (`KICKOFF` def `255`; resubmit-guard match `286`).

**Approach:** Set `KICKOFF` to a concise pointer, e.g.:

> "Read docs/handoff.md — it's the brief for this worktree (treat it as directional: orient and validate against the code, don't execute literally). Get oriented, then recommend the next compound-engineering step (/ce-brainstorm if ambiguous, /ce-plan if clear) with a one-line rationale, and wait for my direction."

Keep the resubmit-guard's `case` match a stable, unambiguous substring of the new first line — `*"Read docs/handoff.md"*` still matches the pointer above, so it may need no change; confirm the new first line still contains that exact substring and update `286` if the wording drifts. Do not reintroduce the long directional prose — it is authoritative in the handoff (KTD5).

**Test scenarios:**
- Length: the new `KICKOFF` is well under a conservative single-paste width (target ≤ ~300 chars; the prior string was ~1080). Note the ~300 figure is a safety target, not the measured truncation threshold — the actual cmux `send`/TUI paste limit is unmeasured, so shorter is safer.
- Guard sync: the resubmit-guard `case` pattern is a literal substring of `KICKOFF`'s first line (grep the two against each other).
- Behavior intent: the pointer still instructs read-handoff → orient → recommend-next-CE-step → wait (matches the received-session behavior the handoff expects).

**Verification:** `KICKOFF` fits one paste without truncation on send — confirm empirically against the real send path where feasible, not just by length target; the resubmit-guard still recognizes an un-submitted kickoff on the input line.

---

### U4. Extend smoke.sh, version bump, republish

**Goal:** Ship the fix: add fixture assertions for the new behavior to the canonical smoke-test, bump the plugin version, and republish so the installed mirror regenerates (R7, R8).

**Requirements:** R7, R8.

**Dependencies:** U1, U2, U3 (smoke assertions cover their behavior; publish must carry the finished script).

**Files:** `plugins/spinoff/skills/spinoff/scripts/smoke.sh` (add assertions); `plugins/spinoff/.claude-plugin/plugin.json` (`version` 0.7.0 → 0.7.1); marketplace publish (per the shrimpshack version-gated publish workflow).

**Approach:** First read `smoke.sh` and mirror its existing idiom (git-fixture setup + assert helpers). Add cases that run `spinoff.sh` against a fixture repo and assert:
- **Docs carry (U1):** a fixture with `docs/plans/a.md` (nested), `docs/odd-name.md` (non-plan-named), and an uncommitted `docs/wip.md` → all three land at the same relative paths in the worktree; `docs/handoff.md` is not overwritten by a source copy; the summary reports a non-zero docs count.
- **Dotfile carry + guard (U2):** a fixture with a root `.env` (and a repo whose `.gitignore` does NOT cover it) → `.env` lands in the worktree, `git -C <worktree> status --porcelain` does not list it (exclude guard works), and the handoff ends with the security footnote; a fixture with no allowlisted dotfiles → no footnote, no exclude edit.
- **Kickoff brevity (U3):** the `KICKOFF` string in the script is under the safe-paste target and the resubmit-guard match is a substring of its first line (static assertion against the script text is acceptable if driving a real send in the fixture isn't feasible).

Then bump `version` to `0.7.1` and run the marketplace publish workflow (version-gated) so `~/.claude/skills/cmux-spinoff/` regenerates from the new canonical script. Publish is a release action — confirm with Shawn before running it.

**Execution note:** Add the smoke assertions and confirm they fail against the current (unfixed) script before the U1-U3 edits land, so the tests genuinely exercise the fixes (characterization-style). If sequencing lands U1-U3 first, deliberately revert one fix locally to confirm the corresponding assertion fails, then restore.

**Test scenarios:**
- `smoke.sh` new assertions pass against the fixed script and fail against the unfixed behavior (deliberate-fail smoke check).
- `smoke.sh` remains runnable end-to-end (dependency-free, exits non-zero on any failed assertion, matching its existing contract).
- `plugin.json` `version` reads `0.7.1`; publish is gated on the bump (a re-publish without the bump is a no-op — see memory `project_shrimpshack_plugin_store_version_gated`).
- Post-publish: `~/.claude/skills/cmux-spinoff/scripts/spinoff.sh` reflects the U1-U3 changes (spot-check the recursive carry + short KICKOFF).

**Verification:** New smoke assertions pass on the fixed script (and demonstrably fail on the unfixed behavior); version bumped; after publish the installed mirror's script matches the canonical one.

---

## Scope Boundaries

**In scope:** the four units above — recursive docs carry, dotfile allowlist + secret guard, kickoff collapse, version/eval/publish.

**Out of scope (non-goals):**
- Widening the `find` name filter — superseded by the full-tree copy (KTD1).
- Chunked-send or kickoff-to-`docs/kickoff.md` alternatives — pointer-collapse chosen (KTD5).
- Editing the installed mirror `~/.claude/skills/cmux-spinoff/` directly — it regenerates on publish.
- Recursive dotfile carry or a broader dotfile set — root-level allowlist only (KTD3).

**Deferred to follow-up work:**
- Adding a canonical `evals/` directory to the plugin that the publish flow sources the mirror `evals.json` from. Today `evals.json` is mirror-only; extending the behavioral eval set properly needs publish-flow work. Out of scope here — mechanical coverage lives in the canonical `smoke.sh` (U4) instead.

---

## Open Questions

- **OQ1 — Resolved: verify via canonical `smoke.sh`.** The mirror `evals.json` was a dead end (mirror-only, publish-regenerated, violates the never-edit rule). Coverage moves to the existing canonical `smoke.sh` (U4), which gives real mechanical assertions on `spinoff.sh` output — better than behavioral prose and directly serves "verify it works." No open decision remains.
- **OQ2 — `cp -n` vs explicit existence check on the runtime `cp`.** The no-clobber primitive should be validated against the actual `cp` on the target platform (macOS/BSD). The plan uses an explicit `[ -e "$dst" ] && continue` guard to avoid depending on a flag; confirm that's preferred over `cp -n`.
- **OQ3 — `.env.*` allowlist breadth.** `"$REPO_ROOT"/.env.*` also matches `.env.example` / `.env.sample`, which are often committed templates rather than secrets. Decide whether to carry them (harmless, sometimes useful) or tighten the glob to exclude `*.example`/`*.sample`.

---

## Risks & Dependencies

- **Secret spread (mitigated).** Carrying `.env` places secrets in a second on-disk location. Mitigations: conservative allowlist (KTD3), `.git/info/exclude` guard so they can't be committed (KTD4), and a conditional handoff footnote flagging it (KTD6). Residual risk is local-disk exposure, which is what was explicitly requested.
- **`set -u` + unmatched globs.** The dotfile loop must guard against unmatched globs expanding to literals; the `[ -e ]` check handles it, but this is the most likely source of a silent bug — cover it in tests (U2).
- **Linked-worktree `.git` is a file, not a dir.** The exclude path must be resolved via `git rev-parse --git-path info/exclude`, not a hardcoded `$WORKTREE/.git/info/exclude` (KTD4).
- **Publish is version-gated and destructive-adjacent.** Republishing regenerates the installed mirror; run only after the script changes are final and confirmed (memory `project_shrimpshack_marketplace_publish_workflow`, `feedback_slate_plugins_marketplace_autoupdate_destructive_reclone`).
- **Dependency:** U4 depends on U1-U3 being complete before publish.

---

## Definition of Done

- A spinoff from a repo with nested, oddly-named, and uncommitted docs lands all of them (minus `handoff.md`) at correct relative paths in the worktree, without clobbering committed files.
- Allowlisted dotfiles are carried, excluded from git in the worktree, and flagged in the handoff footnote — only when actually carried.
- The kickoff sent to the launched session is short, untruncated, and the resubmit-guard still matches its first line.
- Summary and inline `step` messages report split docs / dotfiles counts honestly.
- `smoke.sh` carries new assertions for U1-U3 that pass on the fixed script and fail on the unfixed behavior.
- `plugin.json` bumped to 0.7.1, installed mirror republished (with confirmation).
