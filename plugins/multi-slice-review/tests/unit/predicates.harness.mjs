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

const f = (id, defectCategory = 'correctness', severity = 'P1', slice = 's1', lens = 'correctness') =>
  ({ id, slice, lens, defectCategory, severity });

const assert = (cond, msg) => { if (!cond) { console.error('FAIL: ' + msg); process.exit(1); } };

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

  enum_reject: () => {
    let threw = false;
    try { classKey(f('a', 'not-a-category')); } catch { threw = true; }
    assert(threw, 'unknown defect-category is rejected');
  },

  // Pipeline: the SAME finding recurring unfixed must NOT escalate — dedup drops
  // it after round 1, so it never reaches the class history 3x.
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
  // Pipeline: genuinely NEW findings of the same class 3 rounds running DO escalate.
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
};

const name = process.argv[2];
if (!cases[name]) { console.error('unknown case: ' + name); process.exit(2); }
cases[name]();
process.exit(0);
