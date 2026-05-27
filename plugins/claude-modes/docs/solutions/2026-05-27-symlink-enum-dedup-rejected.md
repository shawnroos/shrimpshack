# Symlink-enumeration dedup: rejected by measurement

**Date:** 2026-05-27
**Class:** Structural-debt evaluation (deferred from a thermo-nuclear audit)
**Verdict:** Do NOT collapse. The cost outweighs the win.

## The proposal

Thermo-nuclear audit (symlink-lifecycle layer) flagged a duplication: the
Python reconciler at `lib/reconcile-symlinks.py` enumerates plugin-owned
symlinks (`_enumerate_plugin_symlinks`, `_enumerate_staging`,
`_current_symlinks_match`), and the Bash rebuilder at
`lib/symlink-rebuild.sh` enumerates the same set
(`__claude_modes::enumerate_plugin_symlinks`). Suggested code-judo: have
symlink-rebuild.sh expose a `claude_modes::symlink_diff` function and have
reconcile call it via subprocess, removing ~80 lines of Python.

## The measurement

Hot path: this runs on every SessionStart. Reconcile calls the enumerator
**at least 4 times** per run (commands + agents for fast-path check; same
again if rebuild fires).

Measured costs on this machine (macOS, /usr/bin/python3 3.9):

- Bash subprocess startup: **~20ms per `bash -c ':'`** (1.019s for 50)
- Python in-process directory enumeration of `~/.claude/commands`:
  **~0.27ms per call**

So:

| Approach | Cost per enumeration | × 4 calls / SessionStart |
|---|---|---|
| In-process Python (current) | 0.27ms | ~1ms |
| Shell-out to Bash (proposed) | 20ms+ | **80ms+** |

That's a **~70× slowdown** on a hook the user feels directly on every new
Claude Code session.

## The verdict

The dedup saves ~80 lines of code at a cost of ~80ms per SessionStart. That
trade is wrong. The duplication is genuinely the smaller cost.

**This is the same shape of judgment as the inline validator/resolver
copies that were kept in 0.3.0**: a Bash↔Python language-boundary
duplication is unavoidable when the call site is on a hot path. The
existing pattern is "accept the duplication, guard against drift with an
equivalence test." That pattern applies here too, *if* drift becomes a
risk worth guarding. Today it isn't (the two enumerators have different
output formats — Python returns `Set[str]` of basenames matched against
the staging root via realpath; Bash prints lines via a slightly different
classification routine — and they don't need byte-equivalence because
they're consumed by different code paths within the same reconcile flow).

## When this verdict would flip

- Bash subprocess startup gets meaningfully cheaper (unlikely on macOS).
- Reconcile's enumeration count drops to ≤1 per SessionStart (would
  require restructuring the fast-path check, which the existing structure
  doesn't need).
- A bug surfaces where the two enumerators silently diverge on a real
  classification — at which point the answer is an equivalence test, not
  a collapse.

## What stays

- `lib/reconcile-symlinks.py::_enumerate_plugin_symlinks` etc. — the
  Python in-process enumerator. Marked: see this doc for the deferral verdict.
- `lib/symlink-rebuild.sh::__claude_modes::enumerate_plugin_symlinks` —
  the Bash enumerator. Marked: see this doc.
- A short pointer comment in both files referencing this verdict.

## Related

- The thermo-nuclear pass that surfaced this:
  Family-3 of the 2026-05-27 duplication cleanup loop.
- The general pattern (accept Bash↔Python duplication on hot paths,
  pin with equivalence test if drift becomes a risk):
  `tests/integration/active-mode-resolver-equivalence.test.sh`,
  `tests/integration/mode-body-read-equivalence.test.sh`.
