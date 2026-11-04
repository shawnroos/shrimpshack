"""Test helper: give a task run record a contract and append PM changes to it, through the run-record lock."""

import os
import sys

_LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib")
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)
from _bootstrap import load_lib_module  # noqa: E402

core = load_lib_module("run_record_core")
wc = load_lib_module("worker_contract")

AUTHORITY = {"technical_approach": {"mode": "act", "asks": "pm"}, "product_scope": {"mode": "act", "asks": "pm"}}
DONE_BAR = {"internal": ["steps_terminal"], "external": []}


def add_contract(repo, run, *, cap=3, applied=0, authority=None, workflow="a2"):
    block = wc.new_contract(set_by="sess-pm", authority=authority or AUTHORITY, done_bar=DONE_BAR,
                            workflow=workflow, fan_out_cap=cap)
    block["applied_version"] = applied
    core._with_locked_run_record(repo, run, lambda rec: rec.__setitem__("contract", wc.validate(block)))


def request_change(repo, run, bite, **changes):
    def mutate(rec):
        block = rec["contract"]
        block["version"] += 1
        block.update(changes)
        block.setdefault("pending_versions", []).append({"version": block["version"], "bite": bite})
        wc.validate(block)

    core._with_locked_run_record(repo, run, mutate)
