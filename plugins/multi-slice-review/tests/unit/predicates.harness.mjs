// Harness for predicates.bats — imports predicates.js under bare node and runs
// one named case. Exits 0 on pass, 1 on fail. (KTD4 import-safety.)
import {
  isEmptyRound,
  escalates,
  dedupeVsSeen,
  classKey,
  findingKey,
  newP1Classes,
} from '../../workflows/predicates.js';

// title defaults to `finding <id>` so a finding always has content identity.
const f = (id, defectCategory = 'correctness', severity = 'P1', slice = 's1', lens = 'correctness', title) =>
  ({ id, slice, lens, defectCategory, severity, title: title ?? `finding ${id}` });

const assert = (cond, msg) => { if (!cond) { console.error('FAIL: ' + msg); process.exit(1); } };
const throws = (fn) => { try { fn(); return false; } catch { return true; } };

const A = ['x'], B = ['y'], C = ['z'];

const cases = {
  empty_true: () => assert(isEmptyRound([]) === true, 'empty round is empty'),
  empty_false: () => assert(isEmptyRound([f('a')]) === false, 'non-empty round is not empty'),

  escalate_true: () => assert(escalates([A, A, A]) === true, '3 consecutive same class escalates'),
  escalate_two_false: () => assert(escalates([A, A]) === false, '2 rounds does not escalate'),
  escalate_nonconsec_false: () => assert(escalates([A, B, A]) === false, 'non-consecutive does not escalate'),
  escalate_diff_false: () => assert(escalates([A, B, C]) === false, 'different classes never escalate'),

  dedup_drops_seen: () => {
    const seen = [findingKey(f('a'))];
    const { kept } = dedupeVsSeen([f('a')], seen);
    assert(kept.length === 0, 'already-seen finding is dropped');
  },
  dedup_keeps_new_same_class: () => {
    const { kept } = dedupeVsSeen([f('a'), f('b')], []);
    assert(kept.length === 2, 'distinct findings of same class both kept');
    assert(classKey(kept[0]) === classKey(kept[1]), 'they share a class');
  },

  enum_reject: () => assert(throws(() => classKey(f('a', 'not-a-category'))), 'unknown defect-category is rejected'),

  pipeline_identical_no_escalate: () => {
    let seen = [];
    const history = [];
    for (let r = 0; r < 3; r++) {
      const round = dedupeVsSeen([f('x')], seen);
      seen = round.seen;
      history.push(newP1Classes(round.kept));
    }
    assert(escalates(history) === false, 'identical recurring finding does not escalate');
  },
  pipeline_newsameclass_escalate: () => {
    let seen = [];
    const history = [];
    const ids = ['x1', 'x2', 'x3'];
    for (let r = 0; r < 3; r++) {
      const round = dedupeVsSeen([f(ids[r])], seen);
      seen = round.seen;
      history.push(newP1Classes(round.kept));
    }
    assert(escalates(history) === true, 'new findings of same class 3 rounds escalate');
  },

  // --- U6-review regressions (added test-first) ---

  // P1 #4: two DIFFERENT findings (different title) that reuse the SAME id must
  // both survive dedup — ids are per-round-local, not globally unique.
  dedup_reused_id_kept: () => {
    const a = f('1', 'correctness', 'P1', 's1', 'correctness', 'the lock is never released');
    const b = f('1', 'correctness', 'P1', 's1', 'correctness', 'the socket is never closed');
    const { kept } = dedupeVsSeen([a], []);
    const round2 = dedupeVsSeen([b], kept.map(findingKey));
    assert(round2.kept.length === 1, 'a genuinely-new finding reusing an id is NOT dropped');
  },
  // P1 #4b: an id-less finding must not silently collapse all id-less findings to one key.
  finding_requires_id: () => assert(throws(() => findingKey(f(undefined, 'correctness', 'P1', 's1', 'correctness', 't'))), 'id-less finding is rejected'),

  // P1 #5: a malformed severity must be rejected, not silently skipped (which would
  // let a real P1 recurrence fail to escalate).
  severity_malformed_rejected: () => assert(throws(() => newP1Classes([f('a', 'correctness', 'p1')])), 'malformed severity rejected'),

  // Seam P2: classKey must validate lens too (asymmetric guard was the seam defect).
  classkey_validates_lens: () => assert(throws(() => classKey(f('a', 'correctness', 'P1', 's1', 'not-a-lens'))), 'unknown lens is rejected'),
};

const name = process.argv[2];
if (!cases[name]) { console.error('unknown case: ' + name); process.exit(2); }
cases[name]();
process.exit(0);
