# Observed permission events (Claude Code 2.1.303, 2026-10-19)

Recorded by headless `claude -p --setting-sources project,local --model haiku` runs. Setup: a scratch repo, a sibling worktree, and a stub `gh` first on `PATH`; `GH_TOKEN` unset and `GH_CONFIG_DIR` set to a scratch folder. A throwaway dump hook was registered for `PermissionDenied`, `PostToolUse` and `PostToolUseFailure` in the worktree's `.claude/settings.json`. Every `gh` call reached the stub; its log shows only the four calls listed below. Content is redacted to keys and refusal text.

| # | Observation | Result |
|---|---|---|
| 1 | Allow in the main checkout's `.claude/settings.local.json` covers a read in a worktree session | Yes. `Bash(gh pr checks *)` there let `gh pr checks 12` run from the worktree in `dontAsk` mode. |
| 2 | `gh pr merge 1` and `gh pr checks 1 && gh pr merge 1` in `dontAsk` mode | Both refused; the stub logged neither. |
| 3 | Post-tool event for a `gh` that runs and exits non-zero | `PostToolUseFailure`. Exit 0 fires `PostToolUse`. |
| 4 | `PermissionDenied` payload | Not observed. In auto mode with no allow rule, the classifier allowed `gh pr merge 7 --squash` against the stub, so no honest run produced a classifier denial. The hook contract rests on the documented fields: `tool_name`, `tool_input`, `tool_use_id`, `reason`, plus common fields. |
| 5 | Managed settings | None present (`/Library/Application Support/ClaudeCode/` does not exist). |
| 6 | Auto mode with the allow present | The read ran; the transcript decision is `accept`, source `config`, reason `subcommandResults`. No classifier ran. |
| 7 | Post-tool event when a deny rule refuses the call | None. A deny rule and a `dontAsk` refusal fire no `PermissionDenied`, no `PostToolUse` and no `PostToolUseFailure`. Only the transcript records them. |
| 8 | Transcript rows | See below. |

## Hook payload: PostToolUse / PostToolUseFailure

Keys: `session_id`, `transcript_path`, `cwd`, `prompt_id`, `permission_mode`, `effort`, `hook_event_name`, `tool_name`, `tool_input` (`command`, `description`), `tool_use_id`, `duration_ms`.
`PostToolUseFailure` adds `error` (exit code plus command output) and `is_interrupt`. `PostToolUse` carries `tool_response`. Both output fields can hold command output and must never be stored.

## Transcript rows

The assistant row holds a `tool_use` block with `id`, `name`, `input.command`.
The following user row holds a `tool_result` block (`tool_use_id`, `is_error`, `content`) and two row-level fields that record the runtime's own decision:

| Case | `permissionDecision` | `toolDenialKind` | `is_error` |
|---|---|---|---|
| Ran, exit 8 (red or pending CI) | `{"decision":"accept","source":"config","reasonType":"subcommandResults"}` | `null` | `true` |
| Ran, exit 0, approved by the classifier | `{"decision":"accept","source":"config","reasonType":"classifier"}` | `null` | `false` |
| Refused by `dontAsk` mode | `{"decision":"reject","source":"config","reasonType":"mode"}` | `"permission-rule"` | `true` |
| Refused by a deny rule | `{"decision":"reject","source":"config","reasonType":"subcommandResults"}` | `"permission-rule"` | `true` |
| Refused by a PreToolUse hook (the settings guard, observed in the end-to-end run) | `{"decision":"reject","source":"hook","reasonType":"hook"}` | `"permission-rule"` | `true` |

The refusal `content` begins `Permission to use Bash has been denied because Claude Code is running in don't ask mode.` `is_error` is `true` for both a refusal and a red-CI run, so it cannot tell them apart.

## Consequences for the implementation

- KTD1's denial predicate reads `permissionDecision.decision` (`reject` or `accept`) from the transcript result row, not refusal text and not `is_error`. A result row without `permissionDecision` is unconfirmed.
- `reasonType` and `toolDenialKind` name the layer for refusals no hook reports, such as a deny rule or a mode. U4 uses them in the `ineffective` diagnosis.
- Deny-rule and mode refusals leave no hook row, so U4 finds them by reading the reserved session's transcript after the reservation. Hook rows alone would settle these cases as `retry_unobserved`.
- The classifier rejection shape (`reasonType: "classifier"` with `decision: "reject"`) was not observed. Code treats any `reject` as a denial and maps an unrecognized `reasonType` to `unknown`.
