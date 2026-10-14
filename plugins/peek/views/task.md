---
type: task
match: { folder: .peek/tasks, prop: isTask, equals: true }
props:
  id:          { kind: text, required: true }
  status:      { kind: choice, values: [todo, doing, done, cancelled], required: true }
  creator:     { kind: text, required: true }
  parent:      { kind: ref }
  sequence:    { kind: ref }
  due:         { kind: date }
  attachments: { kind: links }
requires_when: { isTask: true, all: true }
layout_default: { page: tree, group: list }
---
# {{name}}

| Prop | Value |
|---|---|
| Status | {{status}} |
| Created by | {{creator}} |
| Due | {{due}} |
| Parent | {{parent}} |
| Attachments | {{attachments}} |

{{description}}

## Children

```peek-tree ancestors={{id}}
```

## Sequence

```peek-list neighbours={{id}}
```
