#!/usr/bin/env python3
# Prints every read of the Ruling store, one JSON line per consumer, over one programme that holds each
# Ruling shape: active, expired, pending, carried, closed, legacy, kind-less, aliased and finished targets.
# Item herdr:a sits in a repo whose project layer holds tool_choice at propose; herdr:c in one with no layer.
import json, os, subprocess, sys
root, work = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "lib"))
from _bootstrap import load_lib_module
P = load_lib_module("programme")
ph = load_lib_module("programme_home")
pc = load_lib_module("programme_context")
pred = load_lib_module("programme_predicate")
carry = load_lib_module("programme_carryover")
va = load_lib_module("programme_view_agreement")
rec_mod = load_lib_module("programme_recovery")
pchg = load_lib_module("programme_protocol_changes")
pdec = load_lib_module("programme_decisions")

NOW = "2026-10-22T08:00:00Z"
PAST, FUTURE = "2026-01-01T00:00:00Z", "2099-01-01T00:00:00Z"
r1, r2 = os.path.join(work, "r1"), os.path.join(work, "r2")


def git(*a, cwd=None):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *a], cwd=cwd, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
seed = os.path.join(work, "seed")
if not os.path.isdir(r1):
    os.makedirs(os.path.join(seed, ".claude"))
    with open(os.path.join(seed, ".claude", "auto-protocol.json"), "w") as fh:
        json.dump({"protocol_format": 1, "autonomy": {"tool_choice": {"level": "propose"}}}, fh)
    git("init", "-q", "-b", "main", cwd=seed); git("add", "-A", cwd=seed); git("commit", "-q", "-m", "s", cwd=seed)
    git("clone", "-q", "--bare", seed, os.path.join(work, "bare.git"))
    git("clone", "-q", os.path.join(work, "bare.git"), r1)
os.makedirs(r2, exist_ok=True)
with open(os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"], "w") as fh:
    json.dump({"protocol_format": 1, "autonomy": {"merge_at_gate": {"level": "act_and_tell"}}}, fh)

def rev(n, state="accepted", **kw):
    base = {"rev": n, "state": state, "at": "2026-10-01T00:00:00Z", "scope": f"scope {n}", "reason": None,
            "limits": [], "requirements": [], "source": {"prompt_id": f"p{n}"}, "quote": f"quote {n}",
            "baseline": None}
    base.update(kw)
    return base

decisions = {
    "g-active": [rev(1, kind="tool_choice", effect="grant", applies_to=["herdr:a", "herdr:old-c"], baseline="act",
                     until=FUTURE, limits=["no majors"])],
    "g-none": [rev(1, kind="tool_choice", effect="grant", until=None)],
    "r-empty": [rev(1, kind="tool_choice", effect="restrict", applies_to=[], until=None)],
    "r-item": [rev(1, kind="work_sequencing", effect="restrict", applies_to=["herdr:a"], until=None)],
    "p-wide": [rev(1, kind="technical_approach", effect="decided", applies_to=["programme"], until=None)],
    "g-expired": [rev(1, kind="tool_choice", effect="grant", applies_to=["herdr:a"], until=PAST, baseline="act")],
    "g-pending": [rev(1, state="pending_acceptance", kind="tool_choice", effect="grant", applies_to=["herdr:c"],
                      until=None)],
    "g-two": [rev(1, kind="file_issue", effect="grant", applies_to=["herdr:c"], until=None, baseline="propose"),
              rev(2, state="pending_acceptance", kind="file_issue", effect="grant", applies_to=["herdr:c", "herdr:a"],
                  until=None)],
    "k-carried": [dict(rev(1, state="pending_acceptance", kind="tool_choice", effect="grant", applies_to=[],
                           until=None, quote=None), carried={"from": "repo-x", "run_id": "old-run", "entry": "k1"})],
    "g-closed": [dict(rev(1, state="closed", kind="tool_choice", effect="grant", applies_to=["herdr:a"], until=None),
                      closed={"as": "withdrawn"})],
    "l-instr": [rev(1, kind=None, effect="decided", legacy="instruction", applies_to=["herdr:a"], until=None,
                    quote="skip the eval for herdr:a", reason="waive eval")],
    "l-pt": [rev(1, kind=None, effect="restrict", legacy="project_term", area="deploys", applies_to=None,
                 until=None, scope="Shawn deploys")],
    "l-pt-old": [rev(1, kind=None, effect="restrict", legacy="project_term", area="pricing", applies_to=["programme"],
                     until=PAST, scope="pricing copy")],
    "d-record": [rev(1, applies_to=["herdr:a"])],
    "g-done": [rev(1, kind="tool_choice", effect="grant", applies_to=["herdr:b"], until=None, baseline="act")],
    "g-wide": [rev(1, kind="merge_at_gate", effect="grant", applies_to=["programme"], until=None, baseline="act")],
    "w-waiver": [rev(1, kind="eval_waiver", effect="decided", applies_to=["herdr:a"], until=None)],
    "g-empty": [rev(1, kind="merge_at_gate", effect="grant", applies_to=[], until=None, baseline="act")],
    "g-ghost": [rev(1, kind="merge_at_gate", effect="grant", applies_to=["herdr:gone"], until=None, baseline="act")],
    "g-norepo": [rev(1, kind="tool_choice", effect="grant", applies_to=["herdr:d"], until=None, baseline="act")],
}
programme = {
    "items": {"herdr:a": {"state": "open", "repo": r1, "title": "a"},
              "herdr:b": {"state": "done", "repo": r1, "title": "b"},
              "herdr:c": {"state": "open", "repo": r2, "title": "c", "aliases": ["herdr:old-c"]},
              "herdr:d": {"state": "open", "title": "d"}},
    "remit": {"repos": [{"path": r1, "key": "r1"}, {"path": r2, "key": "r2"}]},
    "context": {"decisions": decisions},
}
programme = ph.normalize_programme(programme)
out = {}
out["rules_view"] = P.active_rulings(programme, NOW)
out["rules_view_no_now"] = [r["id"] for r in P.active_rulings(programme)]
gate = {}
for item in ("herdr:a", "herdr:b", "herdr:c", "herdr:old-c", "herdr:d", "programme"):
    for kind in ("tool_choice", "work_sequencing", "technical_approach", "file_issue", "merge_at_gate", None):
        gate[f"{item}/{kind}"] = pc.rulings_for(programme, item, kind, NOW)
out["gate"] = gate
dt = load_lib_module("run_record_core").parse_iso(NOW)
out["offer"] = carry.offer(programme, NOW)
out["unoffered"] = pred.unoffered_rulings(programme, dt)
out["page"] = va.rulings(programme, NOW)
out["page_dt"] = va.rulings(programme, dt)
out["page_none"] = va.rulings(programme)
record = {"run_id": "run-pin", "programme": programme}
pkt = rec_mod.packet("run-pin", 7, record, objects=False)
out["binding"] = pkt["binding"]["rulings"]
protocol = load_lib_module("programme_protocol").load()
rules = P.rules_in_force(record, {}, protocol, changes=False, behaviours=False)
out["legacy_restricts"] = rules.get("legacy_restricts")
out["rules_rulings"] = [r["id"] for r in rules["rulings"]]
out["conflicts"] = pchg.report(P, programme, {}, protocol).get("conflicts")
gates = {}
for kind in ("tool_choice", "work_sequencing", "merge_at_gate", "file_issue", "eval_waiver"):
    for target in ("herdr:a", "herdr:c", "herdr:d", "programme"):
        try:
            prot = pdec._check_pm_may_decide(P, programme, kind, target)
            gates[f"{kind}/{target}"] = "ok " + str((prot["autonomy"].get(kind) or {}).get("level"))
        except Exception as exc:
            gates[f"{kind}/{target}"] = type(exc).__name__ + ": " + str(exc)
out["pm_may_decide"] = gates
src = load_lib_module("programme_sources")
ev = load_lib_module("programme_evidence")
traj = load_lib_module("programme_trajectory")
briefs = {}
for key in ("herdr:a", "herdr:c", "herdr:d"):
    for cited in ([], ["g-active"], ["g-two", "l-instr"]):
        try:
            briefs[f"{key}/{','.join(cited)}"] = src._brief_tail(P, programme, key, cited, [], rulings=True)
        except Exception as exc:
            briefs[f"{key}/{','.join(cited)}"] = type(exc).__name__ + ": " + str(exc)
out["brief"] = briefs
out["waivers"] = {k: [r["id"] for r in ev._context(P, programme, k, "released", None)["waivers"]]
                  for k in ("herdr:a", "herdr:c")}
out["clauses"] = sorted(traj.allowed_clauses(rules, P.active_rulings(programme, NOW)))
for key in sorted(out):
    print(json.dumps({key: out[key]}, sort_keys=True, default=str))
