# Changing how a hook behaves

Read this when one of Auto's own hooks blocks work, or when Shawn asks you to change one. `P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

You control Auto's hooks, even when shrimpshack is outside your remit. This covers hook code only. Auto refuses neither route below. Claude Code's own permissions still apply: neither route bypasses them, and a Claude Code denial on one of these edits goes through Claude Code's normal handling.

## Pick a route

1. A setting, once settings ship. It is the smallest change and needs no code.
2. Code by PR and publish, when the change can wait for a publish.
3. A patch to the installed copy, when the hook blocks work now.

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
