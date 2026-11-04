# Launch command and goal binding probe (U1)

Date: 2026-11-02. Claude Code 2.1.316. Scratch dir only; the live programme was not touched.

## What the launcher actually sends (read from code)

- `start-worker` (`plugins/auto/lib/programme_sources.py`, `_h_start_worker`) passes the spinoff arguments through. It may copy the `--handoff` file and append a tail of Rulings. It never builds a prompt.
- `spinoff.sh` (`plugins/spinoff/skills/spinoff/scripts/spinoff.sh`, line 2125) sets a fixed text: "Read docs/handoff.md ... recommend the next compound-engineering step ... and wait for my direction."
- That text is written to `.spinoff-brief` and launched as `claude --session-id <id> --name <label> "$(cat .spinoff-brief)"`. It is the positional prompt of an interactive session.
- So the handoff file is never the first line of the prompt. The first line is always that fixed text. A worker cannot start with `/auto <plan>` today without a spinoff change (a new flag or a kickoff override).

## Probe 1: does a leading `/auto ...` run as a command?

- Command used: `claude -p "/auto-status" --max-turns 1 --no-session-persistence --output-format stream-json --verbose`, run in the scratch dir. `/auto-status` is a read-only command from the installed auto plugin. It stands in for `/auto <plan>`, which would start a real run.
- Observed: the first turn was a Bash call `command -v auto; ls .../.claude/auto ... | head -20`. That is what the `/auto-status` command does (look for run records). It was not a reply to the bare text. A first call with `--max-turns 2` also ended on a tool call, not a text answer.
- Evidence: scratch `out2.jsonl` in `u1-probe/`. The command body was not echoed, so this is indirect proof.
- Limits: this was headless `-p`, not the interactive positional prompt that spinoff uses. Not probed: the interactive path (would need a terminal session). The real `/auto <plan>` was not run because it would arm a pulse.
- Consequence for U3 launch mode: a leading slash command very likely runs in `-p`, but the interactive launch is unproven and spinoff sends fixed text anyway, so U3 must pick launch mode 2 (fallback) unless it also adds a spinoff kickoff override and proves it live.

## Probe 2: does a brief that tells the worker to run /auto as its first action work?

- Brief used: none sent. NOT PROBED as a runtime test. Reasoned from code instead.
- Evidence: the brief reaches the worker as plain model text (line 2146 of `spinoff.sh`), and the worker reads `docs/handoff.md` on its own. A model can call the `auto` skill or the slash command from plain text, so an instruction "your first action is to run `/auto <plan>`" can work.
- Risk found: the fixed kickoff text tells the worker to treat the handoff as "directional", to recommend a next step, and to "wait for my direction". That wording conflicts with "run /auto first", so the fallback instruction must sit in the handoff file in plain imperative words, and U3 needs to change or override the kickoff text. A worker that waits for a human will stall in an unattended pane.
- Consequence for U3 launch mode: the fallback is workable only if the kickoff text is overridden; it is not safe as a handoff-file line alone.

## Probe 3: does a bound `/goal <file>` re-read its file on each check?

- Command used: none. NOT PROBED.
- Reason: `/goal` is a feature of an interactive session. Binding one needs keys typed into a live pane or a TUI. The rules for this task forbid sending keys to any pane, and `-p` runs end after one answer, so there is no repeated check to watch.
- What the docs say (`plugins/auto/skills/auto-author-goal/SKILL.md`, "The binding model"): the model "judges the entire doc as the goal at each stop attempt". This implies the file text is used at each check but does not say whether the file is re-read or cached at bind time. The skill also says auto can neither arm nor clear a native goal.
- Consequence for U12 binding path: assume the file is NOT re-read until proven. Design U12 so an amendment triggers a rebind (`/goal clear`, then `/goal <file>` by the session or by Shawn). If the file does re-read, the rebind is harmless.

## Open items to close by hand

1. In a throwaway interactive session in a scratch repo: bind `/goal goal.md`, edit `goal.md`, let the session stop once, and read whether the next judge text shows the new wording.
2. In the same kind of session: launch with the first line `/auto-status` as the positional prompt and see if it runs.
