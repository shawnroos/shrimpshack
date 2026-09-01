# Bounding an unattended background agent — ideation

**Date:** 2026-08-14 · **Subject:** how the `spawn` plugin should bound what an
unattended bg-agent can do · **Status:** premise corrected mid-run

---

## Read this first: the question changed

This session was run to answer *"how do we bound an unattended agent given the
harness offers no default-deny?"*

**That premise is false.** Measured today, by observed effect, across five
configurations: a `--settings` ceiling on headless `claude -p` **does**
default-deny. A tool named in neither `allow` nor `deny` is attempted and
refused, and the refusal lands in `permission_denials[]`.

The decisive case: with the ceiling allowing only `Read`, the model tried Bash
(denied), then fell back to **`Write`** — a tool named nowhere in the settings —
and that was denied too. Positive control: an allowed `Read` returned the canary
with zero denials, so the child was functional and the refusals were enforcement,
not a model politely declining.

Also confirmed: **a repo cannot widen its own ceiling.** A worktree that grants
itself `Bash` in `.claude/settings.json` is still refused — `--settings` wins.

The shipped plugin already gets this. `ceilings.sh:221-225` builds
`--setting-sources` + `--settings` + `--permission-mode dontAsk`, and
`bg-agent.sh:974` execs with it.

### Why the old measurement and this one are both right

Prior art resolved the contradiction. Anthropic issue
[#50303](https://github.com/anthropics/claude-code/issues/50303) is titled
"`--allowedTools` has no effect **when permission bypass flags are active**" —
and that qualifier is the whole story. The documented model is
`deny` → `ask` → `allow`, where `allow` only *skips a prompt*. So:

- **With a bypass flag** (`--dangerously-skip-permissions` / `bypassPermissions`):
  nothing prompts, nothing is refused, and tool restrictions are defeated
  entirely. This is the state the 2026-08-13 measurement captured.
- **Without one** (what spawn does): a call that isn't allowed *would* prompt,
  there is nobody to answer in headless, so it is **refused**. That is
  default-deny in effect, and it is what today's five probes measured.

The unifying rule: **in headless, anything that would prompt is refused unless a
bypass flag is active.** The load-bearing property of the spawn ceiling is
therefore *the absence of a bypass flag*, which no test currently asserts.
That is a gap worth closing — see idea 0.

Issue #50303 was **closed as not planned**. Nobody is shipping an
`allowlistOnly` mode; do not wait for one.

**Consequences for the idea set:**

- The heavy substrate ideas (VM, dedicated UID, `pf`, remote execution) were
  justified almost entirely by "there is no outer wall." There is one. They drop
  below their cost line.
- The 40-rule deny list in `repo-bounded.settings.json` is not the load-bearing
  boundary it was believed to be. It is defence in depth on top of a real
  allow-gate. Worth keeping, not worth growing.
- What survives are the ideas that close gaps a tool-gate **structurally cannot**
  close — and those gaps are real.

## What a working tool-gate still does not cover

1. **Damage inside the allowed worktree.** `rm -rf` of the branch's own files,
   or editing `.git/hooks`, uses permitted writes on permitted paths.
2. **Reads.** Every mechanism considered sees writes, processes or requests. A
   child that reads a private key and prints it into its own narrative is
   invisible to all of them. *(Named by all three frames independently.)*
3. **Blocked vs never-attempted.** A `deny` **path** rule refuses but leaves
   `permission_denials[]` empty, so a bound that held and a job that never tried
   look identical.
4. **Grant lifetime.** `--allow X` widens the child for the *whole job*,
   including the turn where it reads an untrusted README.

---

## Ranked ideas

### 0. Assert the absence of a bypass flag — a one-line test for the property everything rests on

**Axis:** upstream/harness · **Confidence:** High · **Complexity:** XS

The ceiling holds *because* no bypass flag is passed. Nothing in the suite says
so. A future edit adding `--dangerously-skip-permissions` to fix some unattended
hang would silently convert a real boundary into no boundary, and every existing
test would stay green.

**Basis — direct:** issue #50303 documents that any bypass flag defeats tool
restrictions entirely; `ceilings.sh:221-225` is the exact flag set that must stay
bypass-free.

**Why it ranks zeroth:** it is the cheapest item on the list and it protects
every other item. Assert on the constructed `SPAWN_CEILING_FLAGS` array that no
element matches `--dangerously-*` / `bypassPermissions`, and mutation-verify it
by adding one.

**Downsides:** none. This is a guard, not a feature.

### 0.5 Catch-all PreToolUse hook — deny before permission rules are evaluated

**Axis:** invert · **Confidence:** High — **MEASURED 2026-08-14** · **Complexity:** M

> **VERIFIED.** Every unknown below was tested by effect and resolved. Results:
>
> | question | answer |
> | --- | --- |
> | Do hook definitions load from `--settings`? | **YES** — hook fired, marker written |
> | Does a code-2 hook block a tool that `permissions.allow` permits? | **YES** — Bash allowed, still blocked |
> | Does the hook survive `--permission-mode bypassPermissions`? | **YES** — still blocked |
> | Does a hook denial appear in `permission_denials[]`? | **YES** — `['Bash']` |
> | Can the hook see `tool_name` for allow-set logic? | **YES** — plus `tool_input`, `permission_mode`, `cwd` |
>
> **Control arm:** identical settings with the hook removed → Bash **ran** and
> created the marker. So the block is the hook, not an unrelated refusal.
>
> **Full allow-set demo, all under `bypassPermissions` with Bash/Write/Edit/
> WebFetch every one of them in `permissions.allow`** — the hook permitting only
> `Read|Glob|Grep|TodoWrite`:
> - `Read` → returned the canary. Works.
> - `Bash` → blocked.
> - `Write` → blocked.
>
> This is genuine default-deny, decided per call in code we own, and it is the
> **only mechanism measured that holds under a bypass flag**. It is strictly
> stronger than the current `--settings` ceiling, which idea 0 exists to protect
> precisely because a bypass flag defeats it.

Documented behaviour: a PreToolUse hook fires on every tool call except
`EndConversation`, its matcher accepts `"*"` as match-all, and **a hook exiting
with code 2 stops the call *before* permission rules are evaluated — so it blocks
even where an allow rule would have permitted it.**

A hook that denies any `tool_name` outside a small allow set is default-deny by
construction, decided per call in code we own. It survives a bypass flag (which
is what makes it strictly better than the current ceiling), and it closes the
class the 40-rule deny list leaves open.

**Residual unknowns** (the load-bearing ones are now measured):
- Whether hooks fire in an *untrusted* folder — probes ran in a `git init`'d dir.
  Workspace-trust rules skip some hook sources; `--bare` disables project hooks
  entirely. Test before shipping.
- Hook latency per tool call — one subprocess spawn per call. Fine for a bash
  script; measure if it grows.
- `disableAllHooks` is a settings key. Confirm a lower-precedence source cannot
  set it to switch the ceiling off.

**Hard prerequisite:** the job must not be able to write the file that defines
its own bound. This is the live escape class in the field — Pillar Security
escaped Cursor, Codex, Gemini CLI and Antigravity by having the agent "write a
file that a trusted tool outside the box later runs." The ceiling already denies
`.spawn/` writes; it must deny `.claude/settings.json`, `.claude/hooks`, and
`.mcp.json` the same way.

### 1. Export gate on a disposable clone — the job's output is a declared list, everything else is discarded

**Axis:** substrate · **Confidence:** High · **Complexity:** M

Run the child in an ephemeral copy of the worktree. Nothing it produced becomes
durable unless the supervisor copies out a path the contract already named in
`deliverables[]`; the copy is then thrown away whatever the outcome.

**Basis — direct, measured today:** `cp -c -R` (APFS clone) of a 200 MB tree took
**17 ms** with no meaningful disk cost. The isolation is effectively free.
`deliverables[]` is already mandatory in the contract, and the supervisor already
diffs deliverables against a pre-job baseline — the list and the comparison exist.

**Why it ranks first:** it is the only survivor that closes gap 1
(in-worktree damage), and it is genuinely default-deny in the *effects*
direction — over a finite caller-declared list, holding against tools that do not
exist yet, because a new tool still has to write to a filesystem that gets
discarded. It does not depend on any permission-system behaviour at all.

**Downsides:** the result becomes a patch to apply, which changes the output
contract and can conflict. Jobs needing the real tree's untracked state (built
`node_modules`, a running dev server) silently do nothing useful. Covers
filesystem only — not network, not credential use.

### 2. Per-step grants — `--allow` widens the supervisor, never the child

**Axis:** invert · **Confidence:** High · **Complexity:** S

Today `--allow X` widens the child's ceiling for the entire job. Invert it: the
grant attaches to a named supervisor-run step, so the child holds no elevated
capability during its own turn.

**Basis — direct:** the supervisor *already* runs a shell command itself and
records its exit code (`bg-agent.sh:1025`, `verify.cmd` → `verify.rc`). Same
flag, same parser, different consumer; `ceiling_grant` simply stops being called.

**Why it ranks second:** highest ratio of bound-gained to code-changed on the
list, and it closes gap 4 — the prompt-injection window where a granted
capability is live while the model reads untrusted repo content. Grants are used
for verify-shaped work today, which already runs supervisor-side, so little is
lost.

**Downsides:** none identified for current usage — which is itself worth
double-checking before building.

### 3. Sensitive-root tripwire — run the existing baseline check outside the worktree

**Axis:** contain · **Confidence:** High · **Complexity:** S

After the child exits, run a second `find <root> -newer $MARKER` over a fixed
list of roots outside the worktree (`~/.ssh`, `~/.claude`, shell rc files,
`~/Library/LaunchAgents`, `~/.gitconfig`, `~/.config/gh`). Report as
`touched_outside[]`; never a new exit code.

**Basis — direct:** `changed_since_baseline()` (`bg-agent.sh:298`) already does
exactly this shape inside the worktree, with the baseline marker already written.

**Why it ranks here:** it is the only cheap idea that catches an effect
*nobody enumerated*, which is the one thing a tool-gate cannot do by
construction. It also distinguishes gap 3 — a bound that held from a job that
never tried — by looking at effects rather than at the denials array.

**Downsides:** detection, not prevention — the write already happened. False
positives are real and need pruning: `~/.claude` churns constantly from the
operator's own concurrent session. Misses mtime-preserving writes and all reads.

### 4. Lifetime bound — nothing the job started may outlive it

**Axis:** invert · **Confidence:** Med · **Complexity:** S

Own the child's process group, kill the group at a deadline, and sweep anything
registered to run later at teardown.

**Basis — direct:** `reap_child` in `ceilings.sh` already does TERM → poll →
KILL; this generalises it to the group and adds a deadline.

**Why it survives the correction:** `Cron*` and `ScheduleWakeup` are now
default-denied anyway, so this is no longer the primary defence — but it closes
the persistence class *by construction* rather than by name, so a scheduling tool
added next year is covered for free. Cheap enough to be worth it on that basis
alone.

**Downsides:** does nothing about what happens *during* the window. Long jobs
just need a bigger deadline.

### 5. Attestation diff — the child's story against the supervisor's measurement

**Axis:** contain · **Confidence:** Med · **Complexity:** S

Have the contract require the child to end with a machine-readable list of paths
it believes it wrote; the supervisor diffs that against `changed_files`.

**Why it survives:** the only idea that catches the model being *misleading*
rather than merely doing something, and it directly attacks the plugin's
recurring "measured, not claimed" problem.

**Ship asymmetrically:** *claimed-but-absent* blocks `done` (fabricated
completion). *Present-but-unclaimed* is informational only — models routinely
under-report incidental writes, so blocking on it would fail most honest jobs.

**Downsides, stated plainly:** this is a **competence check, not an adversary
check**. A child that wants to hide something writes an honest-looking block.
It will be over-trusted unless that limit is documented at the same volume as
the feature.

---

## Rejected

| Idea | Reason |
| --- | --- |
| Lima VM per job | Premise void — cost (VM daemon, in-guest auth, seconds of latency) was justified by "no outer wall"; there is one |
| Dedicated `_spawnbg` UID | Same; needs sudo + NOPASSWD, and a separate `$HOME` for `~/.claude` state |
| `pf` egress rule by UID | Depends on the UID idea; blind to server-side fetches anyway |
| Run the job on a remote machine | Breaks the legitimate case — the gateway is on `127.0.0.1:4000`; reaching it remotely is a bigger hole than the one closed |
| Hand-rolled `sandbox-exec` profile | **Superseded, not rejected** — Anthropic ships `@anthropic-ai/sandbox-runtime`, which wraps the *whole* Claude Code process in Seatbelt/bubblewrap with writes and network denied by default. Use the vendor wrapper rather than authoring SBPL. See "Prior art" below |
| Restricted `PATH` | Ineffective — absolute paths bypass it. The `ulimit` half (process count, file size, CPU) is real and folded into idea 4 |
| APFS `tmutil localsnapshot` | Forensics, not rollback; thinned within ~24h; duplicates idea 1 more cheaply |
| Gateway request budget per job | Needs gateway-side work that does not exist, and the agent could not confirm the gateway logs per-request client-role lines |
| Wildcard `deny: ["*"]` | Measured dead earlier this session — deny beats allow, so it blocks explicitly-allowed tools too |
| Binary tool enumeration | Measured dead — structural extraction yields ~103 candidates, mostly Mermaid grammar tokens |
| Proposer/executor inversion | Strong idea, but largely redundant now: the tool-gate already prevents the child holding Bash. Idea 2 captures the valuable part at a fraction of the cost |
| Scripted pipeline (no agent loop) | Makes bg-agent materially less capable to solve a problem the tool-gate already solves |
| Generalise the doors per capability shape | Multiplier on other ideas, not a bound itself; real cost is deciding the shapes |
| Process-tree `ps` sampling | A 5s poll misses essentially every short command; risks reading an empty set as "nothing ran" |
| PATH shim logging `argv` | Bypassed by absolute paths, builtins, and `python -c`; honesty instrument only |
| Off-contract quarantine | Folded into idea 1 — a discarded clone makes quarantine unnecessary |

## Prior art — how the field actually does this

**Every fully-autonomous product moved the boundary to the OS or a disposable
VM. None of them enumerate tools.**

- **Anthropic's own guidance is explicit:** "Always run
  `--dangerously-skip-permissions` sessions inside a container, a VM, or the
  sandbox runtime, so that file tools, MCP servers, and hooks are also inside the
  boundary." There is no documented safe *flag* — the documented counterpart is
  an isolation boundary around the process.
- **`@anthropic-ai/sandbox-runtime`** (`npx @anthropic-ai/sandbox-runtime claude`)
  — the whole process in Seatbelt (macOS) / bubblewrap (Linux). Writes denied
  everywhere, network denied everywhere, reads allowed by default. `.bashrc`,
  `.gitconfig` and `.git/hooks/` are *always* write-blocked even inside an
  allowed path, and no `allowWrite` entry lifts that. Fail-closed on an explicit
  `--settings` path. Research preview. **This matches `ceiling_selectable:false`
  exactly** — the bound is fixed by which command line ran. Their own caveat:
  without a valid settings file it starts anyway with minimal built-ins, so "don't
  take a clean start as proof your settings loaded."
- **Claude Code's built-in Bash sandbox constrains only Bash.** Anthropic states
  it is "not sufficient for fully unattended runs." File tools, MCP servers and
  hooks run directly on the host — so an OS box and the tool-gate are
  complementary, not alternatives.
- **OpenAI Codex CLI** is the cleanest design in the field: three *capability
  levels* (`read-only` / `workspace-write` / `danger-full-access`) compiled to OS
  primitives, composed orthogonally with an approval policy, and chosen by the
  launch rather than asserted by the agent. Network off by default.
- **Devin** and **Google Jules** use a fresh disposable VM per task. **Aider** has
  no sandbox and asks the user — the one answer unattended mode cannot use.
- **`sandbox-exec` is still the answer on macOS in 2026** despite years of
  deprecation. Both Anthropic and OpenAI depend on it; there is no published
  replacement for per-process confinement of a CLI outside App Sandbox.
- **Pattern-matching command text is a losing game.** Claude Code's own changelog
  records three permission-bypass fixes that were all string-filter defeats —
  shell line continuation (v2.1.6), wildcard rules vs compound commands (v2.1.7),
  heredoc delimiter smuggling (v2.1.38). The OS boundary is the one that held.
- **`credentials.mask`** is directly transferable to this plugin's "no credential
  in argv/stdout/stderr/persisted files" rule: the job holds a sentinel and a
  proxy swaps the real secret in only on egress — enforcement instead of
  discipline.
- **Don't build on `excludedCommands`** — several open issues report it doesn't
  behave as documented.

*Sourcing caveat carried from the scout: two CVE numbers (CVE-2026-39861,
CVE-2026-25725) came from secondary blogs, not an NVD or Anthropic advisory, and
are unconfirmed. The Cursor/Codex/Antigravity escape research and the arXiv
pre-action-authorization paper were found by search; the paper was not read.*

## Gaps in this run — disclosed

- **One of five agents returned nothing** — the upstream-ask frame idled empty.
  The prior-art scout arrived late and its findings are incorporated above and
  below.
- **Reads are uncovered by every surviving idea.** Not an oversight; no mechanism
  considered addresses them. It is the honest open hole.
- **Fleet was reduced** (4 frames + 1 scout, not ~13) because grounding was
  measured live this session and a monthly spend limit had been hit.
- Written as markdown rather than the skill's default HTML, to keep spend down on
  a document whose value is the correction at the top.
