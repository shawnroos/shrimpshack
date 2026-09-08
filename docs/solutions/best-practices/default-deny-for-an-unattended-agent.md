# Default-deny for an unattended agent

**Measured 2026-08-14.** Every claim here was tested by observed effect — a
marker file only the tool could create, or an entry in a record the model does
not author. None of it rests on a model saying what it can do.

## The correction that started this

The plugin shipped believing this: *"a tool absent from both `allow` and `deny`
will RUN; only `deny` blocks; there is no default-deny to reach for."* The
repo-bounded ceiling's own comment said so, and a 40-name deny list was built on
it.

**It is false.** Re-measured across five configurations, a tool named in neither
list is *attempted and refused*, and the refusal lands in `permission_denials[]`.

Why both measurements were right:

| condition | outcome |
| --- | --- |
| a permission-**bypass** flag is active | nothing prompts, nothing is refused — restrictions defeated entirely |
| no bypass flag (what spawn does) | a not-allowed call *would* prompt, nobody can answer in headless, so it is **refused** |

**The rule: in headless, anything that would prompt is refused unless a bypass
flag is active.** Upstream issue #50303 documents the bypass half and was closed
as not planned — no allowlist mode is coming.

The consequence is easy to miss: **the load-bearing property of the inner layer
is the ABSENCE of a flag.** Nothing asserted that, so a future edit adding
`--dangerously-skip-permissions` to fix an unattended hang would have converted a
real boundary into none with every test still green. There is now a test.

Also measured: **a repo cannot widen its own ceiling.** A worktree granting
itself `Bash` in `.claude/settings.json` is still refused — `--settings`
outranks project settings.

## Why a deny list still was not enough

A deny list is an *enumeration*: every tool the harness adds later is permitted
until someone writes its name down. That is a property of the mechanism, not a
decision — and it is the exact defect class this repo keeps re-learning
(`enumeration_fixes_never_close_a_class`).

## The outer wall: a PreToolUse tool gate

Documented upstream and confirmed here: **a PreToolUse hook exiting code 2 stops
the call BEFORE permission rules are evaluated.** So it beats an allow rule
rather than merely adding to a deny.

| question | measured |
| --- | --- |
| do hook definitions load from `--settings`? | yes |
| does exit 2 block a tool `permissions.allow` permits? | yes |
| does it survive `--permission-mode bypassPermissions`? | **yes** |
| does the refusal appear in `permission_denials[]`? | yes |
| can the hook see `tool_name`? | yes, plus `tool_input`, `permission_mode`, `cwd` |

The third row is why it exists: it is the only mechanism measured that holds
under a bypass flag.

`hooks/tool-gate.sh` holds an **allow set** and refuses everything else, so a
tool that did not exist when it was written is refused *because it was never
named*. The allow set and the hook path are injected into the job's rendered
ceiling copy at launch; the shipped file stays a readable statement of policy.

### Three things that make it a gate rather than decoration

1. **Fail closed on every path.** Missing allow file, unparseable payload, empty
   tool name, absent `python3` — all exit 2. A gate that fails open is not a
   gate, and the shell's habit is to fall through.
2. **Literal comparison, never a pattern.** A `case` pattern read from the allow
   file would let a stray `*` permit everything. There is a test that a `*` in
   the allow file does *not* become a wildcard permit.
3. **Match on `tool_name`, never `tool_input`.** Matching command text is
   pattern-matching shell syntax, and this harness's own changelog records three
   permission bypasses that were all string-filter defeats — line continuation,
   compound operators, heredoc smuggling. The tool *name* is a closed set; its
   arguments are not.

### The prerequisite, which is not optional

**The job must not be able to write the file that defines its own bound.** This
is the live escape class in the field: agents that stay inside the box and write
a config a trusted process later loads (Cursor, Codex, Gemini CLI and
Antigravity were all escaped this way in 2026). Two things keep it shut and both
are needed — the gate script lives in the *plugin* tree, and the allow file lives
in the job's `mktemp -d` (umask 077) *outside* the worktree. Neither is reachable
through a ceiling whose writes are scoped to the worktree.

**AMENDED 2026-08-25, and this is the important half.** That prerequisite holds
only while every bound is TOOL-scoped. `Bash` became a caller-grantable tool, and
a shell is not the `Write` tool: the worktree path rules do not reach it. A
granted job writes anywhere the invoking OS user can, which includes the plugin
tree and therefore the gate script itself.

So the prerequisite is not a property of the design — it is a property of the
*ungranted* configuration. Under `--allow Bash` it is simply false, and there is
no version of it that can be made true from inside the same trust domain: an
integrity check would live in the same writable tree. Measured once: a granted
child asked to disarm its own gate copy did not do so, with the file writable and
nothing stopping it — that is the model declining, not a bound, and it must not be
recorded as protection.

The honest statement, which the shipped comments now carry: granting a shell to an
unattended job is not a wider ceiling, it is the absence of one, and the mitigation
is that the grant is explicit, refused by default, and named in the job record.

### The join that would have broken silently

There are now two layers, and **a grant must clear both.** Because the gate
default-denies by *name*, a tool added only to `permissions.allow` would pass the
permission layer and then be refused by the gate — a grant that reads as applied
and is not. `spawn::ceiling_grant` writes both in one call, and a mutation test
confirms the assertion is load-bearing.

## What this still does not cover

Say this as loudly as the feature:

- **Damage inside the allowed worktree.** `rm -rf` of the branch's own files uses
  permitted writes on permitted paths.
- **Reads.** Every mechanism here sees writes, processes or requests. A job that
  reads a private key and prints it into its own narrative is invisible to all of
  them.
- **A deny PATH rule leaves no `permission_denials[]` entry**, so for those rules
  "blocked" and "never attempted" remain indistinguishable. A tool-gate refusal
  *does* appear.

## How to verify it, if you doubt this doc

Do not test with `Bash` — it is in the deny list, so blocking it proves nothing
about the gate. Use a tool the deny list **permits** and the allow set omits.
`WebSearch` is exactly that (it is deliberately not denied, being the one
grantable tool). The live arm in `tests/unit/ceilings.bats` does this, and
removing the gate makes it go red.
