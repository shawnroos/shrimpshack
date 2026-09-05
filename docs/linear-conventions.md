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

### Parent issue

Sections observed on parent issues, in order:

```
## What          the thing, what is built, what is not, the feature flag
## Why           motivation, and any scope that moved in or out
## Not in this PR explicit exclusions, each with its current state
## Verification  how it was checked
---
                 a pointer to the architecture or sequence issue
```

Name the feature flag in `## What` when one gates the work.

### Child issue

No fixed section list. A child carries, in whatever order reads best:

- The rule or the problem, stated first.
- Why it matters, in terms of what the user loses.
- What the change covers, and explicitly what it does not.
- A `## Source` line naming where the ticket came from — a Slack thread and its date, a call, a
  QA session, a review finding.
- Links to related issues, either inline or under a `## Relationship to <issue>` heading.

Prefer a stated rule over an enumerated list of cases. `Do not build an allowlist` is a real
instruction Shawn has given in a ticket; a rule survives cases nobody thought of.

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
