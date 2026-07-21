// multi-slice-review — crisp per-round predicates (U8).
//
// Native-primitive-free ON PURPOSE: this module references no Workflow
// primitives at module scope, so tests can import() it under bare node
// (KTD4 import-safety). review.js (the Workflow entry) and the round command
// import these; the round command persists state across /loop iterations.
//
// Finding shape: { id, slice, lens, defectCategory, severity }  severity: P0|P1|P2|P3

export const DEFECT_CATEGORIES = Object.freeze([
  'correctness',
  'contract-mismatch',
  'resource-safety',
  'concurrency',
  'security',
  'missing-validation',
  'ordering',
]);

// The LENS vocabulary — kept in sync with rubric.sh (signal-core). classKey
// validates BOTH lens and defectCategory (symmetric guard) so a drifted/typo'd
// lens can't silently split the count-by-class escalation across variants.
export const LENSES = Object.freeze([
  'correctness', 'adversarial', 'security', 'reliability', 'api-contract',
]);

const SEVERITIES = Object.freeze(['P0', 'P1', 'P2', 'P3']);

const SEP = '|';

// A finding's escalation CLASS — deliberately NOT its literal identity.
// (A literal same-finding check never trips: each round's defect is "new".
// Counting by class is what catches one machinery generating fresh P1s.)
export function classKey(f) {
  if (!LENSES.includes(f.lens)) {
    throw new Error('unknown lens: ' + f.lens);
  }
  if (!DEFECT_CATEGORIES.includes(f.defectCategory)) {
    throw new Error('unknown defect-category: ' + f.defectCategory);
  }
  return [f.slice, f.lens, f.defectCategory].join(SEP);
}

// A finding's dedup identity — full enough that a genuinely new finding of the
// same class is NOT dropped, but an unfixed recurrence of the same one IS.
// Includes the title (content), because finding ids are per-round-local and get
// reused across rounds — id alone would collapse two different findings that
// happen to share a round-number id. id and title are both required, so an
// id-less finding can't silently collapse the whole set to one key.
export function findingKey(f) {
  if (!f.id) throw new Error('finding is missing an id');
  if (!f.title) throw new Error('finding is missing a title');
  return [f.slice, f.lens, f.defectCategory, f.id, f.title].join(SEP);
}

// Exit = an EMPTY round across all lenses — not a shrinking one. Keys only on
// the current round's fresh findings; it must never compare against a prior
// round's count.
export function isEmptyRound(findings) {
  if (!Array.isArray(findings)) throw new Error('isEmptyRound expects an array');
  return findings.length === 0;
}

// Drop findings already seen; return the kept (fresh) findings plus the grown
// seen-set. Dedup is vs `seen`, not vs confirmed — so a judge-rejected finding
// does not resurface next round and the loop converges.
export function dedupeVsSeen(fresh, seen = []) {
  const seenSet = new Set(seen);
  const kept = [];
  for (const f of fresh) {
    const k = findingKey(f);
    if (!seenSet.has(k)) {
      kept.push(f);
      seenSet.add(k);
    }
  }
  return { kept, seen: Array.from(seenSet) };
}

// Escalate when new P1s of the SAME class appear in 3 consecutive rounds.
// history: array (one entry per round) of arrays of classKeys that were NEW P1s
// that round. Returns true iff some class spans a run of >= 3 consecutive rounds.
export function escalates(history, threshold = 3) {
  const runs = new Map(); // classKey -> current consecutive-run length
  let tripped = false;
  for (const round of history) {
    const present = new Set(round);
    for (const key of present) {
      const n = (runs.get(key) || 0) + 1;
      runs.set(key, n);
      if (n >= threshold) tripped = true;
    }
    for (const key of runs.keys()) {
      if (!present.has(key)) runs.set(key, 0);
    }
  }
  return tripped;
}

// Build the per-round new-P1 class list from a round's fresh findings — the
// input escalates() consumes. Only P0/P1 count toward escalation.
export function newP1Classes(freshFindings) {
  // Validate severity against the closed set (fail-closed): a malformed severity
  // must be rejected loudly, not silently skipped — else a real P1 recurrence
  // fails to escalate.
  for (const f of freshFindings) {
    if (!SEVERITIES.includes(f.severity)) {
      throw new Error('unknown severity: ' + f.severity);
    }
  }
  return freshFindings
    .filter((f) => f.severity === 'P0' || f.severity === 'P1')
    .map(classKey);
}
