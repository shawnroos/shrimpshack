---
title: "An answer recorded under two keys answers for scopes nobody asked about"
date: 2026-09-18
module: plugins/work
problem_type: logic_error
component: data_model
severity: high
category: logic-errors
symptoms:
  - "the second team's issue in a project made its worktree in the first team's repository, with no question asked"
  - "the run printed 'the only repository recorded for this scope' — truthfully, about the wrong scope"
  - "recording the second repository did not help: the scope then held two, so every issue in it asked again, for ever"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - testing_framework
tags: [scope-records, cache-keys, linear, worktrees, silent-default]
---

# An answer recorded under two keys answers for scopes nobody asked about

## Problem

`/work:start` asks which repository an issue's worktree is made from, and records the answer so it never asks twice. The answer was written under two keys, the project and the team, and read project first. A Linear project can span several teams, each with its own repository, so the first answer silently decided every later team's issue.

## Symptoms

- A WEB issue answered with `web-app` made the next Android issue's worktree in `web-app`, no question asked.
- The stderr line said "the only repository recorded for this scope", which was true of the record and wrong about the work.
- Recording the Android repository too did not fix it: the project key then held two, and since recording de-duplicates rather than replaces, every issue in that project asked again for ever.

## What Didn't Work

- **Making the scope hold a list.** It already did. The list was never the limit; the key was.
- **Reading the team key first, project second.** This was the first fix, and review found it broken by the very records it was meant to respect. The old rule wrote both keys, so a team record almost always exists: the project fallback fires for almost nothing, and a team that worked in two projects on different repositories now holds two entries under its own key and asks for ever.

## Solution

Key the answer by the pair that actually decides it — the project **and** the team — and keep the plain keys as read-only fallbacks:

| Key | What it is for |
|---|---|
| `project-<pid>.team-<tid>` | what the answer is recorded under now: one repository per project-and-team pair |
| `team-<tid>` | an answer the old rule wrote, or an issue with no project |
| `project-<pid>` | an answer the old rule wrote for a project |

Read pair, then team, then project; the first key holding anything answers. Nothing is migrated: every old record still answers, and a scope stuck asking is settled by answering once, because the answer lands in a key that holds exactly one.

The separator has to be a character an id cannot contain, or a crafted id could spell a plain key as a pair. Linear ids are UUIDs, so the id check refuses a dot and says so.

## Why This Works

The question "which repository does this work land in" is answered by a project and a team together. Recording it against either one alone claims an answer for scopes nobody was asked about: against the project, every other team inherits it; against the team, every other project does.

## Prevention

- When a recorded answer is keyed, ask which combination of things actually determines it. A key narrower than the question answers for cases nobody asked about; a key wider asks again for cases already settled.
- Writing one answer under several keys is the same defect wearing a different hat: each extra key is a claim about a scope the person never spoke about.
- A change that reads a record differently must be tested against the records the **old** rule wrote, not only against ones the new code creates. The first fix here passed a suite built entirely from new-rule records.
- Test the state, not the filename: two tests asserted "nothing was recorded" by naming the files that existed when they were written, and missed the new key entirely. Assert that the store holds no record at all.
