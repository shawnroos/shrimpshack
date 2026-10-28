# Token efficiency: assumption checks and byte ranking

Evidence for `docs/plans/2026-10-28-1003-feat-token-efficiency-plan.md` (U2 assumption checks, U6 gate). Measured with `plugins/auto/lib/token-cost.sh` on 2026-10-28.

## Assumptions (U2)

| | Assumption | Result | Evidence |
|---|---|---|---|
| A1 | The packager's commands pass the sub-agent guard | Partly refuted, fixed in U3 | `refusal()` in `on-pretooluse-subagent.py` allows `status`, `inbox`, `describe`, `tail`/`grep` on the journal, and a `cat > file <<'EOF'` digest write (even with "programme" in the body). It denies `rules` (not in `READ_VERBS`), `mkdir` and `echo`/`printf` redirects on a path naming "programme". U3 allows `rules` without `--ack`, and writes the digest to an existing directory with `cat`. |
| A2 | Watchers and cron survive compaction | Likely, undocumented | Docs: background Bash and subagents survive compaction. Monitor and cron are not documented either way; the process does not end, and the Stop payload carries `background_tasks` and `session_crons`. |
| A3 | An automatic compaction lever reaches a running PM | Refuted for "no Shawn action" | Levers: `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (env, read at launch), `autoCompactWindow` (settings key, effect on a running session undocumented), `--autocompact` (launch flag), `/autocompact <n>` (applies to a running session at once, typed by Shawn). No hook or model can run it. U5 is closed and R7 is advisory. |
| A4 | A Stop hook can read context size | Verified | `transcript_path` is in every hook payload; `message.usage` lines are present in the transcripts (the cost script reads them) though the docs do not describe that schema. Not needed once U5 closed. |
| A5 | A second PM session exists for re-baselining | Refuted | Only one session activated `programme-sweep` more than 12 times (`8c75f931`, 113 activations). The next has 12. The halving bar is re-measured on new PM days after the change ships. |
| A6 | The Stop hook adds no PM turn to a quiet sweep | Verified by code | `decide()` in `on-stop.py` blocks only when a programme's stop signature is new for the session (`_split_programmes`); a repeat signature goes to `quiet` and returns `None`. |

## Baseline re-measured (U1 script)

Peek programme PM session `8c75f931`: parent cost 10.50M units, plus 1.60M units of subagent cost on 2026-10-23 that the earlier figure left out (12.10M together); 613 turns, 113 sweep activations, average context 115k, peak 167k, idle-wake share 17%.

## Where the PM's tool-result bytes go (U6 gate)

Same session, 1.78M characters of tool results:

| Class | Characters | Share |
|---|---|---|
| Reads of plugin skill and reference files | 1,204,917 | 67.5% |
| Reads of project files | 241,668 | 13.5% |
| `programme.sh` verbs | 130,175 | 7.3% |
| `git` | 71,262 | 4.0% |
| `herdr` (worker panes) | 29,971 | 1.7% |

Of the plugin reads, 1.15M characters are compound-engineering references (`ce-plan`, `ce-doc-review`, `ce-work`, `ce-code-review`) and 53k are auto's own files. This PM ran CE pipelines in its own context. Neither an artifact generator (R9) nor a worker-chaser (R10) addresses a top class, so U6 is not built.
