# Session binding spikes

Facts measured on 2026-09-16 with herdr 0.9.0, before building session binding. Each herdr check ran in a throwaway `herdr --session spk-*` server with a disposable linked test plugin (`spike.sessbind.*`), unlinked afterwards. Each Linear check was a read.

## Stop conditions

None holds.

| Stop condition | Answer | Evidence |
|---|---|---|
| A startup hook cannot tell which session it runs in | No: it can | The hook in session `spk-nocli` received `HERDR_SOCKET_PATH=~/.config/herdr/sessions/spk-nocli/herdr.sock`, and `herdr status` from the hook printed the same socket. |
| A fresh `herdr --session <name>` start never runs the startup hook with a client attached | No: it runs | `herdr --session spk-fresh` started in a terminal ran the hook, and the popup the hook opened was on screen. |
| Linear cannot answer team or initiative membership | No: it can | `projects { teams { nodes { key } } initiatives { nodes { id } } }` answers both; an issue filter `project: { initiatives: { some: { id: { eq: "<id>" } } } }` returned that initiative's issues. |

## herdr

1. **Session name from the socket.** `herdr session list` prints each session's socket: `default` at `~/.config/herdr/herdr.sock`, a named session at `~/.config/herdr/sessions/<name>/herdr.sock`. The herdr home follows `XDG_CONFIG_HOME` (a server started with `XDG_CONFIG_HOME=/x` put its session under `/x/herdr/sessions/`), so the rule matches the `herdr/herdr.sock` and `herdr/sessions/<name>/herdr.sock` tails, not a fixed home.
2. **Socket path length.** A herdr home under a long directory fails with `local socket name length exceeds capacity of sun_path`. Tests keep fake socket paths short or never bind them.
3. **Startup hook environment.** The hook receives `HERDR_PLUGIN_EVENT=startup`, `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_PLUGIN_ID` and the ids of the first pane (`w1`, `w1:t1`, `w1:p1`). `HERDR_BIN_PATH` differs between servers (`/opt/homebrew/bin/herdr` and `~/.local/bin/herdr` were both seen).
4. **Popup with no client.** In a headless server (`herdr --session spk-nocli server`), `herdr plugin pane open --plugin <id> --entrypoint ask` from the hook answered `{"type":"ok"}` and exit 0, and the popup's process ran. The call gives no sign that nobody can see it.
5. **Popup seen on a later attach.** In `spk-late2`, the hook opened the popup with no client; a client attached five seconds later saw the popup on screen. So the hook does not need to know whether a client is attached: it opens the popup, and the person sees it on attach while the popup's process still runs.
6. **Popup environment.** The popup's process receives `HERDR_SOCKET_PATH` and `HERDR_PLUGIN_ENTRYPOINT_ID`, and no `HERDR_PANE_ID`. The CLI `--placement` flag offers no `popup` value; the manifest's `placement = "popup"` applies when the open request names none.
7. **Linked plugins reach every server.** While the test plugin was linked, its startup hook also ran in another tool's throwaway server (`hb-e2e-clprobe-*`). A shipped startup hook runs in every herdr server the person starts, so it must do nothing harmful in a server it does not recognise.
8. **Tab bar label.** A `tab_bar_right` entry `{ type = "command", command = "<shell string>" }` (a string; an array is a config parse error) runs with the session's own `HERDR_SOCKET_PATH`: session `spk-x` showed `lbl:spk-x`. The entry lives in the person's global `config.toml`, so one entry serves every session, and a plugin cannot add it: the person adds the line. The window title fallback (KTD7) was not needed and was not measured.

## Linear

1. **Organization:** `organization { id name urlKey }` answers.
2. **Project to teams:** `project.teams` is a list; a project can belong to several teams (one had five). A project is inside a team session when that team is in its list.
3. **Project to initiatives:** `project.initiatives` is a list and is often empty.
4. **Issue to scope:** `issue { team { id key } project { id teams initiatives } }` answers every membership question in one read.
5. **Board filters:** `issues(filter: { team: { key: { eq: "WEB" } } })` and `issues(filter: { project: { initiatives: { some: { id: { eq: "<id>" } } } } })` both answer; the shorter `project: { initiatives: { id: { eq } } }` form also answers.

## Effect on the plan

- KTD6 keeps its decision (ask at start through a herdr plugin). The hook opens the popup whether or not a client is attached (fact 5), instead of choosing between the popup and the label.
- The startup hook exits quietly when the socket fails the naming rule (fact 7).
- KTD7 holds: the label is a documented `tab_bar_right` command entry the person adds (fact 8).
