# CustomView probe — transcript, 2026-09-14

Captured by `tests/probe/customviews.sh` (read arms only) against
api.linear.app. Every id, name and cursor below is a same-shaped synthetic
value; the field names and the shapes are what the API answered. The create
arm was not run.

## Introspection

### `CustomView` (the fields this plugin reads)

```
id:ID!  name:String!  archivedAt:DateTime  modelName:String!
filterData:JSONObject!  projectFilterData:JSONObject  shared:Boolean!
viewPreferencesValues:ViewPreferencesValues
userViewPreferences:ViewPreferences  organizationViewPreferences:ViewPreferences
```

`modelName` is `Issue` or `Project`. There is no project field on an issue
view; the project is named only inside `filterData` (KTD12).

### `ViewPreferencesValues` (the layout fields; the type has ~250 others)

```
layout:String  issueGrouping:String  issueSubGrouping:String
columnOrderBoard:[String!]  hiddenColumns:[String!]  showEmptyGroupsBoard:Boolean
```

`columnOrderBoard` and `hiddenColumns` are nullable lists. On every view the
probe saw, `columnOrderBoard` was `null`; `hiddenColumns` was `null`, `[]`, or
a list of workflow-state ids. `lib/linear.sh` reads a null list as empty.

### `CustomViewCreateInput`

```
id:String  name:String!  description:String  icon:String  color:String
teamId:String  projectId:String  initiativeId:String  ownerId:String
filterData:IssueFilter  projectFilterData:ProjectFilter
initiativeFilterData:InitiativeFilter  feedItemFilterData:FeedItemFilter
shared:Boolean
```

**There is no `modelName` input.** The plan's sketch carried one; the model
follows from which filter field is set. `filterData` is typed `IssueFilter`,
so the create sends `{"project":{"id":{"in":[P]}}}` there.

### `ViewPreferencesCreateInput`

```
id:String  type:ViewPreferencesType!  viewType:ViewType!  preferences:JSONObject!
insights:JSONObject  teamId:String  projectId:String  initiativeId:String
labelId:String  projectLabelId:String  initiativeLabelId:String
releasePipelineId:String  customViewId:String  userId:String
```

`viewType` is required and the plan's sketch omitted it. `preferences` is a
plain JSON object, not a typed input: `ViewPreferencesValuesInput` does not
exist. `ViewPreferencesType` is `organization | user`. `ViewType` carries
`customView` among some seventy values. So the create sends
`{type:"user", viewType:"customView", customViewId, preferences:{layout:"board", issueGrouping:"workflowState"}}`.

### Payloads and mutations

```
CustomViewPayload       { lastSyncId:Float!  customView:CustomView!  success:Boolean! }
ViewPreferencesPayload  { lastSyncId:Float!  viewPreferences:ViewPreferences!  success:Boolean! }
ViewPreferences         { id  type:String!  viewType:String!  preferences:ViewPreferencesValues! ... }

customViewCreate(input: CustomViewCreateInput!)
customViewUpdate(input: CustomViewUpdateInput!, id: String!)
customViewDelete(id: String!)
viewPreferencesCreate(input: ViewPreferencesCreateInput!)
viewPreferencesUpdate(input: ViewPreferencesUpdateInput!, id: String!)
```

## `customViews(first:50)` — the filterData forms Linear saves

Every view built in the UI arrives wrapped: `{"and":[ ...clauses... ]}`. Forms
seen, redacted:

```json
{"and":[{"project":{"id":{"in":["44444444-4444-4444-8444-444444444444"]}}}]}
{"and":[{"project":{"id":{"in":["44444444-4444-4444-8444-444444444444","99999999-9999-4999-8999-999999999999"]}}},
        {"labels":{"or":[{"or":[{"name":{"eq":"Feature"}},{"parent":{"name":{"eq":"Feature"}}}]}]}}]}
{"and":[{"project":{"initiatives":{"or":[{"id":{"eq":"iiiiiiii-iiii-4iii-8iii-iiiiiiiiiiii"}}]}}},
        {"priority":{"in":[1,2,3,4]}}]}
{"and":[{"assignee":{"or":[{"isMe":{"eq":true}}]}}]}
{"and":[{"team":{"id":{"in":["55555555-5555-4555-8555-555555555555"]}}},{"state":{"name":{"in":["Dev Done"]}}}]}
{"and":[{"labels":{"and":[{"or":[{"name":{"eq":"a label"}},{"parent":{"name":{"eq":"a label"}}}]}]}}]}
{"and":[{"dueDate":{"gte":"P0D"}},{"dueDate":{"lte":"P1W"}}]}
{}
```

So the matcher in `herdr_linear::project_views` walks `and`/`or` lists and
matches a `project` clause only when it carries `id` with `eq` or `in`. The
third form, `project.initiatives`, names no project and does not match. A
`Project`-model view carries `{}`.

Every Issue view answered `issueGrouping: "workflowState"` except one grouped by
`assignee`; `layout` was `list` or `board`. The connection paged with
`pageInfo{hasNextPage endCursor}`; `endCursor` is the last node's id.

```json
{"data":{"customViews":{"nodes":[
  {"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","name":"Canvas board","modelName":"Issue","archivedAt":null,
   "filterData":{"and":[{"project":{"id":{"in":["44444444-4444-4444-8444-444444444444"]}}}]},
   "viewPreferencesValues":{"layout":"list","issueGrouping":"workflowState","columnOrderBoard":null,"hiddenColumns":null}},
  {"id":"c5c5c5c5-c5c5-4c5c-8c5c-c5c5c5c5c5c5","name":"All projects","modelName":"Project","archivedAt":null,"filterData":{}}
 ],"pageInfo":{"hasNextPage":true,"endCursor":"c5c5c5c5-c5c5-4c5c-8c5c-c5c5c5c5c5c5"}}}}
```

## `customView(id:)` with `viewPreferencesValues`

```json
{"data":{"customView":{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","name":"Canvas board","modelName":"Issue",
  "archivedAt":null,"filterData":{"and":[{"project":{"id":{"in":["44444444-4444-4444-8444-444444444444"]}}}]},
  "viewPreferencesValues":{"layout":"list","issueGrouping":"workflowState","columnOrderBoard":null,"hiddenColumns":null}}}}
```

A board-layout view with hidden columns answered
`"hiddenColumns":["st-devdone","st-done"]` (workflow-state ids) and still
`"columnOrderBoard":null`.

## `issues(first:3, filter: <a view's filterData, unchanged>)`

The wrapped `{"and":[...]}` object is accepted as an `IssueFilter` variable
as-is. A project filter alone admits completed issues, which is why
`project_issues` adds `state.type.neq canceled` only and a view's own filter
is passed through untouched.

```json
{"data":{"issues":{"nodes":[
  {"identifier":"WEB-3310","state":{"name":"Dev Done","type":"started"}},
  {"identifier":"WEB-3303","state":{"name":"Done","type":"completed"}},
  {"identifier":"WEB-3252","state":{"name":"Dev Done","type":"started"}}],
 "pageInfo":{"hasNextPage":true,"endCursor":"13131313-1313-4131-8131-131313131313"}}}}
```

## `customView(id:)` on an unknown id

The same shape as an unknown issue: `errors[]` beside `"data": null`, code
`INPUT_ERROR`, which `herdr_linear::query` already maps to
`HERDR_LINEAR_NOT_FOUND`.

```json
{"errors":[{"message":"Entity not found: CustomView","path":["customView"],"locations":[{"line":1,"column":20}],
  "extensions":{"type":"invalid input","code":"INPUT_ERROR","statusCode":400,"userError":true,
  "userPresentableMessage":"Could not find referenced CustomView."}}],"data":null}
```

## Not captured

The create arm (`customViewCreate` then `viewPreferencesCreate`, then
`customViewDelete`) was not run. Its input field names come from the
introspection above; `tests/unit/linear.bats` pins the bodies `view_create`
sends against those names.
