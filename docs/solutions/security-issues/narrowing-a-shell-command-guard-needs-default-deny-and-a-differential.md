---
title: "Narrowing a shell-command guard needs default-deny for runtime-built commands and a differential against the old guard"
date: 2026-10-31
category: security-issues
module: plugins/auto
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - "a PreToolUse guard reads Bash command text to stop a session reaching another session's terminal pane"
  - "a false-positive report asks to allow some commands whose program name comes from a variable or substitution"
  - "a change removes characters or rules from a deny check in plugins/auto/lib/send_guard.py"
  - "a guard check is recursive, or runs once per token over the whole command"
symptoms:
  - "each review round of a narrowed guard finds new bypasses in the narrowed rule"
  - "a command with an unbalanced quote, a joined operator such as ');', or a long prefix passes a guard that denies the plain form"
root_cause: "a rule that tries to tell from the rest of a shell command what a runtime-built command word will run is parsing shell by enumeration, and every narrowed character set or position rule opened a form the old guard denied"
resolution_type: code_fix
related_components:
  - testing_framework
tags: [send-guard, pretooluse-hook, default-deny, enumeration, shlex, fail-open, differential-testing, runtime-built-command]
---
# Narrowing a shell-command guard needs default-deny for runtime-built commands and a differential against the old guard

## Context

Issue #146 asked auto's send-guard to stop denying harmless worker commands: `agent-browser eval` with a JavaScript `=>`, the `EMAIL=$(grep … ~/.secrets …)` login, `rex session rename "$REX_SESSION"`, and `2>&1` redirects. PR #148 (pending at the time of writing) made the fix. The guard decides whether a worker's Bash command can type into the programme PM's herdr pane, Rex block or Ghostty terminal, and a hook exception or a hook timeout lets the command through.

Three ways to allow some commands whose program name is built at run time (`"$PY" x.py`) each failed review:

| Rule tried | Bypass found in review |
|---|---|
| Skip the command word's `$( … )` group, then probe one tail | a name glued to a substitution (`$(printf her)dr`), a wrapper word (`$W $H …`), a quoted `)` ending the group early |
| Scan every suffix of the tail, with Rex verb rules | a verb inside the group (`$(echo $H pane send-text) $P hi`), `rex api -s X call`, and tool flags read as Rex scope options |
| A typing-verb vocabulary plus a "verb place" rule | a runtime verb after a glued `--opt=value`, `${V%/*}` read as a file path |

## Guidance

- **Deny every runtime-built command word, whatever follows it.** The person chose this after the third round. The guard then needs no understanding of the rest of the command. The accepted cost is that `"$PY" script.py` stays denied, which fails closed.
- **Keep the whole runtime character set.** Removing `;` and `~` from it lost two protections. When `shlex` hits an unbalanced quote, the guard falls back to splitting on whitespace, so `true;herdr …` becomes one token that only the `;` marks. And `~r` runs a zsh named directory. Exempt only what caused the false positive: tokens made entirely of shell operators (the `)` and `>` that `shlex` splits out of quoted JavaScript).
- **Decide command position in one linear pass** (`_command_positions` in `plugins/auto/lib/send_guard.py`):
  1. Read joined operator tokens (`);`, `;>`, `<(`) one character at a time, with a parenthesis stack. A `$(` substitution returns to the position its enclosing word left, so `X=$(…) $H` is still a command word.
  2. Keep the position through assignments, redirections, and a precommand's flags.
  3. Skip a precommand option's value from a small table (`env -u NAME`, `sudo -u USER`, `xargs -I {}`). An unknown option keeps the position, so it fails closed.
- **Never let the check raise or slow down on adversarial input.** A recursive version raised `RecursionError` after about 600 `a=1` prefixes. A per-token backward walk took 65 s for 20,000 prefixes against a 10 s hook limit. Both let the command through. Pin both with tests: one deny check for a thousand prefixes, and one timed deny check for twenty thousand.
- **Prove the narrowing with a differential, not another review round.** Collect every probe command any reviewer wrote, judge each with the pre-branch guard and with the new one, and list every command the old guard denied and the new one allows. Each line must be an intended fix, a form that cannot run, or a gap the PR names. The differential found two regressions that three review passes had missed: the joined `);` token and `X=$(…) $H`.

## Applicability

This applies to any guard that reads command text where a wrong "allow" fails silently, and especially to one whose errors and timeouts fail open. Before narrowing such a guard, ask the person which precision they will give up. Do not start a third parse-based round (auto memory [claude]: the same pattern failed three rounds running in earlier auto and reflect guard work).
