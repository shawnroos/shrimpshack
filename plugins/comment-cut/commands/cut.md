---
description: Cut comment bloat out of a branch without losing the comments that matter. Scopes the diff against a base ref, sweeps the mechanical classes, then does the judgement cut area by area, proving at every step that only comments changed.
argument-hint: "[<scope-path>] [--base <ref>] [--bar <path>]"
---

Run a comment-cut pass over **$ARGUMENTS**.

Use the Skill tool to invoke `comment-cut:comment-cut`, and hand it the arguments below. The skill owns the keep/cut bar, the gates, and the phase order; this command only resolves what to point it at.

Resolve the three arguments before invoking:

- **Scope path** — the directory or path prefix to cut under. When `$ARGUMENTS` names one, use it. When it does not, ask which subtree to cut rather than defaulting to the whole repo; a repo-wide pass reports pre-existing hits outside the change and can never reach zero.
- **`--base <ref>`** — the ref the diff is scoped against. Default to the merge-base with the repository's default branch. Pin it to a fixed commit, not `HEAD`, when the branch will sync with a moving upstream during the pass.
- **`--bar <path>`** — an explicit keep/cut bar. Pass it through only when `$ARGUMENTS` names one. Otherwise let the skill resolve the bar from the target repo in its own documented order; it must never fall back to a copy baked into the plugin.

Two things to carry into the invocation:

- The detector is advisory. It reports the mechanically-detectable classes and stays silent on everything else, so a clean run is **not** evidence the bar was met. The judgement cut is the part that does the work.
- Never seed a worker with an expected cut ratio, high or low. Workers hit a stated target, and a ratio given as guidance has measurably suppressed the cut in load-bearing files.

Report the retention alongside the cut: lines removed is half the number, lines re-added as tightened survivors is the other half.
