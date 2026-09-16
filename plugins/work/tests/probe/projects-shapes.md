# Project membership probe — query shapes, 2026-09-16

Hand-written, not captured (KTD18). The probe ran read-only against
api.linear.app through `herdr_linear::query`, so the key went to curl on
stdin. Nothing it answered is in this file: no ids, no names, no cursors, no
counts. What is here is the query text, the variable types and the refusal
messages, which are what `herdr_linear::my_projects` and the `projects(` arm of
`tests/fixtures/fake-linear.sh` depend on.

## Introspection

### `Query.projects`

```
projects(filter:ProjectFilter  before:String  after:String  first:Int  last:Int
         includeArchived:Boolean  orderBy:PaginationOrderBy):ProjectConnection
```

### `ProjectFilter` (the field this plugin uses)

```
members:UserCollectionFilter
```

### `UserCollectionFilter` and `UserFilter` (the fields this plugin uses)

```
UserCollectionFilter  some:UserFilter  every:UserFilter  isMe:BooleanComparator
UserFilter            isMe:BooleanComparator
```

`isMe` is a boolean comparison, so the filter names no user id and needs no
`ID` variable. `User` has no projects field; the membership is only reachable
as a filter on `projects`.

### `Project` (the fields this plugin reads)

```
id:ID!  name:String!  teams(first:Int ...):TeamConnection!
```

Every project the probe listed carried at least one team.

## The read

```
query($n:Int,$after:String,$filter:ProjectFilter){
  projects(first:$n,after:$after,filter:$filter){
    nodes{id name teams(first:1){nodes{key}}}
    pageInfo{hasNextPage endCursor}
  }
}
```

Variables:

```
{"n": <Int>, "after": <String, omitted on the first page>,
 "filter": {"members": {"some": {"isMe": {"eq": true}}}}}
```

The filtered list was a strict subset of the unfiltered one, and every project
it returned was also in the unfiltered list, so the filter selects membership
rather than widening or re-ranking.

## Refusals observed

A wrong variable type is refused before the query runs, with no `data` key,
code `GRAPHQL_VALIDATION_FAILED`:

```
Variable "$filter" of type "IssueFilter" used in position expecting type "ProjectFilter".
Variable "$n" of type "String" used in position expecting type "Int".
```

`herdr_linear::query` maps that code to unavailable, so a wrong type reads as an
outage. The fake answers the same two messages.
