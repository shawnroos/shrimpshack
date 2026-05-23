---
allowed-tools: AskUserQuestion, Bash, Read
---

# /mode:setup-interactive

Interactive walkthrough of `/mode:setup` with confirmation gates at each
consequential step. Use this on first install when you want to **preview
what setup will move and seed** before it commits — especially the
user-catalog move (which physically relocates your `~/.claude/commands/*.md`
and `~/.claude/agents/*.md` into managed staging + symlinks back).

The non-interactive `/mode:setup` runs all 10 steps automatically; this one
asks before each consequential step:

- **S1** — already-installed check (cancel by default, force-reinstall is opt-in advanced).
- **S2** — pristine settings.json capture (default / preview / customize).
- **S3** — `_global.yaml` baseline preview (looks-good / show-full-list / override-identifier).
- **S5** — catalog move preview (move-all / pick-which / skip / cancel) — **the most valuable gate.**
- **S6** — seed example modes (discovery / delivery / skip).
- **S7** — V1 archive (only if V1 modes detected).
- **S8** — set an active mode now (discovery / delivery / skip / author new).

The skill at `.claude/skills/setup-interactive/SKILL.md` orchestrates the
existing `scripts/setup.sh` step functions; no shell logic is duplicated.

To dispatch (invokes the skill directly so the harness picks it up):

This command is just an entry point — the actual flow lives in the
`setup-interactive` skill. Trigger by saying "interactive setup" or
running this slash command; the harness will load the skill and walk
you through the phases.
