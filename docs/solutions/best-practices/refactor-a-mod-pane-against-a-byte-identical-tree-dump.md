---
title: "Refactor a mod pane against a byte-identical drawn-tree dump, and know what the test kit cannot see"
date: 2026-10-13
module: plugins/peek
problem_type: best_practice
component: testing_framework
severity: medium
category: best-practices
applies_when:
  - "restructuring a Claude Code mod's ui.render code without changing what it draws"
  - "moving code out of one large render closure into imported modules"
tags: [peek, refactor, characterization, tree-dump, claude-code-testing, validator, behavior-preservation]
---

# Refactor a mod pane against a byte-identical drawn-tree dump, and know what the test kit cannot see

## Context

The peek structure refactor took `register.tsx` from 4,099 lines to about 520, split into screens, widgets, actions, layouts and ports. The rule was "behavior must not change". Ordinary pane tests check chosen facts, such as a key opening a file. They do not catch a moved screen that draws one extra row, a different key, or a reordered menu.

## Guidance

1. **Dump the whole drawn tree for many states and compare bytes.** A temporary test mounted the Pane for about 216 states:
   - every view kind
   - Recent, Gallery and Groups, folded and expanded
   - the group page
   - terminal and desktop, at two widths, with the menu closed and open

   It normalized press handles and random ids, then wrote one text file. Two runs on the unchanged code must be byte-identical before the baseline is trusted. After every refactor commit, `cmp` the new dump with the baseline. Keep the dump out of git (about 3 MB) and save the baseline beside the run notes.
2. **Compare the validator output too.** Run `claude plugin validate .` and strip the `(via …)` attributions. The hooks, state reads and writes, surface modules, env reads and engine-call lines must stay identical. This catches a moved module that reads an atom it did not read before, which the drawn tree cannot show.
3. **Add a lasting characterization test before each risky move, and see it pass on the old code first.** Examples from this refactor:
   - every screen's footer keys and ⌃k rows, with each key pressed once
   - selection and scroll after j/k and block jumps
   - every message a client module posts
   - failure mapping per transport
   - ref identity tables

   A characterization test never seen green on the old code cannot clear the refactor.
4. **Mutation-check the new pins.** Break the line a pin protects, confirm the pin fails, then restore it. Several pins passed on their first run and would have passed whatever the code did, until a mutation showed it.

## What the `claude-code/testing` kit cannot show

- **Scroll and focus calls:** the plugin's own `$.ui.scroll` and `$.ui.focus` calls are not surfaced. Pin them through effects: the selected row's keys and the reader's position line.
- **Races between a draw and a handler:** the kit redraws after every state write, before the next read or post, and the plugin's `ui.message` hook runs before any test hook. So a click queued against a stale layout cannot be staged end to end. Move the guarding decision into a pure function and test that instead. This race is how a dropped mode/openGroup guard nearly shipped. An independent cross-model reviewer and the correctness reviewer each found it from the code, not from tests.
- **Parallel runs:** several `claude plugin test .` runs at once made sequentially green code fail dozens of tests. Run the suite one run at a time.

## Applicability

Use this for any behavior-preserving change to a mod's render path or message handling. For a feature change, use ordinary tests instead, because the dump is supposed to change.
