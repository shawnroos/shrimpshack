"""Read whether an open PR is ready to merge, and optionally pin the head Shawn approved."""

import functools
import json
import shutil

from _bootstrap import load_lib_module

programme_evidence = load_lib_module("programme_evidence")
programme_home = load_lib_module("programme_home")
programme_record = load_lib_module("programme_record")
programme_store = load_lib_module("programme_store")

Unknown = programme_evidence.Unknown

_QUERY = (
    "query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name)"
    "{pullRequest(number:$number){state isDraft mergeable mergeStateStatus reviewDecision "
    "baseRefName headRefOid title url "
    "reviewThreads(first:100){totalCount nodes{isResolved}} "
    "commits(last:1){nodes{commit{oid statusCheckRollup{state contexts(first:100){totalCount "
    "nodes{__typename ... on CheckRun{name status conclusion isRequired(pullRequestNumber:$number)} "
    "... on StatusContext{context state isRequired(pullRequestNumber:$number)}}}}}}}}}}"
)
_NOT_COMPUTED = (None, "", "UNKNOWN")
_BLOCKING_REVIEW = ("CHANGES_REQUESTED", "REVIEW_REQUIRED")


def canonical_ref(ref) -> str:
    owner, name, number = programme_evidence.parse_pr_ref(ref)
    return f"{owner}/{name}#{number}"


def _read(ref):
    owner, name, number = programme_evidence.parse_pr_ref(ref)
    env = programme_evidence._gh_env()
    if shutil.which("gh", path=env["PATH"]) is None:
        raise Unknown("gh is not on PATH")
    graph = programme_evidence._run_json(
        ["gh", "api", "graphql", "-f", "query=" + _QUERY, "-f", f"owner={owner}",
         "-f", f"name={name}", "-F", f"number={number}"], env)
    if graph.get("errors"):
        raise Unknown("GitHub refused the query: " + json.dumps(graph["errors"])[:300])
    pr = programme_evidence._dig(graph, "data", "repository", "pullRequest")
    if not isinstance(pr, dict) or not pr.get("headRefOid"):
        raise Unknown("GitHub returned no pull request")
    no_ci = programme_evidence.head_context_count(pr) == 0 and not programme_evidence.repo_has_ci(owner, name, env)
    return pr, no_ci


def _bar(pr, no_ci=False) -> dict:
    threads = pr.get("reviewThreads") or {}
    nodes = threads.get("nodes") or []
    if not isinstance(threads.get("totalCount"), int) or threads["totalCount"] > len(nodes):
        raise Unknown("review threads past the first page; the unresolved count is not known")
    commits = programme_evidence._dig(pr, "commits", "nodes") or []
    head = programme_evidence._dig(commits[-1], "commit") if commits else None
    if not isinstance(head, dict) or head.get("oid") != pr.get("headRefOid"):
        raise Unknown("GitHub's head commit and the PR head disagree")
    contexts = programme_evidence._dig(head, "statusCheckRollup", "contexts") or {"totalCount": 0, "nodes": []}
    if not isinstance(contexts.get("totalCount"), int) or contexts["totalCount"] > len(contexts.get("nodes") or []):
        raise Unknown("checks past the first page; the head's checks are not all read")
    checks = programme_evidence._check_outcomes(contexts.get("nodes") or [])
    unresolved = sum(1 for n in nodes if isinstance(n, dict) and n.get("isResolved") is False)
    facts = {"state": pr.get("state"), "draft": pr.get("isDraft") is True,
             "mergeable": pr.get("mergeable"), "merge_state": pr.get("mergeStateStatus"),
             "review": pr.get("reviewDecision"), "base": pr.get("baseRefName"),
             "head": pr.get("headRefOid"), "title": pr.get("title"), "url": pr.get("url"),
             "unresolved_threads": unresolved, "checks": checks}
    if no_ci and not checks:
        facts["ci"] = "none"
    facts["fingerprint"] = fingerprint(facts)
    if facts["state"] == "MERGED":
        return dict(facts, result="not_ready", gates=["already merged"], ended=True)
    if facts["state"] != "OPEN":
        return dict(facts, result="not_ready", gates=[f"PR is {facts['state']}"], ended=True)
    if facts["mergeable"] in _NOT_COMPUTED or facts["merge_state"] in _NOT_COMPUTED:
        raise Unknown("GitHub has not computed the merge state yet")
    if not checks and not no_ci:
        raise Unknown("the head has no checks to read")
    gates = []
    if facts["draft"]:
        gates.append("draft")
    if facts["merge_state"] != "CLEAN":
        gates.append(f"merge state {facts['merge_state']}")
    if facts["mergeable"] == "CONFLICTING":
        gates.append("conflicts with the base branch")
    if facts["review"] in _BLOCKING_REVIEW:
        gates.append(f"review {facts['review']}")
    unmet = [f"{c['name']} {c['outcome']}" for c in checks
             if c["required"] and c["outcome"] not in programme_evidence.REQUIRED_MET]
    if unmet:
        gates.append("required checks not met: " + ", ".join(unmet))
    bad = [f"{c['name']} {c['outcome']}" for c in checks
           if not c["required"] and c["outcome"] in programme_evidence.BAD_OUTCOMES]
    if bad:
        gates.append("checks cancelled or failed: " + ", ".join(bad))
    if unresolved:
        gates.append(f"{unresolved} unresolved review threads")
    return dict(facts, result="not_ready" if gates else "ready", gates=gates)


def fingerprint(facts) -> str:
    basis = {k: facts.get(k) for k in ("head", "base", "merge_state", "mergeable", "review", "draft",
                                       "unresolved_threads", "state")}
    basis["checks"] = sorted([str(c.get("name")), str(c.get("outcome"))] for c in facts.get("checks") or [])
    return programme_store.digest_of(basis)[:16]


def check_mergeable(ref, remit_repos=None) -> dict:
    try:
        pr_ref = canonical_ref(ref)
        programme_evidence._require_remit_repo(pr_ref, remit_repos)
        verdict = _bar(*_read(pr_ref))
    except Unknown as exc:
        return {"result": "unknown", "pr": ref, "gates": [], "note": str(exc)}
    except Exception as exc:  # noqa: BLE001 — any read failure is "unknown", never "ready"
        return {"result": "unknown", "pr": ref, "gates": [], "note": f"{type(exc).__name__}: {exc}"}
    return dict(verdict, pr=pr_ref)


def _h_check_mergeable(host, argv):
    positional, opts = host._parse(argv, values=("run", "pin"))
    if len(positional) != 1:
        raise ValueError("usage: check-mergeable <pr> [--pin <item>] [--run <id>]")
    try:
        canonical_ref(positional[0])
    except Unknown as exc:
        raise programme_record.RecordError(str(exc))
    run_id, home, record = host._locate(opts)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    repos = list((programme.get("remit") or {}).get("repos") or [])
    verdict = check_mergeable(positional[0], repos)
    if not opts.get("pin"):
        host._emit(verdict)
        return 0
    item_id = programme_record.check_item_id(opts["pin"])
    if verdict["result"] != "ready":
        host._emit(verdict)
        raise programme_record.RecordError(f"not pinned: the PR is {verdict['result']}")

    def change(programme, prompt, rec):
        key = programme_record._resolve(programme, item_id)
        return {"item": key, "ref": verdict["pr"], "head": verdict["head"],
                "fingerprint": verdict["fingerprint"], "result": verdict["result"]}

    return host._write(dict(opts, run=run_id), change, "merge_pinned")


_SPECS = (
    ("check-mergeable", _h_check_mergeable, "<pr> [--pin <item>] [--run <id>]",
     "a reference that is not a PR; with --pin, a PR that is not ready. Without --pin it writes "
     "nothing; with --pin it journals merge_pinned with the item, the owner/repo#N ref and the head."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
