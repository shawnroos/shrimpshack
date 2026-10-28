# shrimpshack

## Token cost of compound-engineering runs

These three rules are advice, not enforced. The compound-engineering plugin has no setting for review depth, the number of parallel agents, or repeated reads, so nothing blocks a run that ignores them. Measure the effect with `plugins/auto/lib/token-cost.sh --ce <transcript>`.

1. **Match review depth to the size of the change.** A change under about 100 changed lines in one module gets `ce-doc-review` with the coherence and feasibility reviewers only, and `ce-code-review` with one correctness reviewer plus the reviewers its own rules require. Full multi-persona review is for larger or riskier changes.
2. **Run at most two heavy agents at once.** Three or more at a time hit the server rate limit. Queue the rest.
3. **Do not read a reference file or research dossier twice in one session, and do not carry a pipeline's reads in an orchestrating session.** Hand the reading to a short-lived agent that writes its result to a file and returns the path with a short summary. In the measured programme PM session, two thirds of tool-result bytes were reads of compound-engineering reference files (`docs/token-efficiency-findings.md`).

## Capping a programme PM's context

Run `/autocompact 180k` in the PM pane. It applies to the running session at once and is saved for later sessions. No hook or model can run it, so it needs one typed line from Shawn.
