---
title: "A permission allow-list is only as narrow as its widest bare tool, and its own doc can assert a bound it does not have"
date: 2026-08-12
module: plugins/spawn
problem_type: documentation_gap
component: tooling
severity: high
category: documentation-gaps
symptoms:
  - the shipped ceiling for unattended jobs scopes Read, Write and Edit to the worktree but lists Glob and Grep with no path argument at all
  - Grep returns matching file CONTENT, not just paths, so the bare entry is a whole-machine read surface on the config built for the case where nobody is watching
  - the config's own comment describes three careful bounds and never mentions the two bare entries, so the file reads as narrower than it is
  - the plugin's skill documentation asserted the ceiling was worktree-bounded, a property the file does not have
  - nothing errors and nothing is denied, so the gap produces no signal at runtime and no failing test
applies_when:
  - reviewing or writing a permission allow-list, settings profile, or any capability ceiling
  - an allow-list mixes path-scoped entries with bare tool names in the same list
  - prose, a comment, or a skill doc describes the bounds of a config file it does not live in
  - the ceiling exists specifically for unattended or background execution with no human to answer a prompt
resolution_type: documentation_update
related_components:
  - documentation
  - development_workflow
tags:
  - permissions
  - allowlist
  - least-privilege
  - spawn
  - doc-drift
  - unattended-execution
  - grep
  - silent-failure
---

## Context

`plugins/spawn/permissions/repo-bounded.settings.json` is the spawn plugin's shipped
permission ceiling for a background job whose caller was an agent — the case where no human
is present to answer for it. `plugins/spawn/lib/ceilings.sh:106` resolves it (or the
operator's override, `SPAWN_CEILING_CONFIG_REPO`), `spawn::ceiling_render`
(`plugins/spawn/lib/ceilings.sh:135-149`) substitutes `{{WORKTREE}}` with the job's
worktree, and `plugins/spawn/lib/bg-agent.sh:554` renders that copy for the child to run
under.

The file's `allow` list is five entries (`repo-bounded.settings.json:5-11`):

```json
"Read(//{{WORKTREE}}/**)",
"Glob",
"Grep",
"Write(//{{WORKTREE}}/**)",
"Edit(//{{WORKTREE}}/**)"
```

Three carry a path argument. `Glob` and `Grep` are listed bare — a tool name with no path
argument is not scoped to anything. `Grep` returns matching file **content**, not merely
paths. So the ceiling written for exactly the case where nobody is watching —
`defaultMode: dontAsk` (`repo-bounded.settings.json:4`), `Bash` deliberately absent from the
allow list — has an unbounded read surface across whatever the child user can read.

The same file's `$comment` (`repo-bounded.settings.json:2`) narrates "Three bounds, each
measured against the real CLI," and every one of the three is about writes, execution paths,
or configuration. It is a careful, specific, measured paragraph. It does not describe the
read surface, and reading it leaves you believing the ceiling is tighter than the list
below it.

How the mismatch surfaced: the plugin's own documentation asserted the ceiling was
worktree-bounded — a property the file does not have. PR #42 ("spawn: say what each surface
can actually reach") corrected the description in `plugins/spawn/skills/spawn/SKILL.md:60`,
which now says `Read`, `Write` and `Edit` are scoped to the worktree "plus `Glob` and
`Grep`, which are allowed unscoped." That correction came from checking every claim against
the file rather than against memory of it.

**The file's own gap is still open.** At the current tree the allow list is unchanged:
`Glob` and `Grep` remain bare. The description gap is not fully closed either —
`plugins/spawn/README.md:455-459` still summarises the ceiling as "reads, greps, writes and
edits are **scoped to the worktree**," the exact claim PR #42 removed from the skill; that
PR touched `SKILL.md`, not the README.

## Guidance

**Read an allow-list as the union of what each listed tool can reach, not as the intent the
list is named after.** The ceiling is only as narrow as its widest entry. A list of four
tightly-scoped entries and one bare one is a bare ceiling with four decorations.

The concrete rule for reading a permission entry:

1. Take each entry on its own. `Tool(path)` is bounded by that path. `Tool` alone is
   bounded by nothing — no path argument means no path bound, and there is no implicit
   inheritance from the neighbouring entries or from the file's name.
2. Ask what the tool **returns**, not what it is called. `Glob` returns paths; `Grep`
   returns matching content. Both are reads. Grouping them mentally under "search" is what
   lets an unbounded content read pass as harmless.
3. Compute the union and state it as the ceiling. If the union is wider than the file's
   name or comment implies, the name and comment are wrong, not the union.

**Audit prose against the artifact it describes, not against the intent behind it.** The
`$comment` in the ceiling file and the plugin docs were both written from what the ceiling
was *for*. Re-reading them against that intent confirms them every time. The only check that
catches this is reading the description with the allow-list open, entry by entry, and asking
which listed entry supports each sentence.

**Fix every copy of a corrected claim, not the one you were looking at.** The same sentence
lived in the skill and in the README. Correcting one leaves the other reading as an
independent confirmation of the wrong thing.

## Why This Matters

**The read surface is where a ceiling for unattended work is weakest.** The write bounds
here are carefully built and genuinely hold — writes and edits are scoped, path resolution
happens before matching so an escaping symlink falls outside the allow, and version-control
internals and agent configuration are denied outright (`repo-bounded.settings.json:12-27`).
`Bash` is absent from the allow list, so a shell call is refused and recorded. All of that
effort sits on one side of the file. The other side is two bare words.

The contrast inside the file is sharp once you look for it: the fourteen deny rules are
written `//**` — every path on the machine, deliberately, so a job cannot leave something
behind anywhere. The deny floor is unbounded **by design**. The read ceiling is unbounded
**by omission**. Same file, same breadth, opposite intent.

**The asymmetry is what makes it hard to catch.** A violated write bound is obvious: a file
exists that should not, a hook is on disk, a config was widened. It leaves an artifact
someone finds. A read leaves nothing behind — no baseline to diff, no file to find missing.

**On severity, honestly.** An earlier grounding pass on this question established that the
routes out of a background job are narrow: with no `Bash`, no `WebFetch`/`WebSearch` and no
MCP configuration available to it, what a job reads can only leave through a file it writes
into its own (bounded) worktree or through its own returned text — both of which are already
surfaced to the caller (session history). That reframes the bare entries as a guardrail gap
against a wandering or misdirected agent rather than an open exfiltration path. It does not
make the gap fine: the guardrail exists precisely because nobody is reading the job's
narrative live, and the caller who dispatched it was told the reads were bounded.

**A confidently-worded doc is what stops anyone from re-checking.** The `$comment` is
specific, measured, and cites real CLI behaviour. Its quality is the problem: a vague comment
invites verification, a precise one closes the question. Anyone dispatching a job under this
ceiling reads "three bounds, each measured" and stops.

## When to Apply

- Any settings, allow-list, or policy file — permission configs, IAM policies, CORS or CSP
  lists, firewall rules, agent tool grants.
- Any document that describes one, including a comment inside the file itself. A file that
  narrates its own guarantees is the highest-risk case: the description and the artifact
  ship together and read as one thing, so nobody diffs them.
- Any ceiling handed to a process no human is watching — unattended jobs, cron, CI runners,
  background agents. The weaker the observation, the more the read surface matters.
- Whenever a doc correction lands. PR #42 changed the description in one file; check
  whether the artifact still has the gap, and whether other files repeat the old claim.
  Both are true here.

## Examples

The real allow list, with each entry read on its own terms
(`plugins/spawn/permissions/repo-bounded.settings.json:5-11`):

| entry | bounded? | what it reaches |
|---|---|---|
| `Read(//{{WORKTREE}}/**)` | yes | files under the job's worktree |
| `Glob` | **no** | paths anywhere the child user can read |
| `Grep` | **no** | file **content** anywhere the child user can read |
| `Write(//{{WORKTREE}}/**)` | yes | the worktree, minus the deny rules |
| `Edit(//{{WORKTREE}}/**)` | yes | the worktree, minus the deny rules |

The `//` prefix on the bounded entries is not cosmetic: a permission path is absolute only
when it begins with `//`, which is why the template writes `//{{WORKTREE}}/**` and the
substitution drops the leading slash (`plugins/spawn/lib/ceilings.sh:125-149`). A rule
written `/Users/...` matches nothing and reads as an allow that silently is not one.

A bounded form would carry the same argument the write entries carry:

```json
"Glob(//{{WORKTREE}}/**)",
"Grep(//{{WORKTREE}}/**)"
```

Stated only as what the shape would be — this is a documentation capture, and whether that
exact syntax is honoured by the permission system for these two tools has not been measured
here. Measure it before relying on it; the same file's `$comment` records that every bound
in it was checked against the real CLI, which is the standard any replacement should meet.

**The test would not have caught this.** `plugins/spawn/tests/unit/ceilings.bats:292-343`
(AE10, "the repo-bounded ceiling scopes writes to the worktree and denies hooks and agent
config") is the test that asserts the ceiling's shape. It checks that
`Write(//<worktree>/**)` and `Edit(//<worktree>/**)` are present in `allow`
(`ceilings.bats:303-306`), that no `{{WORKTREE}}` placeholder survived the render
(`ceilings.bats:308`), that nine specific deny rules are present
(`ceilings.bats:316-327`), and that `Bash` appears in neither the allow list nor as a
tool-level deny (`ceilings.bats:333-338`). It never names `Glob` or `Grep`, and — the
load-bearing part — it never asserts the allow list is **exhaustive**. It tests membership,
so it is satisfied by a list containing the right entries plus anything else. A test that
pinned the allow list as a whole would have made the two bare entries visible on the day
they were written.

The test even records the read surface as intended, at `ceilings.bats:340-342`: "R25 denies
EXECUTION-bearing paths, not readable ones: within its bound the model still reads whatever
the worktree contains." The phrase *within its bound* is the assumption the bare `Grep`
breaks, written into the test as a comment rather than as an assertion. The same sentence
appears in `plugins/spawn/lib/bg-repo.sh:32-36`.

## Related

- [A default-allow safety gate on a regex dialect projection silently drops matches](../logic-errors/default-allow-regex-projection-gate-silently-drops-nudges.md)
  — the sibling instance of this defect class in another plugin: a permit-list whose real
  reach was never diffed against the claim made about it. Different mechanism, same failure
  to verify.
- [Selecting processes by a shared script name double-counts and reaches into other worktrees](../best-practices/pgrep-pkill-by-shared-script-name-is-unsound-across-worktrees.md)
  — the same one-sentence shape on a different subject: a selector believed to be
  worktree-bounded is in fact wider, and nothing errors either way.
- A design that would close the file's gap by making the sandbox tight by default and
  letting the caller grant beyond it per job is in flight: an as-yet-uncommitted plan file,
  `docs/plans/2026-08-12-001-feat-spawn-caller-granted-sandbox-plan.md`, sitting in the
  `task/spawn-grep-ceiling-scope` worktree — not on `main`, and not yet committed to that
  branch either, so it may not survive. Look for it before proposing a narrow patch to the
  two entries (session history).
