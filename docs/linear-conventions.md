# Linear conventions for Slate work

The shape a Linear project, issue, and sub-issue takes. Any agent that creates or updates
Linear on Shawn's behalf follows this document.

Most rules below are derived from issues Shawn wrote in the Web Creation team during 2026.
Where a rule could not be derived from evidence, it is listed under **Not yet settled** rather
than invented.

---

## Voice

Write for a busy human who was not in the room. Plain language, no internal identifiers, no
process narration.

- Lead with the problem and who it hurts, or with the outcome and who gains.
- Name the real caveat. Do not inflate a shim into an architecture.
- Match length to the size of the change.
- A ticket states the *why*. A pull request states the *what changed*.

---

## Titles

The title shape is the clearest signal of where an issue sits in the hierarchy.

| Level | Shape | Examples |
|---|---|---|
| Parent | A noun phrase naming the thing | `Upscale Image` · `Audio Cleanup Tools` |
| Child | A full sentence naming the problem or the outcome | `Two of the five Upscale model rules never fire` · `We cannot see how anyone actually uses Upscale` |

Rules that hold at both levels:

- Do not put the issue identifier in the title. Linear supplies it.
- Do not open with a verb phrase describing a task (`Add a button`, `Fix the cache`). State the
  condition that is wrong, or the outcome wanted.
- A topic prefix is allowed when it disambiguates: `Upscale: the card has no art`.
- A child that records a decision may be phrased as the decision:
  `Decide whether to hold Remove Logo containers open for 20 minutes (~$70/mo)`.

---

## Descriptions

**This is the template. It is Shawn's stated preference, given 2026-09-05, and it
replaces the `## What / ## Why / ## Not in this PR / ## Verification` shape that
was derived from older tickets.** Where an existing ticket still carries the old
shape, leave it alone; write new descriptions in this one.

```markdown
## Problem

Describe the problem as it affects the actor — a user, a customer, internal
staff. Convey the first and second order effects.

### For example:
- <example one>          — show the implications in the experience
- <example two>

## Solution

Describe what the solution looks like for that same actor if the problem were
resolved. **Implementation neutral.** What does the same scenario look like when
the problem does not exist?

### For example:
- <solved example one>   — show the benefit of the problem not existing
- <solved example two>

## Proposal

What we are building, without fluff or management theatre, for a non-technical
reader.

### Key Requirements
- <key point one>        — framing, decisions, perspectives shaping the work
- <key point two>

### Constraints
- <constraint one>       — technical, business, UX
- <constraint two>
```

### The template is the default, not a cage

Use it when writing a description from nothing. **A ticket that has earned its
own headings keeps them.**

`WEB-3214 — Improve AI tools analytics` is the worked example. It uses none of
the three spine headings and is a better ticket for it:

| Its heading | What the template would have called it |
|---|---|
| `## Why` | `## Problem` |
| `## The shape of this work` | `## Proposal` |
| `## Two things everyone reading these dashboards needs to know` | `## Constraints` |
| `## Worth agreeing before GA, not after` | — |

Those headings are **arguments**. A reader can act on "Two things everyone
reading these dashboards needs to know" before reading a word beneath it.
`## Constraints` is a heading people skim past. A heading that carries the point
beats a heading that carries a category.

What that ticket does that any good description does, whatever it calls its
sections:

- **Evidence with provenance.** "verified directly against Amplitude, not
  inferred from the code" — it says how it knows, so a reader can weigh it.
- **The second-order effect stated.** Not "we measure the wrong thing" but "GA
  starts with instrumentation already trusted, instead of a month spent
  debugging telemetry while the numbers finally matter."
- **The trap named before someone falls in it.** "A pre-GA baseline is staff
  behaviour, not customer behaviour. Do not carry one across the GA line."
- **An open decision left open, and dated by consequence rather than calendar.**
  "A number chosen after seeing the first week tends to be the number the first
  week produced."

### The three rules that matter

1. **Problem and Solution are about the actor, never the code.** Solution is
   written implementation-neutral: it describes the world without the problem,
   not the mechanism that removes it. The mechanism belongs in Proposal.
2. **Sections after Proposal are decided per ticket.** The three above are the
   spine; anything beyond them is a judgement call for that ticket.
3. **NEVER a diary.** The description is always the *latest* source of truth. It
   is not a log, not a progress record, and not a running commentary. Nothing
   dated accumulates in it. Working history belongs in a Linear document
   (see **Documents** below); status belongs in the issue's state.

Rule 3 is the one an automated writer will break first, because appending is
easier than rewriting. A description that grew a `### 5 Sep — update` heading has
already failed, however accurate that heading is.

### Child issues

A child may carry less than the full spine when the parent already holds the
Problem — but what it does carry uses these section names, not invented ones.
Prefer a stated rule over an enumerated list of cases: `Do not build an
allowlist` is a real instruction Shawn has given in a ticket, and a rule
survives cases nobody thought of.

A `## Source` line is worth keeping where a ticket came from somewhere nameable —
a Slack thread and its date, a call, a QA session, a review finding.

---

## Hierarchy

- **Project** — a body of work with its own milestones, spanning many issues over months.
  Example: `AI Canvas Tools`.
- **Parent issue** — one feature or one coherent capability inside a project. It holds the
  overall description and the flag, and it stays open while its children land.
- **Child issue** — one piece of that feature, or one defect found while building it. Most
  children are created *during* the work, not planned up front.

A child is created when work is discovered that is separately reviewable and separately
landable. Work that cannot be reviewed on its own stays in the parent.

---

## Labels

Labels are used sparingly. Most issues carry none. Do not add a label to describe what the
title already says.

Grouped families, applied when the grouping is meaningful:

| Family | Use |
|---|---|
| `repo/…` | the repository the work lands in, e.g. `slateteams/web-app` |
| `platform: …` | the platform affected, e.g. `platform: WCS` |
| `Requests/…` | the platform a customer request came from |

Loose labels seen in use: `Bug`, `Improvement`, `quick win`, `support`, `Hardening`,
`Track: …`, `Use Case: …`.

**`ready-for-ai`** marks a ticket an AI agent may pick up and implement. Treat it as the gate:
an agent does not start implementation on a ticket that does not carry it.

---

## Milestones

A milestone marks a shipping increment inside a project, not a date and not a theme. Example:
`Logo Removal` on the AI Canvas Tools project. Apply one only when the issue must ship as part
of that increment. Most issues carry none.

---

## Priority

Set priority on a standalone issue and on any bug. Children swept out of one review or one QA
pass may all be left at `No priority`, because their order comes from the parent.

---

---

## Documents

A Linear document is where anything that would otherwise land in a gitignored
`/docs` directory belongs. In Slate's web-app `/docs` is ignored, so a durable
document written on a branch dies with the worktree. A Linear document outlives
the branch, is linked to the work, and is readable by people without the repo.

Derived from 40 documents in the workspace, most of them Shawn's.

### Two families, and the title says which

| Scope | Attached to | Title shape | Real examples |
|---|---|---|---|
| **Issue** | `issueId` | leads with the identifier, then the kind, then what it is | `WEB-3127 diagnosis: texture leak on image swap` · `WEB-2651 — Denoise mix-slider regression report` · `MEDIA-270 Implementation Log: Folder Navigation in Media Hub` |
| **Project** | `projectId` | a noun phrase, no identifier | `Architecture Overview` · `V1 Limitations & Fast-Follow Themes` · `RFC: Brand Vocab` · `PRD: Brand Hub Auditing` |

The separator after the identifier varies in practice — a space, a colon, or an
em dash all appear. Any of the three is fine; do not "correct" an existing one.

### Kinds actually in use

Issue-scoped: `diagnosis`, `findings`, `regression report`, `Implementation Log`,
`Reference`, `Test Plan`.

Project-scoped: `RFC`, `PRD`, `Plan`, `Development Plan`, `Architecture Overview`,
`Codebase Exploration`, `Design References`.

Use one of these rather than a new word. A new kind is a decision, and the point
of a shared vocabulary is that a title tells you what you are about to read.

### Icons

Sparse — 22 of 40 documents carry none, which is the default. The one consistent
use is **`:mag:` for a findings or diagnosis document**; all four of its
appearances are that. Apply no icon otherwise. Same restraint as labels: do not
add one to say what the title already says.

### Updating rather than creating

A document the plugin created is updated in place on the next run, never
duplicated. The document id is recorded against the binding, in the same list
that bounds what the plugin may write to — a document the plugin did not create
is never modified.

## Not yet settled

These need Shawn's decision. An agent asks rather than guessing.

- When a new **project** is created, as opposed to a parent issue inside an existing project.
- When a Linear **document** is written, as opposed to a long issue description.
- Whether an agent may create a milestone, or only apply an existing one.
- Whether an agent may apply `ready-for-ai` to a ticket it wrote itself.
- Who is assigned to an issue an agent creates.
- Whether an agent may create a **project-scoped** document, or only an issue-scoped one. A project document is read by people outside the work, which is a higher bar than a diagnosis note on one ticket.
- Who owns a document an agent creates (`ownerId`), and whether it should be Shawn or the agent's own account.
- Whether documents should be filed into a resource folder (`resourceFolderId`), which nothing in the observed set uses.
