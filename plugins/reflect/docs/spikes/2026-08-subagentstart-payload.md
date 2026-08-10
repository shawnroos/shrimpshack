# SubagentStart payload — can the hook see the subagent's task?

**NO-GO — the `SubagentStart` payload carries no task, prompt, or description text. It carries exactly two event fields: `agent_id` and `agent_type`.**

Spike: U8 (SubagentStart payload probe), plan `docs/plans/2026-08-07-001-feat-mid-session-memory-recall-plan.md`.
Date: 2026-08-07. Binary: Claude Code **2.1.224** (`~/.local/share/claude/versions/2.1.224`, Mach-O arm64).

## Method

Read the contract out of the running binary rather than observing it. No temporary hook was registered; no settings file was touched. Three independent sites in the same build were extracted and cross-checked:

1. the hook-input **constructor** (`executeSubagentStartHooks`, minified `wCn`),
2. the **Zod input schema** for the event (`FLv`) and the shared base schema (`wR`),
3. the **`HOOK_EVENT_REGISTRY`** entry, whose description string is the user-facing documentation of the event.

All three agree. Extraction was byte-offset reads of the binary via python; offsets are given per quote so any of this can be re-checked.

## Verbatim evidence

### 1. The constructor — every field the payload is built from

`@ 257249634`:

```js
async function*wCn(e,t,r,n=Hh,o){let i={...rh(void 0),hook_event_name:"SubagentStart",agent_id:e,agent_type:t};yield*y1({hookInput:i,toolUseID:pri.randomUUID(),matchQuery:t,signal:r,timeoutMs:n,getAppState:o})}
```

The object is a spread of the base input plus exactly `hook_event_name`, `agent_id`, `agent_type`. Nothing else is added.

### 2. The Zod input schema for the event

`@ 266445409`:

```js
FLv=ve(()=>wR().and(Te({hook_event_name:wt("SubagentStart"),agent_id:N(),agent_type:N()})))
```

For contrast, its sibling `SubagentStop` — which *does* carry more:

```js
BLv=ve(()=>wR().and(Te({hook_event_name:wt("SubagentStop"),stop_hook_active:Lt(),agent_id:N(),agent_transcript_path:N(),agent_type:N(),last_assistant_message:N().optional().describe("Text content of the last assi…
```

### 3. The event registry's own documentation

`@ 261891030`:

```js
SubagentStart:{summary:"When a subagent (Agent tool call) is started",description:`Input to command is JSON with agent_id and agent_type.
Exit code 0 - JSON additionalContext shown to subagent
Exit code 2 - show stderr to user only
Other exit codes - show stderr to user only`,matcherMetadata:{fieldToMatch:"agent_type",values:[]}}
```

### 4. The call site — the task text is in scope and deliberately not passed

`@ 254714726`. The spawn function destructures `description:R,name:P,toolUseId:O` and holds the seed messages, then invokes the hook with only the agent id and type:

```js
for await(let Jt of wCn(ie,e.agentType,tr.signal,void 0,r.getAppState)){…}
```

This is not an oversight of the extraction: the prompt/description are live locals at that line and are not forwarded.

## What the payload *does* carry

`hook_event_name`, `agent_id`, `agent_type`, plus the base fields shared by every hook (`rh` / `wR`).

Constructor, `@ 257263172`:

```js
function rh(e,t,r){let n=t??Mt(),o=r?.agentType??jU(),i=r?.options?.mainLoopModel,s=r?.getAppState?.().effortValue;for(let l of r?.permissionLayers??[])if(l.kind==="effort"&&l.effort!==void 0)s=l.effort;let a=i&&r?.getAppState&&dI(i)?{level:Hj(i,s)}:void 0;return{session_id:n,transcript_path:SM(n),cwd:Ft(),prompt_id:iMt()??void 0,permission_mode:e,agent_id:r?.agentId,agent_type:o,effort:a}}
```

Base schema, `@ 266439170`:

```js
wR=ve(()=>Te({session_id:N(),transcript_path:N(),cwd:N(),prompt_id:N().optional().describe("UUID correlating a user prompt with all subsequent events until the next prompt. Same value emitted on OpenTelemetry events as the `prompt.id` attribute, so hook output can be joined to OTel events at prompt grain. Absent until the first user input of the process lifetime."),permission_mode:N().optional(),agent_id:N().optional().describe("Subagent identifier. Present only when the hook fires from within a subagent (e.g., a tool called by an AgentTool worker). Absent for the main thread, even in --agent sessions. Use this field (not agent_type) to distinguish subagent calls from main-thread calls."),agent_type:N().optional().describe('Agent type name (e.g., "general-purpose", "code-reviewer"). Present when the hook fires from within a subagent (alongside agent_id), or on the main thread of a session started with --agent (without agent_id).'),effort:Te({level:N().describe('Active effort level for the current turn (e.g., "low", "medium", "high", "xhigh", "max"), after any silent downgrade for the selected model. Also exposed to hook commands and Bash as the CLAUDE_EFFORT env var.')}).optional().describe("Reasoning effort applied to the current turn. Same shape as StatusLineCommandInput.effort. Present for hooks that fire within a tool-use context (PreToolUse, PostToolUse, Stop, SubagentStop, etc.) on a model that suppor…
```

Note `SubagentStart` builds its base with `rh(void 0)` — no permission context and no agent context — so `permission_mode` is absent and base `agent_id`/`agent_type` are overwritten by the explicit ones. `effort` is likewise absent (it needs the agent-context argument `rh` was not given).

Practical upshot: a `SubagentStart` hook knows *which kind of agent* is starting and *which session* it belongs to. It does not know what the agent was asked to do.

## Injection back into the subagent does work

The one capability that is confirmed present: a SubagentStart hook can inject context into the subagent it fires for.

Output schema, `@ 248044394`:

```js
Te({hookEventName:wt("SubagentStart"),additionalContext:N().optional()})
```

Consumption, `@ 257269950`: `case"SubagentStart":u.additionalContext=e.hookSpecificOutput.additionalContext;break;`, and the call site wraps collected contexts in a `hook_additional_context` message pushed onto the subagent's seed messages. So injection is real — only the *query* is missing.

One matcher caveat, `@ 257315258`: for every other event the matcher is folded into the hook key as `Event:matcher`, but `SubagentStart` is special-cased to `return e` — the bare event name:

```js
case"SubagentStart":return e;
```

`matcherMetadata.fieldToMatch` for the event is `agent_type`, so matching on agent type in `hooks.json` still selects which hooks run; the special case only affects the key the hook is recorded under.

## Consequence for the plan

The subagent gap is **not** servable by a task-aware SubagentStart injection. Options that survive:

- **Agent-type-keyed recall.** The hook can inject memories relevant to the *kind* of agent starting (a reviewer gets review memories) — coarse, but real, and cheap.
- **The recall CLI being available to subagents** — the plan's existing fallback, unchanged by this finding.
- **Adjacent, unverified lead:** the task text is present in the *parent's* `PreToolUse` payload for the Agent tool (`tool_name` + `tool_input`, where the Agent tool's input carries `prompt`). That fires before the subagent exists and injects into the parent, not the child, so it is a different mechanism with a different injection target — worth its own probe if task-aware subagent recall is ever revived. `TaskCreated` similarly carries `task_subject` / `task_description` (`@ 266446787`), again in the parent.

Plan Open Question 4 ("SubagentStart GO case") resolves to **no**: seeded subagent recall keyed on the subagent's task is not plannable against 2.1.224.
