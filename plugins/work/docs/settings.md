# Settings

Every setting a person may change in the `work` plugin. Each one is an environment
variable: export it from the shell, or set it in `~/.claude/settings.json`. Nothing here
has to be edited in shell code.

A setting is checked against the code by `tests/unit/settings-doc.bats`, in both
directions. A row naming a setting that does not exist fails, and a setting added later
without a row fails too.

---

## The settings

The last column matters more than it looks. Most settings are read as
`${NAME:-default}`, so setting one to an empty string is the same as not setting it at
all. Two are read as `${NAME-default}`, so an empty value is a value: it means the empty
string, and the default does not come back.

| Setting | Default | What changes when it is set | Defining file | Empty differs from unset |
|---|---|---|---|---|
| `HERDR_LINEAR_PROJECTS_ROOT` | `$HOME/projects` | The root every canonical checkout must sit under. A session outside it is refused. The old spelling of this setting is still honoured, and `lib/contain.sh` prints what to rename it to. | `lib/contain.sh` | no |
| `HERDR_LINEAR_WORKTREES_ROOT` | `$HOME/worktrees` | Where a worktree started from a ticket is created. Nothing under it is canonical, so the whole tree stays safe to delete. | `lib/contain.sh` | no |
| `HERDR_LINEAR_STORE_DIR` | `$HOME/.claude/work` | Where bindings between a worktree and a ticket are recorded. | `lib/binding.sh` | no |
| `HERDR_LINEAR_PIN_DIR` | `$HOME/.claude/linear-pin` | Where a pinned ticket for the current session is held. | `lib/binding.sh` | no |
| `HERDR_LINEAR_JOURNAL_DIR` | `$HOME/.claude/work/layouts` | Where a layout the plugin built is journalled. | `lib/herdr-write.sh` | no |
| `HERDR_LINEAR_DESC_BACKUP_DIR` | `$HOME/.claude/work/descriptions` | Where a ticket description is copied before it is overwritten. | `lib/description.sh` | no |
| `HERDR_LINEAR_SHADOW_LOG` | `$HOME/.claude/work/shadow.log` | Where a write that was only rehearsed is logged instead of sent. | `lib/binding.sh` | no |
| `HERDR_LINEAR_WORKTREE_SCHEME` | `identifier-title` | Which shape a worktree's directory name takes. Every scheme carries the ticket identifier, so the worktree stays findable from its branch whichever one is chosen. Valid: `identifier-title`, `identifier`. | `lib/schemes.sh` | no |
| `HERDR_LINEAR_BRANCH_SCHEME` | `prefix-worktree` | Which shape a branch name takes. It composes on the worktree scheme, so changing that changes both and the identifier stays in each. Valid: `prefix-worktree`, `worktree`. | `lib/schemes.sh` | no |
| `HERDR_LINEAR_BOARD_PAGE_SIZE` | `50` | How many tickets the board reads from Linear in one request. A smaller page costs less rate limit per request and needs more requests. | `lib/board-linear.sh` | no |
| `HERDR_LINEAR_BOARD_MAX_PAGES` | `100` | The most pages one board read takes. A read that reaches it is incomplete, and an incomplete read changes nothing on the board. | `lib/board-linear.sh` | no |
| `HERDR_LINEAR_BOARD_CALL_SECONDS` | `15` | How long the board waits for one herdr command before treating herdr as unreachable. | `lib/board-herdr.sh` | no |
| `HERDR_LINEAR_BOARD_PANE_CAP` | `16` | The most panes one tab build moves or places at a time. The rest wait for a person to ask for more at the next `/work` command. | `lib/board-herdr.sh` | no |
| `HERDR_LINEAR_BOARD_FENCE_SECONDS` | `90` | How long the board sync at the start of a `/work` command may run before it is stopped. The command carries on either way, and the next sync finishes what a stopped one left. | `lib/board-attended.sh` | no |
| `HERDR_LINEAR_BOARD_TAB_LIMIT` | `4` | How many panes a board tab takes before new tickets for it wait on the place-more question at the next `/work` command. Answering yes places them; panes already in a tab are never removed for being over it. | `lib/board-sync.sh` | no |
| `HERDR_LINEAR_BOUND_WORKTREE_LIMIT` | `8` | How many already-bound worktrees `/work:bind` offers when it runs outside a worktree and the project has no recorded repository. Each one costs a Linear read. | `lib/propose.sh` | no |
| `HERDR_LINEAR_BOARD_SYNC_WAIT_SECONDS` | `10` | How long a board sync waits for another sync that holds the board lock before it gives up and changes nothing. A lock whose holder is no longer running is taken at once. | `lib/board-sync.sh` | no |
| `HERDR_LINEAR_SOCKET_PATH` | `(none)` | The herdr socket the board moves panes through. Unset asks the running herdr server where its socket is. | `lib/board-herdr.sh` | no |
| `HERDR_LINEAR_TAB_SCHEME` | `identifier` | Which shape a herdr tab's label takes. Valid: `identifier`, `identifier-title`. | `lib/schemes.sh` | no |
| `HERDR_LINEAR_OPEN_SESSION` | `(none)` | Whether starting work also opens a herdr session. Unset leaves each path as it is: `/work:new` opens one and `/work:start` does not. `true` opens one on both; `false` opens one on neither. Anything else is named on stderr and read as unset. | `lib/start.sh` | no |
| `HERDR_LINEAR_CONVENTIONS_PATH` | `${CLAUDE_PLUGIN_ROOT}/docs/linear-conventions.md` | The rulebook the plugin follows when it writes a Linear title, description or document. Set it to keep the conventions in a repository of their own. A path naming nothing readable is refused with the path printed, rather than the shipped copy being served in its place, so a typo cannot restore the old rulebook unnoticed. This one is settable from the environment only and is never a field in a configuration file: seven skills read the file as instructions, and it decides what the plugin writes to Linear. | `lib/documents.sh` | no |
| `HERDR_LINEAR_BRANCH_PREFIX` | `feature` | The prefix a branch started from a ticket is given. Set it empty and the branch takes the identical form as the worktree directory, with no code change. | `lib/start.sh` | yes |
| `HERDR_LINEAR_BIN_PATHS` | `/opt/homebrew/bin:/usr/local/bin:${HOME:-}/.local/bin` | The directories searched for the herdr executable when it is not on `PATH`. Set it empty to mean no known locations, so nothing resolves. | `lib/herdr-read.sh` | yes |
| `HERDR_LINEAR_API_URL` | `https://api.linear.app/graphql` | The endpoint every Linear query and mutation is sent to. | `lib/linear.sh` | no |
| `HERDR_LINEAR_KEYCHAIN_SERVICE` | `work-linear` | The keychain service the Linear credential is stored under. | `lib/linear.sh` | no |
| `HERDR_LINEAR_KEYCHAIN_ACCOUNT` | `linear-api-key` | The keychain account the Linear credential is stored under. | `lib/linear.sh` | no |
| `HERDR_LINEAR_CACHE_MAX_AGE_SECONDS` | `3600` | How long a cached ticket is treated as current before it is fetched again. | `lib/linear.sh` | no |
| `LINEAR_CACHE_DIR` | `$HOME/.claude/linear-cache` | Where fetched tickets are cached. | `lib/linear.sh` | no |
| `LINEAR_SECRETS_FILE` | `$HOME/.secrets` | The file a `LINEAR_API_KEY` line is read from when the keychain holds nothing. | `lib/linear.sh` | no |

---

## Not listed here

These are seams for tests and for the machine, not conventions a person chooses. They
work, and none of them is documented as a setting:

- **Executable paths** — every `*_BIN` name. They exist so a test can hand the plugin a
  stand-in for `git`, `curl`, `gh`, `security`, `osascript`, or herdr itself.
- **Lock, retry, poll, and timeout tuning** — how long a lock is waited for, how many
  times a request is retried, how often a pane is polled, how long a request may take.
- **Herdr's own runtime identity** — the pane, tab, and workspace identifiers and the
  socket path herdr exports into a pane it owns. The plugin reads them; nobody sets them.
  The socket path names the herdr session, which is why a record keyed by a herdr id is
  kept per session.
- **The old spelling of the projects root** — still honoured, and still warned about. See
  `lib/contain.sh`, which prints the name to rename and what to rename it to.

---

## The herdr plugin

`herdr/herdr-plugin.toml` is a herdr plugin with the id `work.session`. It asks an unbound
herdr session which Linear scope it is for, and shows that scope. Link it once, and it runs
in every herdr session you start:

```sh
herdr plugin link "<plugin root>/herdr"
```

- **When it asks.** At a session's start, when the session is unbound, has not declined,
  and has not been asked before. The question opens as a popup, and a popup opened before
  you attach is there when you do. Pressing Enter leaves the session unbound and does not
  ask again. `/work:bind`, or the plugin's "Bind this session to a Linear scope" action,
  asks again whenever you want.
- **Turning the ask off.** Create a file named `no-ask` in the plugin's config directory.
  No session is asked at start after that; the action and `/work:bind` still work.

  ```sh
  touch "$(herdr plugin config-dir work.session)/no-ask"
  ```

- **Showing the scope.** herdr cannot let a plugin change its tab bar, so add the entry
  yourself, in `~/.config/herdr/config.toml` under `[ui]`. herdr runs it on each session's
  own server, so every session shows its own scope, or `unbound`:

  ```toml
  tab_bar_right = [{ type = "command", command = "bash <plugin root>/bin/session-label.sh" }]
  ```

- **Settings it cannot see.** herdr starts these scripts, not Claude Code, so a setting
  made only in `~/.claude/settings.json` does not reach them. They use the defaults above,
  or the value exported in the environment herdr was started from. A session binding is
  stored under `sessions/<name>/` in `HERDR_LINEAR_STORE_DIR`.

---

## What a default may not be

No default names a person, a company, or an account. Where a value has to name an owner,
it is resolved from the Linear organization when it is read, rather than written into a
setting. A default that named one workplace is what made the old projects-root spelling a
problem worth a warning.
