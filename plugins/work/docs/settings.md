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
| `HERDR_LINEAR_PROJECTS_ROOT` | `$HOME/projects` | The root every canonical checkout must sit under. A session outside it and outside the worktrees root gets no grounding block. The old spelling of this setting is still honoured, and `lib/contain.sh` prints what to rename it to. | `lib/contain.sh` | no |
| `HERDR_LINEAR_WORKTREES_ROOT` | `$HOME/worktrees` | Where a worktree started from a ticket is created. Nothing under it is canonical, so the whole tree stays safe to delete. | `lib/contain.sh` | no |
| `CLAUDE_PLUGIN_DATA` | `$HOME/.claude/plugins/data/work-shrimpshack` | The plugin's data directory. `scopes.json` in it records which repository a team's work lives in. Claude Code sets it for a running plugin; the default is used only outside a session. | `lib/repos.sh` | no |
| `HERDR_LINEAR_STORE_DIR` | `$HOME/.claude/work` | Where an earlier version of the plugin kept its records. It is read, never written: an answer about a team's repository found under `scopes/` there is copied into the data directory once. | `lib/repos.sh` | no |
| `HERDR_LINEAR_WORKTREE_SCHEME` | `identifier-title` | Which shape a worktree's directory name takes. Every scheme carries the ticket identifier, so the worktree stays findable from its branch whichever one is chosen. Valid: `identifier-title`, `identifier`. | `lib/schemes.sh` | no |
| `HERDR_LINEAR_BRANCH_SCHEME` | `prefix-worktree` | Which shape a branch name takes. It composes on the worktree scheme, so changing that changes both and the identifier stays in each. Valid: `prefix-worktree`, `worktree`. | `lib/schemes.sh` | no |
| `HERDR_LINEAR_TAB_SCHEME` | `identifier` | Which shape a herdr tab's label takes. Valid: `identifier`, `identifier-title`. | `lib/schemes.sh` | no |
| `HERDR_LINEAR_BRANCH_PREFIX` | `feature` | The prefix a branch started from a ticket is given. Set it empty and the branch takes the identical form as the worktree directory, with no code change. | `lib/schemes.sh` | yes |
| `HERDR_LINEAR_OPEN_SESSION` | `(none)` | Whether `/work:start` also opens a herdr tab for the new worktree. `true` opens one; unset, empty or `false` opens none. Anything else is named and read as no. | `skills/start/SKILL.md` | no |
| `HERDR_LINEAR_BIN_PATHS` | `/opt/homebrew/bin:/usr/local/bin:${HOME:-}/.local/bin` | The directories searched for the herdr executable when it is not on `PATH`. Set it empty to mean no known locations, so nothing resolves. | `lib/herdr-read.sh` | yes |
| `HERDR_LINEAR_HERDR_TIMEOUT_SECONDS` | `5` | How long one herdr read may take before it is ended and herdr is read as unavailable. Needs `perl` on `PATH`; without it the read is not bounded. | `lib/herdr-read.sh` | no |
| `HERDR_SOCKET_PATH` | `(none)` | The herdr session this pane belongs to, which herdr exports into every pane it opens. The plugin only reads it: a socket at `sessions/<name>/herdr.sock` is that session, any other `herdr.sock` is `default`, and unset means no session level at all. Set it by hand only to address another running session deliberately. | `lib/herdr-read.sh` | no |
| `HERDR_LINEAR_KEYCHAIN_SERVICE` | `work-linear` | The keychain service `bin/migrate-credential.sh` stores and checks the Linear credential under. | `bin/migrate-credential.sh` | no |
| `HERDR_LINEAR_KEYCHAIN_ACCOUNT` | `linear-api-key` | The keychain account `bin/migrate-credential.sh` stores and checks the Linear credential under. | `bin/migrate-credential.sh` | no |
| `HERDR_LINEAR_KEYCHAIN_TIMEOUT_SECONDS` | `(none)` | How long a keychain read may wait, for a caller nobody can answer an unlock prompt for. Unset, the read waits. Needs `perl` on `PATH`. | `lib/secrets.sh` | no |
| `HERDR_LINEAR_SETUP_LOCAL_TIMEOUT_SECONDS` | `10` | How long `bin/setup-check.sh` waits for one local read (herdr, the board's version and session) before it reports that check as unknown. | `bin/setup-check.sh` | no |
| `HERDR_LINEAR_SETUP_NETWORK_TIMEOUT_SECONDS` | `30` | How long `bin/setup-check.sh` waits for a read that can reach the network (`claude mcp get`, the import dry run, the Linear key check) before it reports that check as unknown. | `bin/setup-check.sh` | no |
| `LINEAR_SECRETS_FILE` | `$HOME/.secrets` | The plaintext file `bin/migrate-credential.sh` reports on, and removes the `LINEAR_API_KEY` line from once the keychain copy works. | `bin/migrate-credential.sh` | no |

---

## Not listed here

These are seams for tests and for the machine, not conventions a person chooses. They
work, and none of them is documented as a setting:

- **Executable paths** — every `*_BIN` name. They exist so a test can hand the plugin a
  stand-in for `git`, `curl`, `security`, `osascript`, or herdr itself.
- **Lock tuning** — how long the repository record's lock is waited for, and when a
  held lock counts as stale.
- **Herdr's own runtime identity** — the pane, tab, and workspace identifiers herdr
  exports into a pane it owns. The plugin reads them; nobody sets them.
- **The old spelling of the projects root** — still honoured, and still warned about. See
  `lib/contain.sh`, which prints the name to rename and what to rename it to.

---

## What a default may not be

No default names a person, a company, or an account. Where a value has to name an owner,
it is resolved from the Linear organization when it is read, rather than written into a
setting. A default that named one workplace is what made the old projects-root spelling a
problem worth a warning.
