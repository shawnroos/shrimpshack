# Remit

The scope the PM looks after: terminal spaces, git repos (each worktree path is listed) and tracker scope. A pane whose folder is not in the remit is skipped as out of remit. `set-remit` replaces the whole repo list, so pass every repo each time.

- **Where it lives:** `auto:programme-remit` skill
- **Note:** Changing the remit needs a typed line that names each repo added or removed. The one exception is a worker the PM starts with `start-worker`: its repo is recorded in `worker_repos`, which widens the sweep only, and leaves when `close-gone-pane` closes its pane.
