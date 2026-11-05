---
when: an Auto limit (not Claude Code) refuses a command
trigger: start
applies_to: workers
why: A Claude Code denial stays with Claude Code's normal handling.
---
Do:
- Keep working on the rest; the PM sees the refusal.
Don't:
- Do not retry it, or try it through another tool, wrapper or worker.
