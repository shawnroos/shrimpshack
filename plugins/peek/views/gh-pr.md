---
type: gh-pr
match: { record: gh-pr }
props:
  title:  { kind: text, required: true }
  status: { kind: choice, values: [open, draft, merged, closed] }
  body:   { kind: text }
  ciTone: { kind: choice, values: [bad, wait, ok, none] }
icons:
  state: 󰝥
  author: 󰀄
  branch: 󰘬
  review: 󰈈
  merge-state: 
  assignees: 󰡉
  labels: 󰓹
  milestone: 󰓾
  created: 󰃳
  updated: 󰥔
  merged: 
  closed: 󰃲
colors:
  ciTone: { bad: red, wait: yellow, ok: green, none: gray }
---
```peek-header from=title
```

```peek-fields from=meta title=Details icon=kind detail=status color=kind
```

```peek-fields from=stats title=Changes icon=gh-pr color=green
```

```peek-media from=body title=Description
```

```peek-comments from=comments title=Comments
```
