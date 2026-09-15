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
| `HERDR_LINEAR_BOARD_PANE_CAP` | `16` | The most panes one tab build moves or places at a time. The rest wait for a person to ask for more at the next `/work` command. | `lib/board-herdr.sh` | no |
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
