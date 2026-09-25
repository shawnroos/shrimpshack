# Board spikes (U1)

Findings for plan `docs/plans/2026-09-14-1322-feat-herdr-linear-board-plan.md`, unit U1 (Spike herdr and Linear facts). Run on 2026-09-14 with herdr 0.9.0 (protocol 22) against a throwaway herdr session, and read-only against real Linear.

## Stop conditions

| # | Stop condition | Answer | Evidence |
|---|---|---|---|
| 1 | herdr can place or move a pane without killing its process | **Yes, with `pane move`. No, with `layout.apply`.** | Step 2: shell pid 96921 and `sleep` pid 98604 survived a move to another tab and then to another workspace; cwd and `terminal_id` unchanged. Step 1: `layout.apply` replaced the whole tab and killed every process in it. |
| 2 | A sync can read a complete filter result within Linear's rate limits | **Yes.** | Step 6: 162 issues in 4 requests at `first:50` (3.6 s) or 1 request at `first:250` (1.1 s). `X-Complexity: 15` per request. One sync uses 0.16% of the hourly request budget. |
| 3 | Column and row membership can be read from herdr's layout without ambiguity | **Yes, only for a canonical tree read from `layout.export`.** Not from rects. | Step 5: the tree names columns and rows exactly while the tab keeps the board's shape. A collapse, a column with fewer panes than rows, or a pane dropped beside another gives a tree that position alone cannot map to a row. Rule: a non-canonical tree is a conflict question, never a write-back. |

None of the three is a stop, provided U7 adopts the rules below: the KTD5 branch is chained `pane move`, and the KTD4 canonical-tree rule.

## How the isolated server was run

The live server (`~/.config/herdr/herdr.sock`) was never addressed for a mutation.

```
cd <scratch> && env -i HOME=$HOME PATH=... SHELL=/bin/zsh TERM=xterm-256color \
  nohup herdr --session u1spike server &
herdr session list
#   default  running  ~/.config/herdr/herdr.sock
#   u1spike  running  ~/.config/herdr/sessions/u1spike/herdr.sock
```

Every command went through a wrapper that unsets `HERDR_PANE_ID`/`HERDR_TAB_ID`/`HERDR_WORKSPACE_ID` and sets `HERDR_SOCKET_PATH=~/.config/herdr/sessions/u1spike/herdr.sock`. Refuses the live path. Before the first mutation:

```
hs status --json   -> "socket":"~/.config/herdr/sessions/u1spike/herdr.sock"
hs api snapshot    -> {"workspaces":[],"tabs":[],"panes":[]}   (live server has many)
```

Methods with no CLI verb (`layout.apply`, `layout.export`, `pane.move` with `focus:false`, `server.stop`) went through a small python3 Unix-socket client with the isolated socket path hard-coded. Wire format: one JSON line `{"id","method","params"}`, one JSON line back.

## Step 1: `layout.apply` with existing pane ids

Test A: tab `w1:t1` held `w1:p3` (sleep 98605, shell 96909) and `w1:p5` (shell 9738). Applied a tree naming both, reordered and with the split direction flipped:

```
layout.apply {"tab_id":"w1:t1","focus":false,"root":{"type":"split","direction":"down","ratio":0.4,
  "first":{"type":"pane","pane_id":"w1:p5"},"second":{"type":"pane","pane_id":"w1:p3"}}}
-> {"tab_id":"w1:t3", root: pane "w1:p6", pane "w1:p7"}
layout.export w1:t1 -> layout_not_found
kill -0 98605 / 96909 / 9738 -> gone / gone / gone
```

Test B: tab `w2:t1` held `w2:p1` (shell 9752) and `w2:p2` (shell 96921, sleep 98604). The tree named only `w2:p1`, plus one new unnamed pane:

```
-> {"tab_id":"w2:t2", panes "w2:p3","w2:p4"}; w2:p1 and w2:p2 gone
kill -0 98604 / 96921 / 9752 -> gone / gone / gone
```

Also: passing both `tab_id` and `workspace_id` returns `invalid_target: use either tab_id or workspace_id, not both`.

**Conclusion.** `layout.apply` does not place existing panes. It closes the target tab and every pane in it, named or not, and kills their processes. It ignores `pane_id` in the tree, then builds a new tab with a new tab id and new pane ids. It is safe only for a tab that holds no process worth keeping.

## Step 2: `pane move` across tabs and workspaces

```
before:                       w1:p4 shell 96921 fg sleep 98604 cwd d  term_65b70c73bdf494
pane move w1:p4 --tab w1:t2 --split right --target-pane w1:p5
  -> changed:true, pane_id w1:p4, terminal term_65b70c73bdf494
after tab move:               w1:p4 shell 96921 fg sleep 98604 cwd d
pane move w1:p4 --tab w2:t1 --split down --target-pane w2:p1
  -> changed:true, previous_pane_id w1:p4, new pane_id w2:p2, terminal term_65b70c73bdf494
after workspace move:         w2:p2 shell 96921 fg sleep 98604 cwd d
pane output still shows:      MARK pid=96921 pane=w1:p4
```

**Conclusion.** The process, its cwd and `terminal_id` survive both moves. Other facts U7 and KTD3 depend on:

- **A move to another workspace renames the pane** (`w1:p4` became `w2:p2`). The process keeps `HERDR_PANE_ID=w1:p4`, so its env value is stale. The old id resolved as an alias while the server ran (`pane get w1:p4` returned `w2:p2`), and stopped resolving after a restart. A move within one workspace keeps the id.
- **A move within one tab does nothing:** `changed:false, reason:"same_tab"`. To reposition inside a tab, use `pane swap`, or move the pane to a scratch tab and back.
- **The CLI `pane move` focuses the moved pane.** The snapshot focus changed to `w1:p4`, then to `w2:p2`. The CLI has no `--no-focus` flag. The socket `pane.move` with `focus:false` left focus where it was. `pane swap` (CLI) also moved focus to the swapped pane.
- **Moving the last pane out of a tab closes that tab:** `closed_tab_id:"w1:t2"`.

## Step 3: ids across a server stop and restart (isolated server only)

Stopped with `server.stop` on the isolated socket, then restarted with the same command.

| Thing | Before | After restart |
|---|---|---|
| workspaces | w1 spikeA, w2 spikeB | w1 spikeA, w2 spikeB |
| tabs | w1:t3, w2:t2 | w1:t3, w2:t2 |
| pane ids | w1:p6, w2:p3, w2:p4, w2:p5 | same |
| layout tree | `right(p3, down(p4,p5))` | same |
| terminal_id | term_65b70cfc265117 … | **all new** (term_65b70d5985d7a1 …) |
| processes | sleep 20099 in w1:p6 | **gone**; fresh zsh in the saved cwd |
| agent state | claude done/idle/blocked/unknown | **agent None, status unknown** |
| alias `w1:p7` (moved to w2:p5) | resolved | `pane_not_found` |

Ids are not reused. The next pane in w1 was `w1:p8`. After `workspace close w1` the next workspace was `w3`. The `number` field is display order (w3 had number 2); do not key on it.

**Conclusion.** Workspace, tab and pane ids survive a restart. `terminal_id` survives a move, not a restart. `pane_id` survives a restart, not a move to another workspace. The ledger should store both. Match on `pane_id` and fall back to `terminal_id`, and take the new `pane_id` from `move_result.pane.pane_id` after every move the board makes. Right after a restart, no pane has a detected agent. KTD3's "any detected agent" protection is therefore empty until herdr re-detects, and a sync in that window must treat every pane as in use.

## Step 4: focus and agent status in `herdr api snapshot`

Agent state was set with `pane report-agent --source u1spike --agent claude --state …`. No real agent ran, so screen-based detection is unverified.

```
focused: w2 w2:t2 w2:p3                       (snapshot.focused_workspace_id / _tab_id / _pane_id)
pane w1:p6 focused=False agent=claude status=done      (working -> idle while unfocused)
pane w1:p7 focused=False agent=claude status=unknown
pane w2:p3 focused=True  agent=claude status=idle      (working -> idle while focused)
pane w2:p4 focused=False agent=claude status=blocked
tab  w2:t2 focused=True  agent_status=blocked          (aggregate: blocked beat idle)
layout w2:t2 focused_pane_id=w2:p3
```

- Focus appears in three places that agreed: `snapshot.focused_pane_id`, `panes[].focused`, and `layouts[].focused_pane_id` (per tab).
- `report-agent` accepts only idle, working, blocked and unknown. The server derives `done` from working→idle on an unfocused pane. The same change on the focused pane shows `idle`.
- A pane with no agent also shows `agent_status:"unknown"`, with no `agent` field. "No agent" and "agent, unknown state" differ only by `agent` being null versus set, or by the pane appearing in `snapshot.agents[]`. KTD3 must test `agent`, not the status.
- `release-agent` left `agent=claude, status=unknown`; the pane stayed in `agents[]`.

## Step 5: column and row membership

The tab was built as two columns of two rows: `w1:p1`/`w1:p3` in column 1, `w1:p2`/`w1:p4` in column 2. The tree comes from `layout.export {"tab_id"}`. The rects come from `pane layout`, which returns the same data as `snapshot.layouts[]`.

| After | `layout.export` tree | Rects |
|---|---|---|
| build | `right .5 ( down .5 (p1,p3), down .5 (p2,p4) )` | aligned 60×20 grid |
| same-tab `pane move p3 → below p4` | unchanged (`reason: same_tab`) | unchanged |
| `pane swap p3 ↔ p2` (the drag stand-in) | `right ( down (p1,p2), down (p3,p4) )` | aligned |
| resize p1 right 0.2 | `right .70 (…)`; membership unchanged | widths 84/36 |
| resize p1 down 0.15 | column 1 `down .65`; column 2 `down .5` | column 1 row boundary at y=26, column 2 at y=20: rows no longer line up |
| close p1 | `right ( pane p2, down (p3,p4) )` | p2 is 84×40 |
| close p2 | `down (p3,p4)`, root direction flipped | 120×20 each |
| move w2:p6 right of w2:p4 | `right ( p3, down ( right (p4,p6), p5 ) )` | x = 0, 60, 90 reads as three columns |

**Conclusion.** Membership reads exactly from the tree when the tree has one fixed shape. The root is a chain of `right` splits, and each chain member is a column. Each column is a chain of `down` splits or a single pane, and each member is a row. Flatten same-direction chains, because herdr trees are binary. Resizes change only ratios, so they never change membership.

Ambiguous cases, all seen above:
- **A collapse.** Closing `p1` leaves `p2` as a bare pane with no row position. Closing the whole first column turns the root into `down`, so the tab reads as one column, and column indexes shift for every remaining pane. Position alone cannot tell this from a person's move. KTD4's rule, that a tab which lost a pane since the last sync gives a conflict question, is required.
- **A column with fewer panes than rows.** A single pane in a column cannot say which row it belongs to. Row membership is unambiguous only if every row cell exists in every column. The board must keep that true (for example, one anchor pane per empty cell) or refuse to read rows for that column.
- **An off-grid drop.** A `right` split nested under a column's `down` split does not fit the shape. The rects make it worse: they read as three columns.
- **Rects are not a membership source.** After an uneven resize, row boundaries differ between columns.

Rule for U7/KTD4: read membership only from `layout.export`. A tree that is not the canonical shape, or a tab with fewer panes than its row cells, gives a conflict question and never a write-back.

**Unverified:** a drag in the herdr TUI. Only the API `pane move` and `pane swap` ran. Whether a TUI drag within a tab swaps panes or rebuilds the tree is unknown, and the rule above covers either result.

## KTD5 decision

**Chained `pane move --split --target-pane`.** Reason: `layout.apply` kills every process in the target tab and ignores `pane_id` (step 1). `pane move` keeps the process, cwd and `terminal_id` (step 2).

Constraints U7 must design around:
1. Call `pane.move` over the socket with `focus:false`. The CLI verb steals focus, and a sync must never move the pane a person is typing in (KTD3). The python3 socket client with an injectable socket path, specified in KTD5 for the other branch, is therefore needed on this branch too.
2. Same-tab moves do nothing. To reorder inside a tab, use `pane swap` (which also moves focus; test whether the socket form takes `focus:false`) or move out to a scratch tab and back.
3. After each move, record the new `pane_id` from `move_result`. A move to another workspace renames the pane.
4. A move that empties a tab closes it (`closed_tab_id`). Build the target tab before emptying the source.

## KTD11 pane cap

Linear does not limit the cap. herdr cost does not either. Measured on a second isolated session (`u1spike2`), socket calls, 16 panes:

```
pane.split 21.7 ms/pane   pane.move 2.3 ms/pane   session snapshot 9.2 ms   layout.export 18.9 ms
CLI `herdr api snapshot` 29 ms   CLI `pane get` 31 ms
```

Placing 16 panes costs about 16 × (21.7 + 2.3) ms ≈ 0.4 s, plus a shell start per pane. A Linear sync costs 1 to 4 requests, whatever the pane count.

The cap is therefore an attention limit: how many new panes one person can review after an unattended sync. Arithmetic from the measured default area (120 × 40 cells), with a minimum readable pane of 30 × 10 cells: 120/30 = 4 columns × 40/10 = 4 rows = **16 panes, one tab's worth**. Proposed cap: **16 panes created per unattended sync**. Record the rest as one pending question (KTD11). For comparison, the real filter below returned 162 issues, ten times the cap.

## Step 6: one paginated read of a real filter

The read went through the plugin's own client (`herdr_linear::query`, key on curl stdin). `HERDR_LINEAR_CURL_BIN` pointed at a wrapper that adds only `-D <file>`, which dumps response headers. A guard refused any body whose query did not start with `query` or that contained `mutation`.

Filter: `{"assignee":{"isMe":{"eq":true}},"state":{"type":{"nin":["completed","canceled","triage","backlog"]}}}`. Selection: id, identifier, title, updatedAt, priority, state, team, project, projectMilestone, cycle, parent, assignee, `labels(first:20){nodes{id name parent{id name}}}`, and `pageInfo`.

```
first:50   page 1: 50 nodes X-Complexity 15 0.85s | p2: 50 15 0.54s | p3: 50 15 1.03s | p4: 12 15 0.64s
           TOTAL pages=4 requests=4 issues=162 complexity=60 secs=3.57 hasNextPage=False
first:250  TOTAL pages=1 requests=1 issues=162 complexity=15 secs=1.09
wide filter (state not completed/canceled, all teams), first:250, capped at 4 pages:
           4 × 250 nodes, X-Complexity 15 each, 4.76 s, hasNextPage=True
headers:   x-ratelimit-requests-limit 2500, x-ratelimit-complexity-limit 3000000
```

Observed `X-Complexity` was 15 at both page sizes. The documented formula gives far more: 0.1 per property, 1 per object, and connections multiplied by `first`, which comes to about 58 points per issue with `labels(first:20)`, or about 14,500 at `first:250`. The server accepted the query and reported 15. These notes record the observed figure and do not rely on the formula. To stay under the documented 10,000-per-query cap even by the formula, use `first:50` pages and `labels(first:10)`: about 34 × 50 ≈ 1,700 points.

Extrapolation for one working day (8 h), with generous assumptions: 40 `/work` commands and 40 Linear writes give 80 syncs a day, with a peak of 25 in one hour. Each sync makes 4 filter pages at `first:50` plus up to 4 supporting reads (states, label groups, projects/milestones, cycles), so 8 requests.
- Requests: 25 × 8 = 200 per peak hour, 8% of 2,500. The ceiling is 2,500 / 8 ≈ 312 syncs an hour.
- Complexity, observed: 25 × 8 × 15 ≈ 3,000 per hour, 0.1% of 3,000,000.
- Complexity, by the documented formula (worst case): about 8 × 1,700 ≈ 14,000 per sync × 25 ≈ 340,000 per hour, 11%.
- Caveat: the budget belongs to the API key, and other tools and sessions using the same key share it. The client already retries on `RATELIMITED`, and a read that stops early must not change membership (KTD9).

## Step 7: schema introspection (read only)

`__type` queries, `X-Complexity` 18 and 7.

```
IssueUpdateInput.projectMilestoneId  String         "The project milestone associated with the issue."
IssueUpdateInput.cycleId             String
IssueUpdateInput.addedLabelIds       [String!]      "…labels to be added to this issue."
IssueUpdateInput.removedLabelIds     [String!]      "…labels to be removed from this issue."
IssueUpdateInput.labelIds / teamId / projectId / parentId / stateId / assigneeId   present
IssueUpdateInput deprecated (includeDeprecated:true): boardOrder -> "use sortOrder instead" (only one)
IssueFilter: assignee, state, team, project, projectMilestone, cycle, labels, parent, id, and, or - present, none deprecated
Issue.previousIdentifiers  "Previous identifiers of the issue if it has been moved between teams."
IssueLabel.isGroup  "When true, this label acts as a container for child labels and cannot be directly applied"
IssueLabel.parent, IssueLabel.children present
```

The deprecations page (https://linear.app/developers/deprecations) currently lists policy only: `@deprecated` in the schema and `[API]` changelog entries. It lists no dated deprecations. The schema's only deprecated issue-write field is `boardOrder`, which the board does not use.

**Conclusion.** Every field KTD10 needs exists and none is deprecated. `Issue.previousIdentifiers` confirms that a team move changes the identifier.

## Step 8: questions that need a write to answer (open)

| Question | Defensive rule the code applies |
|---|---|
| Does Linear refuse, or silently accept, a second label from the same label group? | Read `labels{nodes{id parent{id isGroup}}}` in the filter read. Never send a group label (`isGroup:true`). When setting a label from a group, send the old sibling in `removedLabelIds` and the new one in `addedLabelIds` in the same `issueUpdate`. Re-read after the write, and treat two labels from one group as a conflict question. |
| Does Linear accept a milestone from another project? | Refuse before sending unless the milestone's `project.id` equals the issue's current project, or the `projectId` sent in the same update. Send `projectMilestoneId` with `projectId` when both change, and read `success` and the resulting `projectMilestone.project.id`. |
| Does a team move renumber the identifier (and move state, cycle or labels)? | Key every record by issue `id` (KTD1). Treat `identifier` as display text that can change, and show `previousIdentifiers` when it has. After a team write, re-read state, cycle and team-scoped labels before recording ledger values, because the old team's state and cycle ids do not exist in the new team. |

## What was touched

- Linear: queries only (viewer, 3 filter reads, 2 introspection queries). The guard refused any body containing `mutation`. Sourcing `linear.sh` updated `~/.claude/linear-cache/_plaintext_fallback_used` (timestamp 14:51 local): the credential came from the pre-migration plaintext copy, and the client records that.
- herdr: all mutations ran on sessions `u1spike` and `u1spike2`. Both were stopped through their own sockets and deleted (`deleted session u1spike`, exit 0). Afterwards `herdr session list` showed only `default`, `~/.config/herdr/sessions/` was empty, the isolated socket file did not exist, and the live `herdr status` still showed `running ~/.config/herdr/herdr.sock`.
