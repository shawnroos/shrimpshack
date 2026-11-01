# Run record

The file on disk that holds the state of one run: its steps, verdicts and the cached exit predicate. It is the source of truth, so a run survives a rate limit or a closed session.

- **Where it lives:** `docs/contracts/run-record-schema.md`
- **Note:** Resume reads it (`/auto-resume`). A programme is a second kind of run record with no steps.
