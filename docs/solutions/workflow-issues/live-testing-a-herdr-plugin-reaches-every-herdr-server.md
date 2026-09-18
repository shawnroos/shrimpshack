---
title: "Live-testing a herdr plugin reaches every herdr server you run, so test it in an isolated herdr home"
date: 2026-09-17
module: plugins/work (herdr plugin)
problem_type: workflow_issue
component: tooling
severity: high
category: workflow-issues
applies_when:
  - "linking a herdr plugin to try a startup hook, action or popup pane for real"
  - "another tool or session is running its own throwaway herdr servers on the same machine"
  - "writing a herdr startup hook that does anything a person would notice (a popup, a record, a label)"
symptoms:
  - "a test plugin's startup hook fired inside another tool's throwaway herdr session and opened a popup there"
  - "`herdr ... reload-config` against a session under a long scratch path failed with `local socket name length exceeds capacity of sun_path`"
  - "keys typed into a freshly opened bind popup went to herdr's first-run onboarding screen instead"
root_cause: inadequate_documentation
related_components:
  - herdr
  - testing_framework
tags:
  - herdr
  - herdr-plugin
  - live-testing
  - xdg-config-home
  - startup-hook
  - isolation
---

# Live-testing a herdr plugin reaches every herdr server you run, so test it in an isolated herdr home

## Context

`herdr plugin link <path>` registers a plugin for the whole herdr home, not for one
session. From then on its `[[startup]]` hook runs once in **every** herdr server that
starts, including sessions another tool starts for its own end-to-end tests. During the
session-binding spike (plugins/work/docs/session-spikes.md, fact 7) a disposable test
plugin linked into the normal home fired inside another tool's `hb-e2e-clprobe-*` server
and opened its popup there. herdr popups are session-modal, so this can also block that
tool's own popups.

Two more traps turned up on the first attempts. A herdr home under the session scratchpad
path was too long for a Unix socket, so CLI calls to that server failed. And a brand-new
herdr home shows a first-run onboarding screen that takes keyboard focus away from the
plugin's popup, so typed answers went to the wrong place.

## Guidance

Run every live check of a herdr plugin inside its own herdr home, with a disposable plugin
id and a scratch store. herdr follows `XDG_CONFIG_HOME`: a server started with
`XDG_CONFIG_HOME=/x` keeps its sessions under `/x/herdr/sessions/` and its config at
`/x/herdr/config.toml`. A plugin linked with the same variable is registered only in that
home.

1. Pick a **short** home path, such as `/private/tmp/spkw`. A long path makes the session
   socket exceed the `sun_path` limit.
2. Write `/x/herdr/config.toml` with `onboarding = false` on its own line, before any
   `[ui]` table, plus any `tab_bar_right` entry under test. herdr writes
   `onboarding = false` itself after the first run, so check the file for a duplicate key
   before starting again.
3. Copy the plugin manifest with a disposable id (for example `spike.<name>.<random>`),
   and point its commands at a scratch store (`HERDR_LINEAR_STORE_DIR=/x/store`).
4. Link inside the home: `XDG_CONFIG_HOME=/x herdr plugin link /x/p/herdr`. Confirm the
   normal `herdr plugin list` does not show it.
5. Start sessions with `env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_ENV XDG_CONFIG_HOME=/x herdr --session spk-a`.
   Unset the `HERDR_*` variables, because a pane's socket variable would otherwise aim the
   CLI at the server you are running inside. Drive a client with tmux `send-keys` and read
   it with `capture-pane`.
6. Clean up by stopping and deleting each session with `XDG_CONFIG_HOME=/x`, then removing
   `/x`. Removing the home also removes the plugin registration, so a failed `unlink` (it
   needs a running server) leaves nothing behind.

Before linking into the normal home at all, give the startup hook restraint of its own. It
should exit quietly when the socket names no session it recognises, offer a person an off
switch, and ask at most once per session. The work plugin's `plugins/work/bin/session-start.sh` does
all three.

## Why This Matters

A linked plugin is shared state across every herdr session on the machine. A test that
links into the normal home is not a test of one session. It is a change to every session
started until the unlink, including sessions other agents are running at that moment. The
failure is quiet: nothing errors in your test, and the popup or record lands somewhere you
are not looking.

## When to Apply

- Any live verification of a herdr `[[startup]]` hook, `[[actions]]` entry, popup pane or
  `tab_bar_right` command entry.
- Any time another session on the machine may be starting herdr servers, which in practice
  is always.

## Examples

Before, in the spike: the plugin linked into the normal home, with only a guard inside the
hook.

```sh
herdr plugin link "$SCRATCH/spike-plugin"        # registered for every server
# record.sh had to add: case "$HERDR_SOCKET_PATH" in */sessions/spk-*) ;; *) exit 0;; esac
```

After, in the live check of AE1, AE2 and AE5: the plugin lived only inside an isolated
home.

```sh
Y=/private/tmp/spkw
printf 'onboarding = false\n[ui]\ntab_bar_right = [{ type = "command", command = "HERDR_LINEAR_STORE_DIR=%s/store bash %s/p/bin/session-label.sh" }]\n' "$Y" "$Y" > "$Y/herdr/config.toml"
env -u HERDR_SOCKET_PATH XDG_CONFIG_HOME="$Y" herdr plugin link "$Y/p/herdr"
tmux new-session -d -s spkw2 "env -u HERDR_SOCKET_PATH -u TMUX XDG_CONFIG_HOME=$Y herdr --session spk-w2"
# ... drive and capture ...
env -u HERDR_SOCKET_PATH XDG_CONFIG_HOME="$Y" herdr session stop spk-w2
env -u HERDR_SOCKET_PATH XDG_CONFIG_HOME="$Y" herdr session delete spk-w2
rm -rf "$Y"
```

Related: `docs/solutions/best-practices/default-deny-for-an-unattended-agent.md` (the same
concern for an unattended process in general) and
`docs/solutions/best-practices/pgrep-pkill-by-shared-script-name-is-unsound-across-worktrees.md`
(another shared-machine selector that reaches work that is not yours).
