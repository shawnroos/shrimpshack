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
last_updated: 2026-11-02
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

- **Never read the arguments after a runtime-built command word to decide what it runs.** This is the rule that survived; the three failed rounds in the table above are three ways of breaking it. PR #162 narrowed the guard successfully by asking only *position* questions instead: is this text shell that a shell will actually run; is this token the command word, a plain argument, or a send target; and can the command word be resolved from a plain-literal assignment in the same text. `$H pane ${V/x/x} ${P/x/x} hi` — the bypass that killed round three — still denies, because `H=herdr` resolves to a host program and a host program reached through a variable is denied outright, with its arguments never consulted.
- **Resolving `$NAME` from a literal assignment is safe only when judged on the assignment's own position, never on the gap between assignment and use.** The person allowed literal-set variables on 2026-11-02, partly reversing the earlier "deny whatever follows" rule. The first implementation took the last assignment lexically preceding the use, and two independent reviewers each found the same P0: a dead assignment the shell never executes still named the program, so `H=herdr; false && H=cat; $H pane send-text <PM pane> hi` was allowed and typed into the pane. `H=cat; true && H=herdr; $H …` is the same defect mirrored, which is why "take the last one" is wrong in both directions. The rule that holds: a name resolves only when **every** assignment to it stands before the first control word, group or pipeline in the text, and the resolved literal is compared casefolded, because this filesystem finds `heRdr` on `PATH`.
- **Invert the default on every "is this text dangerous" test, then measure what the inversion costs.** A heredoc body is treated as non-shell only when its operator line *proves* a non-shell reader — every program at a command position on that line is a named non-shell program. Testing only the line's first word missed `cat <<'EOF' | ksh` and `| $S`; the first conservative fix (any `$` anywhere on the line means shell) was safe but re-denied 39 real commands. The corpus number is what caught both: 120 commands cleared, then 81 after the blunt tightening, then 119 after making the test precise. Also widen the shell-name list past the four whose `-c` grammar the guard models — a body can be read by any shell on the box.
- **The accepted cost is now narrower but still real.** `PY="$(for c in python3 python py; …)"; "$PY" …` stays denied, which is `ce-code-review`'s own launcher, so that skill cannot run inside a programme worker.
- **Keep the whole runtime character set.** Removing `;` and `~` from it lost two protections. When `shlex` hits an unbalanced quote, the guard falls back to splitting on whitespace, so `true;herdr …` becomes one token that only the `;` marks. And `~r` runs a zsh named directory. Exempt only what caused the false positive: tokens made entirely of shell operators (the `)` and `>` that `shlex` splits out of quoted JavaScript).
- **Decide command position in one linear pass** (`_command_positions` in `plugins/auto/lib/send_guard.py`):
  1. Read joined operator tokens (`);`, `;>`, `<(`) one character at a time, with a parenthesis stack. A `$(` substitution returns to the position its enclosing word left, so `X=$(…) $H` is still a command word.
  2. Keep the position through assignments, redirections, and a precommand's flags.
  3. Skip a precommand option's value from a small table (`env -u NAME`, `sudo -u USER`, `xargs -I {}`). An unknown option keeps the position, so it fails closed.
- **Never let the check raise or slow down on adversarial input.** A recursive version raised `RecursionError` after about 600 `a=1` prefixes. A per-token backward walk took 65 s for 20,000 prefixes against a 10 s hook limit. Both let the command through. Pin both with tests: one deny check for a thousand prefixes, and one timed deny check for twenty thousand.
- **Prove the narrowing with a differential, not another review round.** Collect every probe command any reviewer wrote, judge each with the pre-branch guard and with the new one, and list every command the old guard denied and the new one allows. Each line must be an intended fix, a form that cannot run, or a gap the PR names. The differential found two regressions that three review passes had missed: the joined `);` token and `X=$(…) $H`. In PR #162 the same technique — importing both module versions side by side and printing a `fixed / base / regression?` table per case — separated four real regressions from one pre-existing hole in a single run, and it is the only reason the pre-existing ones were not fixed inside an unrelated PR.
- **Replay the real denials as the acceptance number, and do not trust a stored command's text.** The journal of a live programme held 282 distinct denied commands; replaying them through each candidate guard turned "this feels better" into 119 of 129. Two traps in that measurement: a journal row is truncated at 2000 characters, which leaves quotes unbalanced, so the lexer takes its `split()` fallback and shreds the row into words — one apparent false positive was purely that artifact. And `bash tests/run.sh 2>&1 | tail -30` backgrounded returns the **pipeline's** exit status, which is `tail`'s, so it reported exit 0 with an empty log; re-run unpiped to a file to get the real `7735 passed, 3 failed`.
- **Clear every terminal-host variable in a test harness, not just the host you are testing.** `plugins/auto/tests/integration/programme-hooks.test.sh` unset only `HERDR_*`. Run from a Rex pane, the leftover `REX_*` put the session in a host the suite never set up and failed 25 cases that read exactly like real regressions. The unit suite already cleared `HERDR|REX|GHOSTTY|AUTO_TEST`; the integration suite had drifted.

## Code the guard cannot read as a command (issues #184 and #185)

A command-text guard stops at the program name. When the program is a shell or an interpreter, the code it runs decides what happens, and that code can sit in a heredoc, an inline `-c` operand, or a file the session wrote. The guard now reads it, for a session that drives no programme.

**What is read, and by which rule** (`plugins/auto/lib/send_guard_runners.py`, `send_guard_inline.py`):

| Code | Rule |
|---|---|
| A path the same command writes and then runs | Judged like a typed command; content the guard cannot read is refused |
| A script file the session wrote or changed | Judged like a typed command. "Session wrote it" means `max(mtime, ctime)` is at or after the session's earliest registry row, and the file is not a tracked file equal to the default branch |
| Inline Python (`-c`, heredoc, here-string) | Allowed only inside a positive list of modules and attributes that cannot open a socket, load code by string or reach a private name. A process it starts needs a command line written out as literal strings, which is then judged like a typed command |
| Inline code in any other language | Refused |
| `PYTHON*`, `BASH_ENV`, `ENV`, `ZDOTDIR`, `LD_*`, `DYLD_*` set in the text of a command that runs a shell or interpreter; a `PATH` with a relative component | Refused |
| A script that does not exist yet, a shell script piped in, `bash <(…)`, `env -S` | Refused |

**Why a positive list, and what it costs.** A refused-module list leaks: `shlex.os`, `json.codecs` and `collections._sys` hand out the modules the list was meant to keep out. The positive list allows a public attribute only when its value is not itself a module, never lets a module stand as a bare value, and refuses underscore names, frame attributes, `getattr`, `eval`, `exec`, `compile`, changes to `os.environ` and the working directory, and any `/dev/` path other than the null and random devices. Replaying 30 days of worker commands (23,752 commands) through the old and new guard, the new guard refuses 6.3% more of them as measured, 5.0% leaving out 312 runs of scripts that no longer exist on disk, and 3.7% leaving out script-file refusals as well, because the replay judges today's files against old sessions. It allows nothing the old guard denied. The largest parts are by design: a process started from a command line that is not written out as literal strings (1.0%), and a command that writes a file and runs it in the same breath (1.2%).

**Two measurements changed the design.** Running the existing command rule over every script file a worker ran would have refused 90% of them, because real scripts hold `$VAR` command words. Reading only files the session wrote cost under 1%. A first draft that also refused every file write and `pathlib` refused 15% of all commands. A file write is not process creation, so the rule moved to what a written file does next: it is read when it runs, a module file that shadows an import is refused, and a device path is refused.

**Residuals that stay open** (each is a follow-up issue): code changed after the check (a background job swapping a file, or `git update-ref` making a script look identical to the default branch); `python3 -m <module>`; a script that imports or sources another file; interpreters outside the name list; programs that start processes from their own arguments (`awk`, `find -exec`, `xargs`, `git -c`); startup files in site directories; and operands the guard cannot resolve (`bash "$f"`). Only a runtime fix closes the class: the host binaries and the herdr socket refuse any session that is not the driver.

## Applicability

This applies to any guard that reads command text where a wrong "allow" fails silently, and especially to one whose errors and timeouts fail open. Before narrowing such a guard, ask the person which precision they will give up. Do not start a third parse-based round (auto memory [claude]: the same pattern failed three rounds running in earlier auto and reflect guard work).

Two further cautions from PR #162, both about the work rather than the rule:

- **A fix to this guard is reviewed under the installed guard, not the fixed one.** `ce-code-review` could not run its own launcher, and that also blocked its cross-model peer, so the PR merged with local reviews only. Expect to verify out-of-process by importing both module versions, and name the missing coverage in the PR instead of discovering it at the review step.
- **Round two is where a narrowing fix gets broken.** Two independent reviewers each found the same P0 in the first commit, and five more between them: a `case … esac` block latched its pattern state and switched the whole runtime-word rule off for the rest of the text; a `<<WORD` inside a comment or quotes moved the real commands into the one text the guard reads as holding no commands; unbounded recursion on nested arithmetic raised a `RecursionError` the hook swallows into an allow; and a per-character list copy made an 80 KB argument take 31 s against a 10 s budget. None of these were in the original defect. Budget a full adversarial pass on the *fix*.
