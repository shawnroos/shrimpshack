# Ledger, verdicts and exit predicate

The ledger records what each step produced. A verdict says whether a step passed. The exit predicate is the condition that says the loop is done; the engine evaluates it and caches the result in the run record. The Stop hook reads that cached result and never re-evaluates it.

- **Where it lives:** `lib/ledger.py`, `lib/on-stop.py`
- **Note:** A goal doc (`/auto-author-goal`) states the same predicate in words so `/goal` can judge it.
