# Ritual

A named workflow the PM runs when a calendar rule ("every Monday") or a programme moment (start, end, handover, takeover, resume after a gap, going quiet) fires. Where a Behaviour answers an item change, a ritual answers the clock or a whole-programme moment. Rituals live in the same three layers as Behaviours (programme, repo, personal). A ritual the PM could not run is offered to Shawn once, in one picker, at the next sweep; it is never dropped and never run silently late.

- **Where it lives:** `docs/contracts/programme-rituals-format.md`, `lib/programme_rituals.py`, `lib/programme_rituals_due.py`
- **Note:** New or retired rituals need Shawn's answer to an offer. Each programme keeps its own next-due time, so a Monday ritual set once at the personal layer runs in every programme.
