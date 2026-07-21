#!/usr/bin/env bats
# U8 — crisp per-round predicates (isEmptyRound / escalates / dedupeVsSeen).
# Runs predicates.js under bare node via the harness (bats→node, KTD4 import-safety).

H="$BATS_TEST_DIRNAME/predicates.harness.mjs"
run_case() { ( cd "$BATS_TEST_DIRNAME" && node "$H" "$1" ); }

@test "isEmptyRound: empty round -> true" { run_case empty_true; }
@test "isEmptyRound: non-empty round -> false" { run_case empty_false; }

@test "escalates: same class 3 consecutive rounds -> true" { run_case escalate_true; }
@test "escalates: 2 rounds -> false" { run_case escalate_two_false; }
@test "escalates: non-consecutive -> false" { run_case escalate_nonconsec_false; }
@test "escalates: different classes each round -> false" { run_case escalate_diff_false; }

@test "dedupeVsSeen: already-seen finding dropped" { run_case dedup_drops_seen; }
@test "dedupeVsSeen: distinct findings of same class both kept" { run_case dedup_keeps_new_same_class; }

@test "classKey: unknown defect-category rejected (closed enum)" { run_case enum_reject; }

@test "pipeline: identical recurring finding does NOT escalate" { run_case pipeline_identical_no_escalate; }
@test "pipeline: new findings of same class 3 rounds DO escalate" { run_case pipeline_newsameclass_escalate; }
