# Spinoff: scope (or honestly document) the unscoped Glob/Grep hole in spawn's repo-bounded ceiling

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal

`plugins/spawn/permissions/repo-bounded.settings.json` is the permission ceiling
for `/spawn:bg-agent` — the one spawn surface that runs unattended. It confines
writes and file reads to the worktree, but **`Glob` and `Grep` are allowed with no
path scope at all**. Decide whether to scope them, or to leave them and make every
document that describes the ceiling tell the truth. Either outcome is acceptable;
shipping a doc that overstates the bound is not.

## Why now / context

Found while fact-checking a tool-guidance skill against the code (that check is
commit `2809c67` on `task/spawn-tool-guidance`). The doc claimed all five tools
were worktree-scoped. The file says otherwise. Verified on disk — the allow list
is exactly:

```
Read(//{{WORKTREE}}/**)
Glob                      <- no path scope
Grep                      <- no path scope
Write(//{{WORKTREE}}/**)
Edit(//{{WORKTREE}}/**)
```

plus 14 deny rules. **`Bash` is absent entirely** — worth holding onto, because it
means a bg-agent job cannot run a test, a command, or `git log`.

The reason this matters more than it first looks: **Grep returns matching
content**, not just a list of paths. An absolute path argument therefore reads text
out of any file on the machine — while `Read`, the tool that *looks* like the
reading tool, is properly confined. `Glob` leaks paths the same way. So the ceiling
built for "nobody is watching" has the widest read surface of the two ceilings.

This is the plugin's recurring defect class showing up in a new place: **a check
narrower in reality than the invariant it claims to hold.** Same shape as the
`SPAWN_SECURITY_BIN` P1 and the duplicate-scan holes. See
`docs/residual-review-findings/` and the memory
`feedback_checks_narrower_than_their_invariant`.

## Key decisions already made

- **This is a decision, not a foregone fix.** Scoping is a behaviour change to a
  ceiling that has shipped. Do not treat "add `//{{WORKTREE}}/**`" as obviously
  correct — it may break legitimate jobs.
- **`ceiling_selectable` stays `false`.** There is deliberately no `--ceiling`
  flag; the bound is fixed by which settings file ran, not by anything a caller
  asserts (`ceilings.sh:12`). Do not add one, and do not "solve" this by letting a
  job request a wider ceiling.
- **Deliberately NOT fixed in the session that found it.** Correcting the doc was
  in scope there; changing the ceiling was not. That's why this is its own branch.
- **The doc half is not optional.** Whichever way the decision goes, the settings
  file's own comment and the SKILL.md text must end up true. The doc asserting a
  property the file did not have is precisely what hid this.

## Open questions / not yet decided

1. **What does a scoped `Grep` rule actually permit?** `Grep` with no path argument
   defaults to cwd. Under `Grep(//{{WORKTREE}}/**)`, does a bare no-path call still
   match, or does it fall outside the allow and start landing in
   `permission_denials[]`? **Establish this empirically. Do not reason about the
   permission matcher's semantics from first principles** — the whole finding
   exists because someone asserted a property instead of testing it.
2. **Does `operator.settings.json` have the same shape?** Check before deciding;
   it may want the same treatment, or may be intentionally wider.
3. **Is unscoped Glob/Grep defensible on purpose?** A job that must read a sibling
   package or a system config to do its work would need it. If it is deliberate,
   the fix is a *precise* comment plus a stated threat model, not a scope change.
4. **What is the actual exposure?** Reading a file's content is one thing;
   exfiltrating it is another. bg-agent has no `Bash` and no network tool, so map
   what a job could genuinely do with what it reads before sizing this.

## Starting point

- `plugins/spawn/permissions/repo-bounded.settings.json` — the allow list and its
  misleading comment.
- `plugins/spawn/permissions/operator.settings.json` — the sibling ceiling.
- `plugins/spawn/lib/ceilings.sh` — selection logic; `:12` states the no-flag
  policy, `:104-106` reads `SPAWN_CEILING_CONFIG_REPO` from the environment (an
  operator-level override, framed as user configuration in R25).
- `plugins/spawn/commands/bg-agent.md:53` — already the most precise phrasing in
  the tree ("*writes* scoped to the worktree"); prefer its shape.
- **Read commit `2809c67` on `task/spawn-tool-guidance` before editing any ceiling
  doc** — it just rewrote those exact sentences, and duplicating that work or
  contradicting it is the easy mistake here.
- `tests/unit/surfaces.bats` — owns the doc invariants. Two opt-in live ceiling
  tests exist behind `SPAWN_CEILING_LIVE=1` (they cost money; they are the 2
  skips in a normal green run). Those are likely where a real
  cannot-grep-outside-the-worktree assertion belongs.

## Constraints (inherited, non-negotiable)

- Exactly one JSON object on stdout on **every** path including failures;
  diagnostics to stderr only.
- Frozen exit enum: 0 ok · 2 usage · 3 unreachable · 4 alias unknown · 5 upstream ·
  6 deadline · 7 auth. New classes go in `error`, never a new exit code.
- `tests/unit/escapes.bats` fails the suite on any byte-identical function body
  across two shipped files — copy-paste will not land.
- **Mutation-verify any new assertion.** Write the test, revert the settings
  change, watch it go RED, restore, watch it go green. A test that passes both
  before and after proves nothing. This is a hard bar in this plugin, earned the
  hard way — see `feedback_mutation_test_not_inject_fail_proves_assertions`.

## Sibling work in flight — read this before you rebase

Two branches touch the same plugin and neither is pushed:

- `task/spawn-drop-gw` — removes the `gw` step from setup so the plugin never
  touches the user's `~/.local/bin/gw`. ~14 files, uncommitted as of this handoff.
- `task/spawn-tool-guidance` — commit `2809c67`, clean, 489 passing. Where this
  hole was found.

Base is `origin/main`, which as of 16:47 today carries PR #41 ("spawn: say what
the user gets, not what it is built on") — the plain-language rewrite of the
README and all five command descriptions. Expect to rebase onto whichever sibling
lands first, and expect textual overlap in the README and SKILL files rather than
logical conflict.

## Recommended next step

`/ce-brainstorm`. The scope-vs-document call is genuinely open and hinges on an
empirical unknown (question 1) plus a threat-model judgement (question 4) — that
is ambiguity about *approach*, not just sequencing, which is what brainstorm is
for. Jumping to `/ce-plan` would bake in "scope it" as the answer before anyone
has established what a scoped rule actually permits. Validate that read against
what you find; if question 1 resolves cleanly and the answer is obviously "scope
it", go straight to `/ce-plan`.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos-projects-shrimpshack-worktrees-gateway-plugin/a518d741-a626-447a-9b77-dbef6ce6c59d.jsonl`
Resume:     `cd /Users/shawnroos/projects/shrimpshack && claude -r a518d741-a626-447a-9b77-dbef6ce6c59d`
