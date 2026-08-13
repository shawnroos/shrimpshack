---
title: Caller-Granted Sandbox for Background Jobs - Plan
type: feat
date: 2026-08-12
topic: spawn-caller-granted-sandbox
artifact_contract: ce-unified-plan/v1
artifact_readiness: requirements-only
product_contract_source: ce-brainstorm
execution: code
---

# Caller-Granted Sandbox for Background Jobs - Plan

## Goal Capsule

- **Objective:** Make the background-job sandbox actually bound every file-touching tool to the worktree, and give the calling agent a way to grant a specific job access beyond it.
- **Product authority:** Shawn. The threat model, the absence of a cap on grants, and the survival of the deny floor under grants are his calls and are settled.
- **Open blockers:** Three, all in Outstanding Questions. What a path-scoped `Grep` rule permits for a bare no-path call, what a path-scoped `Glob` rule scopes by, and whether the deny floor can be lifted for one named path at all. None has been measured against the real CLI, and each one changes a requirement that is currently written as though the answer were known.

---

## Product Contract

### Summary

Background jobs get a sandbox that bounds every file-touching tool to the worktree — searches included, not just writes. The calling agent can then grant one job access beyond that bound, for reads and for writes, with no limit on where a grant may point. Grants are declared in the job's contract rather than passed at the call, and every job reports back the exact ceiling it ran under.

### Problem Frame

The repo-bounded ceiling is the permission file handed to `/spawn:bg-agent` — the one spawn surface that runs with nobody watching. It scopes `Read`, `Write` and `Edit` to the worktree. It allows `Glob` and `Grep` as bare tool names with no path scope at all.

`Grep` returns matching content, not just a list of paths. Given an absolute path argument it reads text out of any file on the machine, while `Read` — the tool that looks like the reading tool — is properly confined. So the ceiling built for the unattended case has the widest read surface of the two ceilings.

Two shipped descriptions of that ceiling read as though the bound already covers reads. `plugins/spawn/lib/bg-repo.sh:34` says the model "reads whatever the worktree contains". `plugins/spawn/skills/spawn/SKILL.md:127-128` says the job "runs inside the current worktree" and that work needing to reach outside it is not a background job. Neither is true of `Glob` or `Grep`. A third site, `plugins/spawn/commands/bg-agent.md:53`, is precise — it says *writes* are scoped — so the tree is inconsistent rather than uniformly wrong.

This is the plugin's recurring defect: a check narrower in reality than the invariant it claims to hold. It has already appeared twice, in the duplicate-scan that closes exact copy-paste but not the duplication class, and in the gateway whose empty auth list made a green round-trip prove nothing.

Separately, the ceiling has no way for a caller to open it. A job that needs to read a sibling package fails, and the only override is a machine-wide environment variable a human sets by hand.

### Key Decisions

- KD1. **The ceiling is a guardrail, not a security boundary.** It stops an unsupervised job wandering; it is not sized against an adversarial or prompt-injected model. Governs R5.
- KD2. **The default bounds every file-touching tool, not just the write-bearing ones.** Governs R1, R2.
- KD3. **The calling agent grants access beyond the default, per job.** This reverses the no-flag policy argued in `plugins/spawn/lib/ceilings.sh:12-14`, which refuses a `--ceiling` flag on the grounds that a flag would be self-declared. That argument was about a *child* asserting its own ceiling, which is self-declaration; a *caller* granting its child access is a different act, and under KD1 it is acceptable. The justification is that the caller is accountable for the job it dispatched — not that the grant is a subset of the caller's own reach. Nothing checks it against the caller's permissions, and R5 permits any path on the machine. Governs R3, R4, R7, R14.
- KD4. **Grants live in the job contract, not in the call.** The contract already carries the job's task, its done-condition, and its deliverables, and already validates that a deliverable cannot name an arbitrary path on the box. A grant is the same kind of fact and belongs beside them. Governs R3, R12.
- KD5. **No cap on where a grant may point.** Rejected: an operator-set root, and an enumerated floor of known-bad paths. The enumerated option was rejected because an enumeration of forbidden paths is default-allow and never closes the class — the next secret-bearing path nobody listed stays grantable. Governs R5.
- KD6. **Visibility replaces the enforcement that a cap would have provided.** Two controls survive the absence of a cap: the deny floor (KD7), which blocks, and visibility, which does not block but makes a grant reviewable after the fact. Visibility is the one this decision adds. Governs R11, R12.
- KD7. **The deny floor survives every grant; a second explicit opt-in lifts it.** "No cap" bounds *where* a grant may point, not *what kind* of file it may reach. The floor is a fixed enumerated set — version-control internals, hooks, and agent configuration — chosen because those paths run later, without anyone present. It does not close the class, and no reader should treat it as complete: shell profiles, scheduled jobs, and package manifests are equally execution-bearing and are not on it. This is the same enumerated default-allow shape KD5 rejects for grants. It is accepted here only because KD1 sizes the ceiling as a guardrail. Governs R9, R10.
- KD8. **The ceiling stays unselectable.** `ceiling_selectable` remains `false`. A grant widens repo-bounded; it never lets a caller pick a different ceiling. Governs R7.

### Requirements

**The default sandbox**

- R1. Every file-touching tool a background job can call is bounded to the job's worktree by default. No tool appears in the ceiling's allow list as a bare name without a path scope.
- R2. A job whose contract declares no grant runs under exactly the bound in R1 and nothing wider.

**Caller grants**

- R3. A job's contract carries an optional grant declaration naming paths the job may read, and paths it may write, beyond its worktree.
- R4. A grant is authored by the calling agent when the job is dispatched and is fixed for the life of the job. The running job cannot request, extend, or alter its own grant.
- R5. A grant may name any path on the machine. Nothing refuses a grant on the grounds of where it points.
- R6. A grant widens the job's bound and never narrows it. A job always retains the R1 bound in addition to whatever it was granted.
- R7. A grant may only add path scopes to tools the ceiling already allows. It cannot name a tool, name a ceiling, or set a permission mode.
- R8. A grant that cannot be parsed, or that names a path in a form the permission system would not match, fails the job at dispatch with a usage error. A job never launches under a bound narrower than the one its contract asked for.

**The deny floor**

- R9. Version-control internals, hooks, and agent configuration stay unwritable under every grant, at every path on the machine, except where R10 lifts the floor.
- R10. A separate, explicitly named opt-in lifts the floor. Granting write access to a path does not lift the floor for that path. Whether the lift can be scoped to one named path, rather than only to a whole category machine-wide, is unresolved — see Outstanding Questions.

**Reporting what ran**

- R11. A job's result carries the allow and deny lists it actually ran under, verbatim rather than summarized.
- R12. A job's grant declaration and any floor-lift are recorded in the job record before the job runs, so what was asked for can be compared against what R11 reports was given.

**Truth in the docs**

- R13. Every description of this ceiling in the plugin — settings-file comment, shell comments, skill text, command text — states the bound the file actually carries.
- R14. Every statement of the no-flag policy is rewritten to describe the grant channel and why it is not self-declaration. This covers `plugins/spawn/lib/ceilings.sh:12-14`, the policy sentence at `plugins/spawn/skills/spawn/SKILL.md:127-128` that says work needing to reach outside the worktree is not a background job, and the echoes in the ceiling's self-description and usage remedy. None is left standing to contradict the new behavior.

### Key Flows

- F1. Ungranted job
  - **Trigger:** A calling agent dispatches a background job whose contract declares no grant.
  - **Steps:** The ceiling renders with worktree scope on every file-touching tool. The job runs. Any call outside the worktree is refused and recorded.
  - **Outcome:** The job's result carries the rendered allow and deny lists, showing the plain worktree bound.
  - **Covers R1, R2, R11.**

- F2. Granted job
  - **Trigger:** A calling agent dispatches a job whose contract grants read and write access to a sibling repository.
  - **Steps:** The grant is validated and recorded. The ceiling renders with the worktree scope plus the granted paths. The job runs and can read and write inside the sibling repo, but is refused *writes to* that repo's version-control internals and agent configuration. Reads of those paths succeed — the floor is write-bearing only.
  - **Outcome:** The result carries the worktree rules, the granted rules, and the deny floor. The floor's refusals themselves leave no trace in the result; only their absence of effect shows.
  - **Covers R3, R5, R6, R9, R11, R12.**

- F3. Rejected grant
  - **Trigger:** A calling agent dispatches a job whose grant is malformed or written in a path form the permission system would not match.
  - **Steps:** Validation fails at dispatch. No child is launched.
  - **Outcome:** A usage error. Nothing runs under a partial or silently narrowed bound.
  - **Covers R8.**

### Acceptance Examples

- AE1. **Covers R1.** Given a job with no grant, when it calls the search tool with an absolute path outside its worktree, then the call is refused and appears in the result's refusal record.
- AE2. **Covers R1.** Given a job with no grant, when it calls the search tool with no path argument at all, then the call succeeds against the worktree. *This example is currently unproven — see Outstanding Questions.*
- AE3. **Covers R6.** Given a job granted read access to one sibling path, when it reads a file inside its own worktree, then the read succeeds.
- AE4. **Covers R9.** Given a job granted write access to a sibling repository, when it writes that repository's version-control hook directory, then the write is refused.
- AE5. **Covers R10.** Given a job granted write access to a sibling repository and no floor-lift, when it writes that repository's agent-configuration file, then the write is refused. Given the same job with an explicit floor-lift, the write succeeds. *Written for a per-path lift, which is unproven — see Outstanding Questions.*
- AE6. **Covers R8.** Given a job whose grant names a path in a form the permission system would not match, when the job is dispatched, then dispatch fails with a usage error and no child process starts.
- AE7. **Covers R11.** Given any completed job, when its result is read, then the allow and deny lists it ran under are present in full.

### Success Criteria

- Each new bound is proved by a test that fails when the bound is removed. Writing the test, reverting the settings change, and watching it go red is the bar — a test that passes both before and after the change proves nothing.
- Every claim any plugin file makes about what a background job can reach can be checked against the ceiling file and found true.
- A reader of a finished job's result can tell what that job was allowed to touch without opening any other file.

### Scope Boundaries

- The operator ceiling is unchanged. `plugins/spawn/permissions/operator.settings.json` carries no allow list at all by design — the operator is present and accountable, so their own settings govern. It is intentionally wider, not the same defect.
- No cap, root, or allowlist governs where grants may point. Both were weighed and rejected (KD5).
- No `--ceiling` flag, and no way for a job to select a ceiling (KD8).
- No network-capable tool is added. The plugin has none today.

### Dependencies / Assumptions

- The bound is enforced by the harness, not by this plugin. Every rule here is a refusal by the permission system, never a tool removal.
- A background job has no shell and no network tool, so anything it reads leaves only through a file it writes into a granted path or through its own returned text. This is what makes KD1's guardrail framing hold; if a network tool or shell is ever added to this ceiling, the threat model must be re-decided first.
- Deny beats allow in the permission system. R9 depends on this and should be confirmed rather than assumed.
- A refusal by a deny rule leaves no entry in the job result's refusal record, while a call that is simply not allowed does. Every assertion about the deny floor is therefore verified by effect against a baseline, not by reading the result. AE4 and AE5 depend on this.
- The ceiling renderer today performs a single text substitution and validates only the worktree path's characters and that its output is non-empty. It does no JSON parsing and no structural validation. Composing rules from a grant is new behavior in a path that has never had to be correct about JSON.

### Outstanding Questions

**Resolve Before Planning**

- What does a path-scoped search rule actually permit? Specifically: under a `Grep` rule scoped to the worktree, does a bare no-path `Grep` call still match, or does it fall outside the allow and get refused? This must be measured against the real CLI. Reasoning about the matcher's semantics from first principles is what produced the original defect. AE2 assumes it matches. If it does not, R1 stands and bare search calls are refused for background jobs — in which case the job's own instructions must tell it to always pass a path, and AE2 is rewritten to assert the refusal. That fallback is the decision; it does not need re-deciding.
- Does a path-scoped `Glob` rule scope by the search root or by the paths it returns? The two behave differently for a job searching from a granted directory.
- Can the deny floor be lifted for one named path at all? The floor is a set of machine-wide deny rules and the permission syntax has no negation, so the only expressible lift may be removing a whole rule — which lifts that category everywhere, not for one path. R10 and AE5 are written for per-path semantics and must be rewritten if only per-category is expressible. Measure this the same way as the `Grep` question.

**Deferred to Planning**

- Where the grant declaration sits within the contract's existing shape.
- How grant rules are composed into the rendered ceiling, given the renderer currently does no parsing.
- Whether grants also appear in the surface's self-description output.

### Sources / Research

Verified against the code on 2026-08-12.

| What | Where |
|---|---|
| The unscoped allow list — `Glob` and `Grep` bare, Read/Write/Edit worktree-scoped | `plugins/spawn/permissions/repo-bounded.settings.json:5-11` |
| The 14 deny rules, all Write/Edit, all machine-wide `//**` | `plugins/spawn/permissions/repo-bounded.settings.json:13-26` |
| `Bash` absent from allow and deny alike | `plugins/spawn/permissions/repo-bounded.settings.json:5-27` |
| The no-flag policy this work reverses | `plugins/spawn/lib/ceilings.sh:12-14` |
| Ceiling render — one text substitution, character check on the worktree path, no JSON parsing | `plugins/spawn/lib/ceilings.sh:136-151` |
| Deny-rule refusals leave no entry in the result; not-allowed refusals do | `plugins/spawn/permissions/repo-bounded.settings.json:2` |
| Child argv — three ceiling flags and nothing else; no tool list is ever passed | `plugins/spawn/lib/ceilings.sh:161-163`, `:540-541`, `plugins/spawn/lib/bg-agent.sh:877-878` |
| Environment override of which settings file the ceiling uses | `plugins/spawn/lib/ceilings.sh:106` |
| Deliverable validation that already refuses absolute paths and `..` | `plugins/spawn/lib/bg-agent.sh:219-227` |
| Overstated read bound, shipped | `plugins/spawn/lib/bg-repo.sh:34` |
| Overstated read bound, shipped | `plugins/spawn/skills/spawn/SKILL.md:127-128` |
| Precise phrasing to model the rest on | `plugins/spawn/commands/bg-agent.md:53` |
| Live ceiling tests, opt-in, with the control-arm pattern a new bound needs | `plugins/spawn/tests/unit/ceilings.bats:182-184`, `:518-588` |
| No assertion anywhere mentions the search tools | `plugins/spawn/tests/unit/ceilings.bats` |
| The operator ceiling has no allow list by design | `plugins/spawn/permissions/operator.settings.json:3-6` |
| The same defect class, twice before | `docs/residual-review-findings/spawn-quality-audit.md:159-196`, `docs/residual-review-findings/feature-gateway-setup.md:50-67` |
