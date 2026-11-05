# Changing how a hook behaves

Read this when one of Auto's own hooks blocks work, or when Shawn asks you to change one. `P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

You control Auto's hooks, even when shrimpshack is outside your remit. This covers hook code only. Auto refuses neither route below. Claude Code's own permissions still apply: neither route bypasses them, and a Claude Code denial on one of these edits goes through Claude Code's normal handling.

## Pick a route

1. A setting: see [Check settings](#check-settings). It is the smallest change and needs no code.
2. Code by PR and publish, when the change can wait for a publish.
3. A patch to the installed copy, when the hook blocks work now.

## Check settings

`P set-check <name> on|off [--item <id>]` changes a check for the programme or one item. An item setting beats the programme setting. A sub-agent cannot run this verb.

| Check | Default | Turning it off | Turning it on |
|---|---|---|---|
| `no-destructive-commands` | off | you, alone | Shawn's pick |
| `no-settings-writes` | off | you, alone | Shawn's pick |
| `pm-settings-writes` | on | you, alone | you, alone |
| `literal-send` | on | you, alone | Shawn's pick |
| `tracker-outside-remit` | on | you, alone | you, alone |
| `advisor-redirect` | on | you, alone | Shawn's pick |
| `subagent-refusals` | on | you, alone | you, alone |
| `stop-block` | on | you, alone | Shawn's pick; `--own` for your own run, you alone |
| `tracker-proof` | on | never | n/a |
| `prefilled-answers` | on | never | n/a |

When a change needs Shawn's pick:

1. Run `P offer <question-key> --command 'set-check <name> on'`.
2. Ask with the input it prints. The decline is listed first.
3. On a pick of the option, run the command with `--prompt <pick id>`. His own words do not approve it: relay them and ask again.

A contract's `--limit <check>` and a behaviour file's `limit: <check>` name a limit and turn nothing on. `P set-contract` and `adopt-behaviour-file` print the offer in `limit_asks`. `P status` lists each named limit that is not on. A `--drop-limit` removes the name and leaves the setting as it is.

`P status` and `P rules` list every setting. A setting is outside the agreed terms, so a change never asks Shawn to accept the agreement again.

### What a limit does

A limit that is on binds every session attached to the item, its sub-agents and takeover sessions, until the item finishes or the programme ends. A launched session that is attached to no item has no limit: run `P add-item` or attach it if it must carry one. Your own session takes a limit only when it is attached to an item.

A refusal stops one call, journals it as `limit_refused` or `blocked_limit_write`, and pauses nothing. It names the limit, and the worker asks you to lift it. While any limit is on, the session also cannot write:

- the programme's files, or set `CLAUDE_AUTO_DATA_DIR`
- the installed plugin cache
- `disableAllHooks` or `allowManagedHooksOnly` in a `settings.json` or `settings.local.json`

Each of those would let the worker switch off the hook that enforces its limit. Reads stay open, and so do runs of the plugin's own scripts. A session with no limit on has none of these checks.

A limit is a best-effort text and path check. A file tool is matched by real path, and a Bash command by its text. A path built at run time, a script written first and run later, a glob, a symlink into these folders, a settings file copied from one made earlier, or a key spelled with a JSON unicode escape can get past it. Do not use a limit to contain a session you do not trust.

## Code by PR and publish

1. Change the hook in a shrimpshack checkout and open a PR.
2. Ask Shawn to merge it. You never merge this PR yourself.
3. Publish with `scripts/publish-plugin.sh`.

Hooks run from the installed plugin cache, not from a checkout. A change reaches workers only after publish and reload.

## A patch to the installed copy

The installed copy is `~/.claude/plugins/cache/shrimpshack/auto/<version>/`, the same folder as `${CLAUDE_PLUGIN_ROOT}`. A patch changes that copy on this machine for every programme here, and the next plugin update overwrites it. So do all of this in the same sweep:

1. Patch the file.
2. Open a PR with the same change.
3. Run `P record-hook-patch <file> --why "<why>" --pr <url or number>` once per file. It journals the patch, so `P status` lists it under Just did, and it sends Shawn the notice.
4. Post the `text` line from its output in chat, unchanged. When the file holds a protected rule, the notice names that rule.

A sub-agent cannot run this verb. Run it in your own Bash tool.

## What a pick proves

A pick or a message counts only from the transcript the session registry holds for that session, at capture and at every later check. A session the registry holds no path for falls back to an absolute path whose file name is `<session id>.jsonl`, so a missing row never locks a session out. A PM with a shell can still edit its real transcript or the journal. Picks stop mistakes, not a hostile session.
