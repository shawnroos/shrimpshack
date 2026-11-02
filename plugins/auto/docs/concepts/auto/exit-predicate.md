# Verdicts and exit predicate

The run record keeps what each step produced. A verdict says whether a step passed. The exit predicate is the condition that says the loop is done; the engine evaluates it and caches the result in the run record. The Stop hook reads that cached result and never re-evaluates it.

- **Where it lives:** `lib/on-stop.py`
- **Note:** A goal doc (`/auto-author-goal`) states the same predicate in words so `/goal` can judge it.
