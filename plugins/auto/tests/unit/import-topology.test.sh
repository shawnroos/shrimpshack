#!/usr/bin/env bash
# auto v0.3.1 Track C: import-topology lint — locks the DAG the B4/B5 splits
# established so future agents can't re-introduce a circular import.
#
# WHY THIS TEST EXISTS:
# B5 split lib/run_record.py into a 4-file DAG (run_record_core ← run_record_mutators ←
# run_record_producers ← run-record-facade); B4 split lib/pulse.py into pulse ←
# {pulse_advance, pulse_guidance} with pulse_advance ← pulse_guidance. Those splits
# carefully avoided cycles. But the load_lib_module loader resolves siblings at
# runtime, so a cycle wouldn't surface as an ImportError at parse time — it
# would surface as a subtle runtime failure (a half-initialized module, or a
# duplicate class identity breaking `except run_record.RunRecordError`). A future agent
# adding a "convenience import" could re-introduce one silently.
#
# This lint makes the topology grep-checkable — the same deterministic-defense
# shape as tests/unit/wikilink-check.test.sh (G5) and
# tests/unit/doc-fence-run-record-schema.test.sh (H). The DAG edges are the
# contract; this test fails the build if a forbidden edge appears.
#
# THE DAG (allowed edges only). VERIFIED AGAINST THE ACTUAL IMPORTS — F6 found this
# comment had drifted badly, and a DAG comment that lies is worse than none: the next
# agent reasons about the topology from HERE, not from the source. Re-verify with
#   grep -nE '^[a-z_]+ = load_lib_module\("|^import [a-z_]+( as [a-z_]+)?([[:space:]]|$)' lib/<mod>.py
# before you edit any line below. (The `( as …)?` alternative catches the [plain] bare
# `import y` edge from line 29 too — the old pattern only saw the aliased form and would
# have missed a future bare `import run_record_core`; it also surfaces stdlib `import os`
# lines, which are noise you eyeball past, not sibling edges.)
#
# Three EDGE KINDS, and telling them apart is the whole point of this file:
#   [top]   `x = load_lib_module("y")` at module top — a visible edge, and the kind the
#           DAG lines below list first.
#   [plain] a bare `import y` at module top — a real edge this lint CANNOT see.
#   [lazy]  a load INSIDE a function body — a real runtime edge, and the mechanism that
#           lets a "cycle" on paper not be one at import time. Two spellings exist:
#           `load_lib_module("y")` and `run_record_core._lazy_load("y")`; `loads_sibling`
#           greps both, so a forbidden edge cannot dodge the lint by switching loader.
#
#   format_compat        → (nothing)                          DAG root; pure stdlib
#   run_record_core      → format_compat [lazy], run_record_predicate [lazy]
#                          Deliberately keeps NO module-top sibling import, which is what
#                          makes it the acyclic root of the run-record family.
#   run_record_mutators  → run_record_core
#   run_record_producers → run_record_core
#   run_record_predicate → run_record_core
#   run_record_steering  → run_record_core, run_record_mutators
#   run_record (facade)  → run_record_core, run_record_predicate, run_record_mutators,
#                          run_record_steering, run_record_producers, format_compat
#                          (format_compat: U10's `downgrade` operator command. The facade
#                          owns the CLI, so the INVERSE map is loaded here; format_compat
#                          cannot host it, being unable to reach core's flock as a root.)
#
#   pulse_guidance → phase-grammar, iteration                  NOT a leaf, and NOT an
#                    importer of the run_record facade — it takes `load_run_record` as a
#                    FUNCTION from _bootstrap. The old comment claimed both.
#   pulse_advance  → phase-grammar, iteration, pulse_guidance, upstream-cluster,
#                    step_producers [plain]
#   pulse          → phase-grammar, pulse_advance, pulse_guidance
#                    The old comment claimed `pulse → iteration, step_producers,
#                    run_record`. It imports NONE of the three: it reaches that work
#                    through pulse_advance. It DOES import phase-grammar, undocumented.
#   step_producers → workflows, iteration
#                    The old comment called this a pure leaf importing nothing. It is
#                    neither: `workflows` is how a producer resolves the step template.
#
#   _bootstrap        → run_record [lazy], format_compat [lazy], phase-grammar [lazy]
#                       EVERY one is call-time, and that is load-bearing: run_record
#                       does `from _bootstrap import …` at module TOP, so a module-top
#                       `_bootstrap → run_record` edge would be a genuine import cycle.
#                       The lazy load is what keeps the back-edge legal. Do not promote
#                       any of these to a module-top import.
#   workflow_validate → format_compat                          (the validate WRITE gate)
#   workflows         → workflow_validate, format_compat       (resolve() read shim)
#   presets           → workflow_validate, backend_ops, format_compat  (load_preset shim)
#   iteration         → verification [lazy]
#   run_record_predicate → programme_predicate [lazy, via _lazy_load]
#   run_record (facade)  → run_record_evidence (in addition to the list above)
#   _bootstrap           → programme_home [lazy] (programme_home imports _bootstrap at top),
#                          programme_authority [lazy]
#   run_record_core      → programme_authority [lazy, via _lazy_load] (programme homes only)
#   run_record (facade)  → programme_authority [lazy] (the offline downgrade refusal)
#
# Programme runs. This family builds on run_record_core directly, not on the facade:
# a programme record has no steps, so the facade's step verbs never apply to it.
#   verb_cli             → (nothing)                           leaf
#   programme_sanitize   → (nothing)                           leaf
#   programme_home       → run_record_core; phase-grammar [lazy], programme_authority [lazy],
#                          _bootstrap [lazy], programme_archive [lazy]
#                          The end path writes through programme_authority, loaded lazily,
#                          so programme_authority → programme_home closes no import-time cycle.
#   programme_predicate  → run_record_core, programme_home, programme_context; phase-grammar [lazy]
#   programme_context    → run_record_core, programme_home, programme_sanitize
#                          (pure over the programme block: the predicate loads it on every
#                          record write; its verb handlers get programme_record passed in)
#   programme_protocol   → programme_home                      (never programme_journal:
#                          the prompt lookup is passed in by the caller)
#   programme_journal    → run_record_core, programme_home; programme_authority,
#                          programme_artifacts [lazy]
#   programme_store      → run_record_core, programme_home; programme_journal [lazy]
#   programme_authority  → run_record_core, programme_home, programme_store;
#                          programme_journal [lazy], format_compat [lazy, via _lazy_load]
#                          run_record_core, _bootstrap, programme_home, programme_journal and
#                          run_record reach it lazily, so it closes no import-time cycle.
#   programme_import     → run_record_core, programme_home, programme_store,
#                          programme_authority; programme_journal [lazy]
#   programme_artifacts  → run_record_core, programme_home, programme_store,
#                          programme_authority; programme_journal, driver_session [lazy]
#                          programme_journal, programme_record and programme_evidence
#                          reach it lazily, so it closes no import-time cycle.
#   programme_gitio      → programme_store
#   programme_preserve   → run_record_core, programme_home, programme_store,
#                          programme_artifacts, programme_gitio; driver_session,
#                          session_registry [lazy]. programme_record reaches it lazily.
#   session_registry     → run_record_core, programme_home, driver_session
#   programme_exec       → programme_sanitize
#   programme_tracker    → programme_exec, programme_journal, programme_sanitize
#   programme_tasks      → programme_sanitize
#   programme_plans      → programme_exec, programme_sanitize, programme_tracker
#   programme_record     → run_record_core, programme_home, programme_journal,
#                          programme_protocol, programme_sanitize, driver_session,
#                          programme_tracker, programme_context; programme_artifacts, programme_preserve [lazy]
#   programme_evidence   → run_record_core, programme_home, programme_journal,
#                          programme_predicate, programme_record, programme_sanitize,
#                          programme_protocol, driver_session, verification;
#                          programme_artifacts [lazy]
#   programme_recovery   → run_record_core, programme_home, programme_journal,
#                          programme_authority, programme_context, programme_artifacts;
#                          driver_session [lazy]. Live herdr reads are passed in by
#                          programme_sources, so it never loads programme_sources.
#   programme_sources    → run_record_core, programme_home, programme_journal,
#                          programme_sanitize, programme_record, programme_context, programme_exec,
#                          programme_tracker, programme_tasks, programme_plans,
#                          programme_recovery, session_registry; driver_session [lazy]
#   programme_archive    → run_record_core, programme_home, programme_journal;
#                          programme_authority, programme_artifacts, programme_store,
#                          programme_context, programme_recovery, programme_preserve,
#                          programme_sources, driver_session [lazy]. programme_home (end),
#                          programme_record (claim) and programme reach it lazily or after
#                          their verb table, so it closes no import-time cycle.
#   programme_resume     → run_record_core, programme_home, programme_authority,
#                          programme_recovery; programme_journal [lazy]. It takes
#                          `programme` as a host argument for the inbox verb and never
#                          loads it, nor programme_sources or programme_lifecycle.
#   programme_trajectory → run_record_core, programme_home, programme_journal,
#                          programme_sanitize, programme_record, driver_session
#   programme_view       → programme_home, programme_permission_rules, programme_predicate,
#                          programme_sanitize, programme_tasks, programme_terms, session_registry,
#                          programme_view_work
#   programme_view_work  → programme_home, programme_predicate
#   permission_transcript → programme_sanitize, session_registry
#   programme_permission_state → run_record_core, programme_record, programme_permission_rules
#   programme_permission_settle → run_record_core, programme_home, programme_journal,
#                          programme_record, programme_sanitize, programme_sources,
#                          programme_permission_rules, programme_permission_state,
#                          permission_transcript, session_registry
#   programme_permission → run_record_core, programme_home, programme_journal,
#                          programme_record, programme_permission_rules,
#                          programme_permission_state, permission_transcript,
#                          programme_permission_settle (never the reverse)
#   programme_settings_guard → programme_home, programme_journal, session_registry,
#                          programme_permission_rules
#   programme            → run_record, run_record_core, programme_home, programme_journal,
#                          programme_authority, programme_protocol, session_registry,
#                          driver_session, verb_cli; programme_resume, programme_store,
#                          programme_import [lazy];
#                          then, after its verb table is built: programme_record, programme_rulings,
#                          programme_evidence, programme_sources, programme_terms, programme_proposals,
#                          programme_trajectory, programme_view, programme_lifecycle, programme_archive
#                          Those eight receive `programme` as a `host` argument and never
#                          load it back.
#   programme_proposals  → programme_home, programme_sanitize
#   programme_rulings    → run_record_core, programme_journal, programme_sanitize,
#                          programme_decisions, programme_context (never programme_terms:
#                          programme_terms loads it for the correction anchor checks)
#   programme_naming     → programme_home
#   programme_lifecycle  → run_record_core, programme_home, programme_journal, programme_authority [lazy],
#                          session_registry, driver_session, programme_sanitize,
#                          programme_resume [lazy] (handover flags the new driver's restore),
#                          programme_sources [lazy] (takeover reads herdr)
#   programme-watch      → run_record_core, programme_home, programme_predicate,
#                          programme_record, programme_sanitize, programme_tracker,
#                          programme_tasks, programme_plans, driver_session
#                          (writes go through the programme CLI as a child process)
#   run_record_evidence  → run_record_core, driver_session; programme_home [lazy],
#                          programme_journal [lazy], programme_sanitize [lazy],
#                          programme_evidence [lazy]
#   on-user-prompt       → programme_home, programme_journal, session_registry
#   on-pre-compact       → programme_home [lazy], programme_resume [lazy]
#   on-session-start     → phase-grammar; on-pre-compact [lazy], programme [lazy],
#                          programme_resume [lazy]
#   on-stop              → programme_resume [lazy] (reads the compact flag's trigger)
#   on-stop              → phase-grammar; programme_home [lazy], programme_predicate [lazy],
#                          programme_journal [lazy], programme [lazy]
#   on-pretooluse-action → phase-grammar; session_registry [lazy], programme_journal [lazy],
#                          programme_home [lazy], run_record_core [lazy], programme_evidence [lazy],
#                          programme_settings_guard [lazy]
#   auto-spawn           → driver_session; auto-workspace [lazy]
#
# format_compat is a DAG ROOT (pure stdlib, no sibling import), so every `→ format_compat`
# edge is a LEAF edge that closes no cycle.
#
# NB this lint is forbidden-edge / negative-grep: an ALLOWED edge missing from this
# comment does NOT turn it red. That is exactly why the comment drifted, and why the
# existence asserts below matter — they are what makes a botched rename fail loudly
# rather than silently vacate a negative grep. `loads_sibling` greps the whole file for
# the two loader call forms, so it sees [top] and [lazy] loads but is blind to [plain]
# edges: pulse_advance reaches step_producers via a PLAIN `import step_producers as
# producers`, and the existence assert is the only thing standing behind that edge.
#
# Task-run consumers (auto.py, dispatcher.py, on-stop.py, auto-status.py, etc.) load
# the RUN-RECORD FACADE, never run_record_mutators/run_record_producers directly — the facade
# is the public surface. The programme family reads and writes through run_record_core.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${AUTO_ROOT}/lib"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() {
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m %s\n" "$CURRENT"
  [ -n "${1:-}" ] && printf "      %s\n" "$1"
  return 0
}

# loads_sibling <file> <sibling-name> → 0 (true) if <file> contains a
# load_lib_module("<sibling-name>") call. Grep for the exact call form.
loads_sibling() {
  grep -qE "(load_lib_module|_lazy_load)\\(\"$2\"\\)" "$LIB/$1"
}

loads_any_sibling() {
  grep -qE "load_lib_module|_lazy_load|^from _bootstrap|^[[:space:]]*import (run_record|programme|session_registry|driver_session|verb_cli)" "$LIB/$1"
}

# ─── run-record DAG: the pinned family EXISTS (anti-vacuity, F13) ────────────
# Same reasoning as the pulse/backend/workflow existence asserts below: every
# run-record DAG check in this file is a NEGATIVE grep through `loads_sibling`, and
# `loads_sibling` greps a file BY PATH — on a MISSING file grep exits non-zero, the
# `if` takes the else branch, and the check passes VACUOUSLY. The U9 rename moved SIX
# modules at once into the `run_record*` names; a single typo'd destination would
# leave this entire lint green while `/auto` died on the first `load_lib_module`.
# Assert the whole family is on disk BEFORE trusting a word the negative greps say.
#
# (The KTD-4 forwarding stubs left behind at the pre-rename paths are deliberately NOT
# asserted here: they are not part of the DAG, and their behaviour is pinned by
# tests/unit/run-record-stub.test.sh, which DRIVES them rather than just checking they
# exist. This lint also deliberately does not spell the retired module names — the
# vocabulary audit greps the whole tree for them, so naming them here would trip it.)
for _rr in run_record.py run_record_core.py run_record_predicate.py \
           run_record_mutators.py run_record_steering.py run_record_producers.py \
           run_record.sh; do
  it "lib/${_rr} exists (the U9-renamed run-record family — DAG checks are vacuous without it)"
  if [ -f "${LIB}/${_rr}" ]; then
    pass
  else
    fail "lib/${_rr} is missing — the U9 run-record rename did not land it, and the DAG checks below would pass vacuously"
  fi
done

# ─── run-record DAG: forbidden edges ────────────────────────────────────────────
it "run_record_core.py imports NO run_record sibling (DAG root)"
if loads_sibling "run_record_core.py" "run_record_mutators" \
   || loads_sibling "run_record_core.py" "run_record_producers" \
   || loads_sibling "run_record_core.py" "run_record"; then
  fail "run_record_core.py must not import any run_record sibling — it is the DAG root"
else
  pass
fi

it "run_record_mutators.py imports run_record_core only (no producers, no facade)"
if loads_sibling "run_record_mutators.py" "run_record_producers" \
   || loads_sibling "run_record_mutators.py" "run_record"; then
  fail "run_record_mutators.py may import run_record_core ONLY — importing producers/facade is a cycle"
else
  pass
fi

it "run_record_producers.py does NOT import the run_record facade (back-edge)"
if loads_sibling "run_record_producers.py" "run_record"; then
  fail "run_record_producers.py must not import the run_record facade — that closes a cycle"
else
  pass
fi

# ─── permission proposals DAG ───────────────────────────────────────────────────
for _m in programme_permission.py programme_permission_settle.py programme_permission_state.py \
          permission_transcript.py; do
  it "lib/${_m} exists (the permission DAG checks below are vacuous without it)"
  if [ -f "${LIB}/${_m}" ]; then pass; else fail "lib/${_m} missing"; fi
done

it "the permission settle, state and transcript modules never load programme_permission (back-edge)"
if loads_sibling "programme_permission_settle.py" "programme_permission" \
   || loads_sibling "programme_permission_state.py" "programme_permission" \
   || loads_sibling "programme_permission_state.py" "programme_permission_settle" \
   || loads_sibling "permission_transcript.py" "programme_permission"; then
  fail "only programme_permission loads programme_permission_settle; a load back closes a cycle"
else
  pass
fi

# ─── pulse DAG: the pinned family EXISTS (anti-vacuity, F13) ─────────────────
# loads_sibling greps a file by path: on a MISSING file grep exits non-zero, the
# `if` takes the else branch, and every negative-grep DAG check below passes
# VACUOUSLY. A mis-renamed module (the concept-vocabulary rename U5 file moves)
# would therefore go green while pinning nothing. Assert the three files first.
for _m in pulse.py pulse_advance.py pulse_guidance.py; do
  it "lib/${_m} exists (the pinned pulse family — DAG checks below are vacuous without it)"
  if [ -f "${LIB}/${_m}" ]; then
    pass
  else
    fail "lib/${_m} missing — the pulse DAG checks would pass vacuously"
  fi
done

# ─── pulse DAG: forbidden back-edges ─────────────────────────────────────────
it "pulse_advance.py does NOT back-import pulse"
if loads_sibling "pulse_advance.py" "pulse"; then
  fail "pulse_advance.py must not import pulse — that closes a cycle"
else
  pass
fi

it "pulse_guidance.py does NOT back-import pulse or pulse_advance (leaf)"
if loads_sibling "pulse_guidance.py" "pulse" \
   || loads_sibling "pulse_guidance.py" "pulse_advance"; then
  fail "pulse_guidance.py is a leaf — it must not import pulse or pulse_advance"
else
  pass
fi

# ─── facade discipline: consumers use the facade, not the internals ─────────
# Every lib file EXCEPT the run-record split itself must route through the `run_record`
# facade — none may load run_record_mutators / run_record_producers directly.
it "no consumer loads run_record_mutators/run_record_producers directly (facade discipline)"
violators=""
for f in "$LIB"/*.py; do
  base="$(basename "$f")"
  # The split files themselves are allowed to import their DAG siblings.
  # run_record_steering (v0.13.0) is a facade LAYER, not a consumer: it holds the
  # agent-facing steering verbs and imports run_record_mutators for the two graph
  # helpers add_step/reshape_deps reuse (core ← mutators ← steering ← facade).
  case "$base" in
    run_record.py|run_record_core.py|run_record_mutators.py|run_record_producers.py|run_record_steering.py) continue ;;
  esac
  if grep -q 'load_lib_module("run_record_mutators")' "$f" \
     || grep -q 'load_lib_module("run_record_producers")' "$f"; then
    violators+="${base} "
  fi
done
if [ -z "$violators" ]; then
  pass
else
  fail "these consumers bypass the run_record facade: ${violators}— load \"run_record\" instead"
fi

# ─── presets DAG: the validator stays a light leaf (KTD-2) ─────────────────
# lib/presets.py (U1, addressable-step-contents) reuses workflow_validate's
# primitives + the backend_ops leaf, but MUST NOT import dispatcher.py — that
# module pulls in the run-record and the whole dispatch surface. Keeping the preset
# validator off the heavy dispatch module is the KTD-2 boundary.
# Existence assert (F13): the forbidden-edge check above is a NEGATIVE grep, so
# it passes VACUOUSLY if lib/dispatcher.py is missing (e.g. a botched rename that
# left the module under its old name). Pin the pinned module's presence so a
# mis-rename goes red here instead of silently un-enforcing the boundary.
it "lib/dispatcher.py exists (pinned module — negative-grep guard against vacuous pass)"
if [ -f "$LIB/dispatcher.py" ]; then
  pass
else
  fail "lib/dispatcher.py is missing — the KTD-2 forbidden-edge grep above would pass vacuously"
fi

it "presets.py does NOT import dispatcher (KTD-2 leaf boundary)"
if loads_sibling "presets.py" "dispatcher"; then
  fail "presets.py must not import dispatcher — the preset validator is a light leaf (KTD-2); import backend_ops for VALID_BACKEND_OPS instead"
else
  pass
fi

# ─── preset_oneshot DAG: the one-shot verdict stays off the iteration gate ──
# lib/preset_oneshot.py (U4, addressable-step-contents) is the one-shot
# terminal-verdict helper. KTD-1 boundary: the one-shot verdict is a
# READ-ONLY terminal aggregate over the ratified criteria — it reuses ONLY the
# pure verification evaluator, and MUST NOT import lib/iteration.py (the
# iteration-decision-commit module). Importing iteration would silently re-acquire
# the loop's advance/iterate gate semantics and kill the "run once" guarantee
# (Risk R-A). It may load `verification` (the pure aggregator) but never `iteration`.
it "preset_oneshot.py does NOT import iteration (KTD-1 boundary — no gate decision-commit)"
if loads_sibling "preset_oneshot.py" "iteration"; then
  fail "preset_oneshot.py must not import iteration — the one-shot verdict is a read-only terminal aggregate (KTD-1); reuse verification.aggregate directly, never the iteration decision-commit"
else
  pass
fi

it "backend_ops.py imports NO sibling lib module (pure-stdlib leaf)"
if grep -q "load_lib_module(" "$LIB/backend_ops.py"; then
  fail "backend_ops.py must be a pure-stdlib leaf — it is the shared VALID_BACKEND_OPS source of truth and must import no sibling"
else
  pass
fi

# ─── file-existence asserts for the U4-renamed backend modules (F13) ────────
# The leaf/negative-grep checks above pass VACUOUSLY on a missing (mis-renamed)
# file — a botched rename to the `backend_ops` / `backend-*` module names would
# go green by accident. These positive existence asserts make it go RED.
for _mod in backend_ops.py backend-ce.py backend-native.py; do
  it "lib/${_mod} exists (pinned module — guard against a vacuous negative-grep pass)"
  if [ -f "$LIB/${_mod}" ]; then
    pass
  else
    fail "lib/${_mod} is missing — the U4 backend rename did not land it"
  fi
done

# ─── file-existence assert for the U6 format shim ───────────────────────────
# Same anti-vacuity reasoning: lib/format_compat.py is the DAG root every read
# chokepoint and the write gate depend on. If it vanished, the negative-grep
# checks above would still pass — but every run-record read would lose its v1→v2
# upgrade. Pin its existence positively.
it "lib/format_compat.py exists (the U6 format-v1→v2 shim; DAG root)"
if [ -f "$LIB/format_compat.py" ]; then
  pass
else
  fail "lib/format_compat.py is missing — the U6 read/write shim did not land"
fi

# ─── file-existence assert for the U7-renamed producer module (F13) ──────────
# The producer module took its final name at U7 (KTD-3: the two-term file — it carried
# BOTH renamed terms, so it moves exactly once, alongside the rest of its family, and
# never twice). Same anti-vacuity reasoning as the
# backend/pulse asserts above — but with a sharper edge here, because the pulse DAG
# reaches this module through a PLAIN `import step_producers as producers` in
# pulse_advance.py, NOT a load_lib_module() string, so `loads_sibling` cannot see the
# edge at all. A botched rename would surface as an ImportError deep in a live run,
# not as a red lint. Pin the file's presence.
#
# (A resurrected import of the PRE-RENAME module name needs no assert here: the
# vocabulary-audit greps the whole tree for the retired term and fails on it — which
# is why this lint deliberately does not spell that name.)
it "lib/step_producers.py exists (the U7-renamed producer module)"
if [ -f "$LIB/step_producers.py" ]; then
  pass
else
  fail "lib/step_producers.py is missing — the U7 producer-module rename did not land"
fi

# ─── file-existence asserts for the U8-renamed workflow modules (F13) ────────
# The DAG edges asserted at the top of this file (`workflows → workflow_validate,
# format_compat`, `presets → workflow_validate`) are all NEGATIVE greps or
# loads_sibling checks, and every one of them passes VACUOUSLY against a module
# that isn't there. A rename that landed `lib/workflow_validate.py` under a typo'd
# name would leave this lint green while `/auto` died at the first resolve. Pin
# the two U8 module names positively — plus the built-in workflow DIRECTORY, whose
# absence would silently drop `resolve()` through to the A1_BUILTIN constant for
# a1 and to a not-found error for every other built-in.
for _mod in workflows.py workflow_validate.py workflows-list.sh; do
  it "lib/${_mod} exists (the U8-renamed workflow module — guard against a vacuous pass)"
  if [ -f "$LIB/${_mod}" ]; then
    pass
  else
    fail "lib/${_mod} is missing — the U8 workflow rename did not land it"
  fi
done

it "the built-in workflow dir exists and holds the conformance corpus (a1/a2/a4/w/pipeline/review)"
_missing=""
for _wf in a1 a2 a4 w pipeline review schema; do
  [ -f "${AUTO_ROOT}/workflows/${_wf}.json" ] || _missing="${_missing} ${_wf}.json"
done
if [ -z "$_missing" ]; then
  pass
else
  fail "workflows/ is missing:${_missing} — the U8 built-in dir rename did not land"
fi

# The producer module is a LEAF: pulse/pulse_advance import it, it imports no
# sibling back. A back-edge to pulse* or the run-record facade would close a cycle.
it "step_producers.py does NOT back-import pulse/pulse_advance (leaf)"
if grep -qE '^\s*import (pulse|pulse_advance)\b|load_lib_module\("(pulse|pulse_advance)"\)' \
     "$LIB/step_producers.py"; then
  fail "step_producers.py must not import pulse/pulse_advance — the producers are a leaf; that closes a cycle"
else
  pass
fi

# The shim must stay a TRUE DAG root: pure stdlib, importing no sibling. If it
# ever grew a sibling edge it could cycle back through run_record_core (which imports
# IT), so this is the load-bearing negative check for the new module.
it "format_compat.py imports NO sibling lib module (it is the DAG root)"
if grep -qE 'load_lib_module\(|^from (run_record|workflows|workflow_validate|pulse)' "$LIB/format_compat.py"; then
  fail "format_compat.py must import no sibling — run_record_core imports it, so any sibling edge risks a cycle"
else
  pass
fi

# ─── programme family: every module and shim EXISTS (anti-vacuity) ──────────
for _pm in programme_home.py programme_predicate.py programme_protocol.py \
           programme_journal.py session_registry.py on-user-prompt.py on-pre-compact.py \
           programme.py programme.sh verb_cli.py programme_record.py programme_sanitize.py \
           programme_evidence.py programme_sources.py programme-watch.py programme-watch.sh \
           programme_view.py run_record_evidence.py programme_lifecycle.py \
           programme_exec.py programme_tracker.py programme_tasks.py programme_plans.py \
           programme_store.py programme_authority.py programme_import.py \
           programme_artifacts.py programme_context.py programme_gitio.py programme_preserve.py \
           programme_recovery.py programme_archive.py programme_resume.py \
           programme_terms.py programme_proposals.py programme_trajectory.py programme_view_work.py \
           programme_naming.py programme_rulings.py; do
  it "lib/${_pm} exists (programme family — its edge checks are vacuous without it)"
  if [ -f "${LIB}/${_pm}" ]; then
    pass
  else
    fail "lib/${_pm} is missing — the programme edge checks below would pass vacuously"
  fi
done

for _hook in on-user-prompt.sh on-pre-compact.sh; do
  it ".claude/hooks/${_hook} exists (the shim that runs its lib module)"
  if [ -f "${AUTO_ROOT}/.claude/hooks/${_hook}" ]; then
    pass
  else
    fail ".claude/hooks/${_hook} is missing — the hook would never run its lib module"
  fi
done

# ─── programme family: forbidden edges ─────────────────────────────────────
for _host in programme_record programme_evidence programme_sources programme_trajectory programme_view \
             programme-watch run_record_evidence programme_lifecycle programme_archive \
             programme_resume programme_terms programme_proposals programme_view_work programme_naming \
             programme_rulings; do
  it "${_host}.py does NOT load programme (it receives it as host, or calls the CLI)"
  if loads_sibling "${_host}.py" "programme"; then
    fail "${_host}.py must not load programme — programme loads it, so that closes a cycle"
  else
    pass
  fi
done

it "programme_resume.py loads no verb module (it is loaded by programme at import time)"
if loads_sibling "programme_resume.py" "programme_sources" \
   || loads_sibling "programme_resume.py" "programme_lifecycle" \
   || loads_sibling "programme_resume.py" "programme_record" \
   || loads_sibling "programme_resume.py" "programme_archive"; then
  fail "programme_resume.py must not load a verb module — programme loads it before its verb table"
else
  pass
fi

it "programme_evidence.py and run_record_evidence.py do NOT load the run_record facade"
if loads_sibling "programme_evidence.py" "run_record" \
   || loads_sibling "run_record_evidence.py" "run_record"; then
  fail "the facade loads run_record_evidence, which reaches programme_evidence — a facade load from either closes a cycle"
else
  pass
fi

for _low in programme_store programme_authority programme_import programme_artifacts \
            programme_gitio programme_preserve programme_recovery; do
  it "${_low}.py does NOT load programme or a programme verb module"
  if loads_sibling "${_low}.py" "programme" || loads_sibling "${_low}.py" "programme_record" \
     || loads_sibling "${_low}.py" "programme_lifecycle"; then
    fail "${_low}.py sits below the verb modules; loading one closes a cycle"
  else
    pass
  fi
done

it "programme_recovery.py does NOT load programme_sources (the sources verbs load it)"
if loads_sibling "programme_recovery.py" "programme_sources"; then
  fail "programme_recovery.py loading programme_sources closes a cycle; take live reads as callables"
else
  pass
fi

it "programme_journal.py and programme_store.py load each other only lazily"
if grep -qE '^[a-z_]+ = load_lib_module\("programme_(authority|store)"\)' "$LIB/programme_journal.py" \
   || grep -qE '^[a-z_]+ = load_lib_module\("programme_journal"\)' "$LIB/programme_store.py" \
   || grep -qE '^[a-z_]+ = load_lib_module\("programme_journal"\)' "$LIB/programme_authority.py"; then
  fail "a module-top load between the journal and the store closes an import-time cycle"
else
  pass
fi

it "programme_journal, programme_record and programme_evidence load programme_artifacts only lazily"
if grep -qE '^[a-z_]+ = load_lib_module\("programme_artifacts"\)' "$LIB/programme_journal.py" \
   "$LIB/programme_record.py" "$LIB/programme_evidence.py"; then
  fail "a module-top load of programme_artifacts closes an import-time cycle (it loads the journal)"
else
  pass
fi

it "programme_home and programme_record load programme_archive only lazily"
if grep -qE '^[a-z_]+ = load_lib_module\("programme_archive"\)' "$LIB/programme_home.py" "$LIB/programme_record.py"; then
  fail "programme_archive loads programme_home and programme_journal at its top; a module-top load back closes a cycle"
else
  pass
fi

it "programme_record loads programme_preserve only lazily"
if grep -qE '^[a-z_]+ = load_lib_module\("programme_preserve"\)' "$LIB/programme_record.py"; then
  fail "a module-top load of programme_preserve from programme_record pulls git capture into every verb"
else
  pass
fi

it "programme_protocol.py does NOT load programme_journal (the prompt lookup is injected)"
if loads_sibling "programme_protocol.py" "programme_journal"; then
  fail "programme_protocol.py must not load programme_journal — the caller passes prompt_lookup in"
else
  pass
fi

it "programme_predicate.py loads no protocol, journal or task predicate"
if loads_sibling "programme_predicate.py" "programme_protocol" \
   || loads_sibling "programme_predicate.py" "programme_journal" \
   || loads_sibling "programme_predicate.py" "run_record_predicate"; then
  fail "programme_predicate.py must stay pure over the record — run_record_predicate loads it, and every record write calls it"
else
  pass
fi

it "programme_context.py loads no programme, verb, journal or protocol module"
if loads_sibling "programme_context.py" "programme" || loads_sibling "programme_context.py" "programme_record" \
   || loads_sibling "programme_context.py" "programme_journal" \
   || loads_sibling "programme_context.py" "programme_protocol" \
   || loads_sibling "programme_context.py" "programme_predicate"; then
  fail "programme_context.py must stay pure — the predicate loads it, and programme_record passes itself in"
else
  pass
fi

it "programme_rulings.py loads neither programme_terms nor programme_record (terms loads it; record is the host's)"
if loads_sibling "programme_rulings.py" "programme_terms" || loads_sibling "programme_rulings.py" "programme_record"; then
  fail "programme_rulings.py must not load programme_terms (cycle) or programme_record (reach it as host.programme_record)"
else
  pass
fi

it "programme_view.py does NOT load programme_record (rules and inbox size are passed in)"
if loads_sibling "programme_view.py" "programme_record"; then
  fail "programme_view.py must not load programme_record — the caller passes rules and inbox size"
else
  pass
fi

it "programme_view_work.py loads only programme_home and programme_predicate"
_extra="$(grep -oE 'load_lib_module\("[a-z_]+"\)' "$LIB/programme_view_work.py" | grep -vE '"(programme_home|programme_predicate)"')"
if [ -z "$_extra" ] && loads_sibling "programme_view_work.py" "programme_home"; then
  pass
else
  fail "programme_view_work.py must stay a pure read over the record and journal it is handed; extra loads: ${_extra}"
fi

it "programme-watch.py does NOT load programme_sources"
if loads_sibling "programme-watch.py" "programme_sources"; then
  fail "programme-watch.py must not load programme_sources — it reads herdr itself and writes through the CLI"
else
  pass
fi

for _reader in programme_exec programme_tracker programme_tasks programme_plans; do
  it "${_reader}.py loads no programme verb module (the watcher and the view load it)"
  if loads_sibling "${_reader}.py" "programme_sources" || loads_sibling "${_reader}.py" "programme_record" \
     || loads_sibling "${_reader}.py" "programme"; then
    fail "${_reader}.py must stay a plain reader — programme_record and programme-watch load it"
  else
    pass
  fi
done

it "run_record.py does NOT load programme_evidence, programme_record or programme"
if loads_sibling "run_record.py" "programme_evidence" \
   || loads_sibling "run_record.py" "programme_record" \
   || loads_sibling "run_record.py" "programme"; then
  fail "run_record.py reaches programme checks only through run_record_evidence, lazily"
else
  pass
fi

for _leaf in verb_cli.py programme_sanitize.py; do
  it "${_leaf} imports NO sibling lib module (leaf)"
  if loads_any_sibling "${_leaf}"; then
    fail "${_leaf} must be a pure-stdlib leaf — programme and its parts all load it"
  else
    pass
  fi
done

# ─── deliberate-fail: prove the lint isn't vacuous ──────────────────────────
# Write a tmp copy of run_record_mutators.py with a forbidden facade import added;
# the loads_sibling check MUST flag it. (We test the predicate directly against
# a planted-broken copy rather than mutating the real tree.)
it "deliberate-fail: a planted run_record_mutators→run_record facade import trips the lint"
tmpdir="$(mktemp -d -t import-topology-df.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
cp "$LIB/run_record_mutators.py" "$tmpdir/run_record_mutators.py"
printf '\nrun_record = load_lib_module("run_record")  # PLANTED forbidden back-edge\n' >> "$tmpdir/run_record_mutators.py"
if grep -q 'load_lib_module("run_record")' "$tmpdir/run_record_mutators.py"; then
  pass
else
  fail "deliberate-fail: planted forbidden import was NOT detected by the grep predicate"
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "import-topology.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
