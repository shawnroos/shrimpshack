---
authors: Claude
type: options-note
project: shrimpshack/auto
topics: rituals, check-command, repo-rituals, pm-downtime
---

# Rituals: two choices for Shawn, and how often the PM was quiet

Context: PR #192 (rituals name what they refuse, take offers, report when they first run). Nothing below is built.

## 1. Should a ritual carry its own check?

Today the daily "versions bumped" check is written as steps. The PM reads them, runs git by hand and decides whether to speak, every day, even when all is fine.

- **A. A check that runs by itself (recommended).** Shawn picks a check from a short fixed list. The system runs it on schedule and wakes the PM only when it finds a problem. It can run only checks from the list, and adding one needs Shawn's typed words. Most to build.
- **B. A command Shawn writes, run by the PM.** Any check works, but the PM still spends one turn a day, and each command needs Shawn's typed words and must pass the worker-command safety rules.
- **C. Steps only.** Nothing to build. The daily turn stays.

Recommendation: A. Start with one check, "versions bumped".

## 2. Should a repo's ritual travel with the repo?

Checked: it does not. `move-ritual --to repo` saves into a machine-wide file (`rituals.json` beside the personal protocol), keyed by repo name. A fresh clone or another machine has nothing.

- **A. Read rituals from a file inside the repo (recommended).** Shrimpshack's "check plugin versions" ritual would ship with shrimpshack. A repo file then holds instructions the PM follows, so changes to it need review like code.
- **B. Keep the machine file.** No change. Repo rituals work only where Shawn recorded them.
- **C. Export and import by hand.** Safer than A, easy to forget.

Recommendation: A, after choice 1, because a shipped check and a shipped ritual belong together.

## 3. How often was the PM down for over an hour?

The journal has no heartbeat. The closest signal is PM actions (reads claims, checks evidence, admits an operation, decides, marks an item waiting, shows recommendations, sends a prompt). Gaps between those rows over the last 7 days, counts only:

| Programme | PM action rows | Gaps over 1 hour | Starting 08:00 to 22:00 local | Longest gap |
|---|---|---|---|---|
| prog-20261028-130241-d8b9d6 (this week's) | 177 | 19 | 16 | 26.7 h |
| prog-20261018-102220-10892e (older) | 445 | 22 | 19 | 22.4 h |

**This is not a miss rate.** A quiet gap means the PM wrote nothing. It does not show the session was down: a PM waiting on workers or on Shawn also writes nothing. So the real miss rate is not known from journals. To measure it, the programme needs to record when the PM session starts and stops (or a heartbeat row at each sweep). A daily 09:00 ritual that lands in a quiet gap is still offered at the next sweep, as designed.

Decision for Shawn: add a heartbeat row so the next report can give a real number (small change), or accept the "offered at the next sweep" rule without measuring.
