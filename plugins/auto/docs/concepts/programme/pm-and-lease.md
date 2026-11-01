# PM and lease

The PM is the one session allowed to write to the programme. The lease names that session. A takeover or handover moves the lease; a session without it is refused with a `become-pm` fix.

- **Where it lives:** `lib/programme_lifecycle.py`
- **Note:** Subagents inherit the session id, so a hook stops them from running write verbs.
