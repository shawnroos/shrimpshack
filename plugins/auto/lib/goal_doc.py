#!/usr/bin/env python3
"""The goal doc for a contracted worker: generated from the contract's done bar, amended in place (KTD10).

``write-goal`` creates or amends ``<repo>/.claude/auto/goals/<run>.md``. A Markdown file never reads as a
run record, because sweeps read every ``*.json`` under ``.claude/auto/``. Each write bumps the contract
version through a pending entry, so the amendment bites at the PM's chosen point, and records the goal
version on the contract. An amendment first reads the programme's ``goal_amend`` authority: act and
act_and_tell write (act_and_tell journals a tell), propose hands a Shawn ask and writes nothing, never
refuses. ``goal-status`` computes ``goal-stale`` at read time; nothing stores it.
"""

from __future__ import annotations

import contextlib
import functools
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_sanitize = load_lib_module("programme_sanitize")
programme_decisions = load_lib_module("programme_decisions")
worker_contract = load_lib_module("worker_contract")
worker_question = load_lib_module("worker_question")
phase_grammar = load_lib_module("phase-grammar")

GOAL_KIND = "goal_amend"
JOURNAL_KIND = "goal_written"
GOALS_DIR = os.path.join(".claude", "auto", "goals")
HEADER_RE = re.compile(r"\A<!-- goal-version: (\d+); contract-version: (\d+); run: ([A-Za-z0-9._-]+) -->\n")
STALE, CURRENT, NONE, NO_CONTRACT = "goal-stale", "current", "none", "no_contract"
TEXT_CAP, OUTCOME_CAP, OUTCOMES_MAX = 300, 300, 12
_CLAUSES = {
    "steps_terminal": "every step in the plan is implemented and reviewed, and only P3 review findings remain "
                      "(P0/P1/P2 all resolved)",
    "gaps_closed": "no plan gap remains open",
    "phase_reached": "the run has reached its final phase",
}
_EXTERNAL = {"pr_merged": "the PR merge", "ci_green": "the CI result"}
_FOOTER = "<!-- note: model-judged goal, independent of auto's Stop hook; release with `/goal clear`. -->"


class GoalError(Exception):
    def __init__(self, message, code="refused"):
        super().__init__(message)
        self.code = code


@contextlib.contextmanager
def refusals(host):
    try:
        yield
    except (GoalError, worker_contract.ContractError, worker_question.QuestionError) as exc:
        raise host.ProgrammeError(f"refused ({exc.code}): {exc}") from None


def goal_path(repo, run_id) -> str:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", run_id or "") or run_id in (".", ".."):
        raise GoalError(f"run id {run_id!r} cannot name a goal doc", "bad_run_id")
    return os.path.join(repo, GOALS_DIR, run_id + ".md")


def read_header(path):
    try:
        with open(path, encoding="utf-8") as fh:
            found = HEADER_RE.match(fh.read(400))
    except OSError:
        return None
    if not found:
        return None
    return {"goal_version": int(found.group(1)), "contract_version": int(found.group(2)), "run": found.group(3)}


def reading(repo, run_id, record=None) -> dict:
    record = record if record is not None else run_record_core.read_run_record(repo, run_id)
    block = worker_contract.contract_of(record)
    if block is None:
        return {"state": NO_CONTRACT}
    path = goal_path(repo, run_id)
    head = read_header(path)
    base = {"path": path, "contract_version": block["version"], "goal_version": block.get("goal_version", 0),
            "goal_bound_version": block.get("goal_bound_version", 0)}
    if head is None:
        return dict(base, state=NONE)
    stale = head["contract_version"] < block["version"]
    return dict(base, state=STALE if stale else CURRENT, doc_goal_version=head["goal_version"],
                doc_contract_version=head["contract_version"])


def human_only_steps(record, manual=()) -> list:
    """Steps only a human can clear: a non-terminal step with a ``human`` verification criterion, or a plan step the PM names."""
    predicate = load_lib_module("run_record_predicate")
    found = []
    for step in record.get("steps") or []:
        if not isinstance(step, dict) or predicate.step_is_terminal(step):
            continue
        for criterion in step.get("verification") or []:
            if isinstance(criterion, dict) and criterion.get("type") == "human":
                found.append(f"{step.get('id')} (human checkpoint {criterion.get('id')})")
    return found + list(manual)


def _flat(value, cap) -> str:
    return programme_sanitize.clean(value, cap=cap)


def render(*, title, plan, done_bar, outcomes, out_of_scope, goal_version, contract_version, run_id) -> str:
    clauses = [_CLAUSES[name] for name in done_bar["internal"]]
    scope = list(out_of_scope)
    if done_bar["external"]:
        names = " and ".join(_EXTERNAL[name] for name in done_bar["external"])
        scope.append(f"{names}, which the PM verifies outside this goal")
    lines = [f"<!-- goal-version: {goal_version}; contract-version: {contract_version}; run: {run_id} -->",
             f"# Goal: {title}", ""]
    if plan:
        lines += [f"Source plan: `{plan}`", ""]
    lines += [f"This goal is met when auto's exit predicate holds: {'; and '.join(clauses)}.",
              "Concretely, that state means:", ""]
    lines += [f"- {o}" for o in outcomes] or ["- every criterion above holds"]
    lines += ["", "Out of scope (do NOT hold this goal open on these): " + ("; ".join(scope) or "none") + ".", "",
              _FOOTER, ""]
    return "\n".join(lines)


def _atomic_write(path, text) -> None:
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".goal-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def _names(raw, known, label) -> list:
    if raw is None:
        return None
    names = [] if raw.strip() in ("", "none") else [n.strip() for n in raw.split(",")]
    for name in names:
        if name not in known:
            raise GoalError(f"--{label} names {name!r}; known: {list(known)}", "bad_done_bar")
    return names


def digest(inputs) -> str:
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()[:12]


def _approved(item, ask_id, token) -> bool:
    ask = programme_decisions.handed(item)
    answered = ask.get("answered")
    return (ask.get("id") == ask_id and ask.get("kind") == GOAL_KIND and isinstance(answered, dict)
            and answered.get("choice") == "ship" and f"amendment {token}" in (ask.get("evidence") or []))


def _hand_via_programme(programme_run, item_key, question, token) -> None:
    argv = [sys.executable, os.path.join(_LIB_DIR, "programme.py"), "hand-item", item_key, "--run", programme_run,
            "--kind", GOAL_KIND, "--question", question, "--evidence", f"amendment {token}",
            "--if-nothing", "the goal doc stays as it is"]
    done = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise GoalError(f"hand-item for the goal amendment failed: {(done.stderr or done.stdout).strip()}",
                        "hand_failed")


def _bound_run(item, key) -> tuple:
    state = item.get("auto_run") or {}
    if state.get("state") != "bound" or not state.get("run_id") or not state.get("path"):
        raise GoalError(f"item {key!r} has no bound Auto run; the worker registers its run first (register-run)",
                        "not_bound")
    session = (item.get("owner") or {}).get("session_id") or state.get("session_id")
    return state["path"], state["run_id"], session, state.get("plan")


def _inputs(opts, block, default_plan, run_id) -> dict:
    internal = _names(opts.get("done-internal"), worker_contract.DONE_INTERNAL, "done-internal")
    external = _names(opts.get("done-external"), worker_contract.DONE_EXTERNAL, "done-external")
    done_bar = {"internal": block["done_bar"]["internal"] if internal is None else internal,
                "external": block["done_bar"]["external"] if external is None else external}
    plan = _flat(opts.get("plan") or default_plan, TEXT_CAP) or None
    outcomes = [o for o in (_flat(x, OUTCOME_CAP) for x in opts.get("outcome") or []) if o]
    if len(outcomes) > OUTCOMES_MAX:
        raise GoalError(f"at most {OUTCOMES_MAX} --outcome values", "too_many")
    return {"done_bar": done_bar, "plan": plan, "title": _flat(opts.get("title"), 120) or
            (os.path.splitext(os.path.basename(plan))[0] if plan else run_id),
            "outcomes": outcomes,
            "out_of_scope": [o for o in (_flat(x, OUTCOME_CAP) for x in opts.get("out-of-scope") or []) if o],
            "manual": [m for m in (_flat(x, TEXT_CAP) for x in opts.get("manual-step") or []) if m]}


def _refuse_human(record, inputs) -> None:
    steps = human_only_steps(record, inputs["manual"]) if "steps_terminal" in inputs["done_bar"]["internal"] \
        else list(inputs["manual"])
    if steps:
        raise GoalError("the done bar includes a step only a human can do: " + "; ".join(steps) +
                        ". A goal containing it could never be met; take the step out of the done bar or "
                        "route it to Shawn", "human_only_step")


def _commit(repo, run_id, programme_run, worker_session, inputs, *, caller, space_of, bite, existed, now):
    landed = {}

    def mutate(rec):
        worker_contract.guard(programme_run, worker_session, caller=caller, space_of=space_of)
        block = worker_contract.contract_of(rec)
        if block is None:
            raise GoalError("the worker's run record has no contract", "no_contract")
        if (rec.get("loop") or {}).get(phase_grammar.LOOP_PHASE_KEY) == "done":
            raise GoalError(f"run {run_id} is done; start a follow-up run from a copy of its contract", "run_done")
        path = goal_path(repo, run_id)
        if os.path.exists(path) != existed:
            raise GoalError("the goal doc changed while this write waited; run it again", "changed_under_write")
        head = read_header(path) or {}
        goal_version = max(block.get("goal_version", 0), head.get("goal_version", 0)) + 1
        block["done_bar"] = inputs["done_bar"]
        entry = worker_question.append_pending(block, bite=bite, set_by=caller, now=now)
        block["goal_version"] = goal_version
        worker_contract.validate(block)
        _atomic_write(path, render(title=inputs["title"], plan=inputs["plan"], done_bar=inputs["done_bar"],
                                   outcomes=inputs["outcomes"], out_of_scope=inputs["out_of_scope"],
                                   goal_version=goal_version, contract_version=block["version"], run_id=run_id))
        landed.update(path=path, goal_version=goal_version, contract_version=entry["version"], bite=bite)

    run_record_core._with_locked_run_record(repo, run_id, mutate)
    return landed


def write_goal(programme_run, item_key, opts, *, caller=None, space_of=None, hand=None, now=None) -> dict:
    sid = caller or load_lib_module("driver_session").driving_session_id()
    if opts.get("bite") not in (None,) + worker_contract.BITES:
        raise GoalError(f"--bite must be one of {list(worker_contract.BITES)}", "bad_bite")
    prog_rec = run_record_core.read_run_record(programme_home.home_path(programme_run), programme_run)
    programme = programme_home.normalize_programme(prog_rec.get("programme") or {})
    item = programme["items"][item_key]
    repo, run_id, worker_session, default_plan = _bound_run(item, item_key)
    worker_contract.guard(programme_run, worker_session, caller=sid, space_of=space_of)
    record = run_record_core.read_run_record(repo, run_id)
    block = worker_contract.contract_of(record)
    if block is None:
        raise GoalError("the worker's run record has no contract", "no_contract")
    inputs = _inputs(opts, block, default_plan, run_id)
    _refuse_human(record, inputs)
    path = goal_path(repo, run_id)
    existed = os.path.exists(path)
    token = digest(inputs)
    mode = "created"
    if existed:
        mode = "amended"
        verdict = worker_contract.effective_authority(
            {}, GOAL_KIND, **worker_contract.programme_inputs(programme, item_key, now=now))
        if verdict["mode"] == "never":
            raise GoalError(f"goal_amend is never for item {item_key!r} ({verdict['reason']}); the goal doc "
                            "stays as it is", "authority_never")
        if verdict["mode"] == "propose" and not _approved(item, opts.get("approved"), token):
            if item.get("state") == "handed" and not programme_decisions.handed(item).get("answered"):
                raise GoalError(f"item {item_key!r} already waits on Shawn's answer; the goal doc stays as it is",
                                "item_handed")
            question = (f"Amend the goal doc of {item_key} to goal version "
                        f"{max(block.get('goal_version', 0), (read_header(path) or {}).get('goal_version', 0)) + 1}?")
            (hand or _hand_via_programme)(programme_run, item_key, question, token)
            return {"state": "waiting_on_shawn", "written": False, "path": path, "amendment": token,
                    "authority": verdict["mode"]}
    else:
        verdict = None
    landed = _commit(repo, run_id, programme_run, worker_session, inputs, caller=sid, space_of=space_of,
                     bite=opts.get("bite") or "step", existed=existed, now=now)
    told = verdict is not None and verdict["mode"] == "act_and_tell"
    out = dict(landed, state="written", written=True, mode=mode, told=told,
               done_bar_changed=inputs["done_bar"] != block["done_bar"])
    if told:
        out["tell"] = (f"Amended the goal doc of {item_key} to goal version {landed['goal_version']} "
                       f"(contract v{landed['contract_version']}).")
    programme_journal.append(programme_run, JOURNAL_KIND, sid,
                             {"item": item_key, "mode": mode, "goal_version": landed["goal_version"],
                              "contract_version": landed["contract_version"], "told": told,
                              "tell": out.get("tell"), "path": landed["path"]})
    return out


def _resolve(host, opts, positional, usage):
    if len(positional) != 1:
        raise ValueError(usage)
    run_id, home, record = host._locate(opts)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    record_mod = load_lib_module("programme_record")
    key = record_mod._resolve(programme, record_mod.check_item_id(positional[0]))
    return run_id, home, programme, key


_WRITE_USAGE = ("usage: write-goal <id> [--plan <path>] [--title <text>] [--outcome <text>]... "
                "[--out-of-scope <text>]... [--manual-step <text>]... [--done-internal <names>] "
                "[--done-external <names>] [--bite pulse|step] [--approved <ask id>] [--run <id>]")


def _h_write_goal(host, argv):
    positional, opts = host._parse(
        argv, values=("run", "plan", "title", "done-internal", "done-external", "bite", "approved"),
        multi=("outcome", "out-of-scope", "manual-step"))
    with refusals(host):
        run_id, home, _, key = _resolve(host, opts, positional, _WRITE_USAGE)
        out = write_goal(run_id, key, opts)
    host.refresh_view(run_id, home)
    host._emit(dict(out, ok=True, run=run_id, item=key, kind=JOURNAL_KIND))
    return 0


def _h_goal_status(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    with refusals(host):
        run_id, _, programme, key = _resolve(host, opts, positional, "usage: goal-status <id> [--run <id>]")
        repo, auto_run, _, _ = _bound_run(programme["items"][key], key)
        out = reading(repo, auto_run)
    host._emit(dict(out, ok=True, run=run_id, item=key))
    return 0


_SPECS = (
    ("write-goal", _h_write_goal,
     "<id> [--plan <path>] [--title <text>] [--outcome <text>]... [--out-of-scope <text>]... "
     "[--manual-step <text>]... [--done-internal <names>] [--done-external <names>] [--bite pulse|step] "
     "[--approved <ask id>] [--run <id>]",
     "any caller but the programme's driving session holding its lease; a worker outside the remit; an item with "
     "no bound Auto run or a run with no contract or a done run; a done bar that includes a step only a human can "
     "do (a non-terminal step with a human verification criterion, or a --manual-step), which the refusal names; "
     "an amendment when goal_amend reads never; an amendment when goal_amend reads propose, which hands a Shawn "
     "ask and writes nothing until it returns with --approved <ask id>. Creates the goal doc or amends it in "
     "place, bumps the contract version and the goal version, and journals the write; act_and_tell adds a tell."),
    ("goal-status", _h_goal_status, "<id> [--run <id>]",
     "an item with no bound Auto run. Reports none, current or goal-stale, computed at read time."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
