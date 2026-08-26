# comment-cut

Cut the comments that say nothing. Keep the ones that say what the code cannot.

A comment earns its place only if deleting it would let a competent reader ship a **silent** bug. Four things clear that bar: a measured or tuned constant, a non-obvious ordering or timing constraint, a footgun that fails silently, and a deliberate deviation from surrounding convention. Everything else goes — docblocks restating the signature, banner headers, narration of the next line, commented-out code, changelog and attribution notes.

The plugin is three things: a skill that runs the pass, a command that starts it, and a gate that catches bloat at the moment it would land.

## The pass

```
/comment-cut:cut src/app/some-subtree
```

Scopes the diff against a base ref, sweeps the mechanical classes, then works area by area doing the judgement cut — proving at every step that only comments changed. Optional arguments: `--base <ref>` to pin the diff endpoint, `--bar <path>` to name the keep/cut bar explicitly.

Give it a subtree. A repo-wide pass reports pre-existing hits outside your change and can never reach zero.

**The bar lives in the target repo, never in this plugin.** It resolves in order: an explicit `--bar`, then `.rulesync/rules/comment-essential-only.md`, then `.claude/rules/comment-essential-only.md`. If none resolve the skill stops rather than falling back to a copy baked in here. In repos using rulesync, `.claude/` is generated and gitignored — the tracked source is `.rulesync/`, which is why it is tried first.

## The gate

A `PreToolUse` hook runs the detector on the files a `git commit` or `gh pr create` is about to land. When the change adds comment bloat **on the lines it touches**, the call is denied once, with the findings as the reason. Re-issue the same command and it proceeds, whether or not you cut them — it interrupts, it never refuses.

**It is off until a repo opts in.** Create the marker:

```
touch .comment-cut-gate
```

Without that file the hook is a silent no-op. This is deliberate: a `PreToolUse` matcher on `Bash` carries no repo scoping of its own, and a personal comment bar has no standing in a team repo.

Two ways to turn it off again:

- **One repo** — delete its `.comment-cut-gate`.
- **Everywhere, for this session** — set `COMMENT_CUT_GATE_OFF=1`.

Two limits worth knowing. The gate only sees commands issued inside a Claude session; a commit you type in a terminal is not gated. And it fails open on everything — no `jq`, no `git`, no python, an unreadable checker, a malformed payload, a git dir it cannot write — because it runs ahead of every Bash call, and a bug there would cost you a commit.

## The detector on its own

```
tools/comment-cut/run.sh                # files changed vs HEAD
tools/comment-cut/run.sh --all          # every tracked JS/TS file
tools/comment-cut/run.sh path/to/file.ts
tools/comment-cut/run.sh --porcelain …  # file:line:kind, exits 1 on findings
tools/comment-cut/run.sh --self-test    # the built-in fixtures, both directions
```

Every path but `--porcelain` exits 0 whatever it finds, so a human run can never block a commit. `--porcelain` exists for the gate.

**A clean run is not evidence the bar was met.** The detector reports only the mechanically-detectable classes and stays silent on everything else, because it cannot judge whether a comment is load-bearing. The judgement cut is the part that does the work.

## Tests

```
bash tests/harness.sh
```

Covers the detector's both-directions self-test, the fixture files end to end, fixture-to-inline-list parity, the porcelain-versus-default exit contract, and the gate — its deny path, its allow-on-retry, its opt-in, and every fail-open path including a linked worktree and an unwritable git dir.

The harness asserts a floor on how many assertions ran. A failed `cd` or an empty glob otherwise produces zero assertions, and zero failures reads exactly like a clean run.

The `.ts` fixtures are generated from the inline lists in `check.py` by `tools/comment-cut/fixtures/render.py`; the suite fails if the checked-in copies have drifted. Before trusting a change to the detector, mutate it and watch the suite go red — a mutation that stays green means nothing is checking that rule.
