#!/usr/bin/env python3
"""Programme evidence: run a deliverable's checker and store its three-state result.

``programme.py`` registers ``check-deliverable`` and ``validate`` through
``build_verbs(host)``. No verb takes a result as an argument: a deliverable is
confirmed only by its checker reading the source system.
"""

from __future__ import annotations

import datetime
import functools
import json
import os
import re
import secrets
import shutil
import subprocess
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_predicate = load_lib_module("programme_predicate")
programme_record = load_lib_module("programme_record")
programme_sanitize = load_lib_module("programme_sanitize")
programme_protocol = load_lib_module("programme_protocol")
driver_session = load_lib_module("driver_session")
verification = load_lib_module("verification")

TIMEOUT_ENV = "CLAUDE_AUTO_CHECK_TIMEOUT_SECONDS"
DEFAULT_TIMEOUT_SECONDS = 30
OUTPUT_CAP_BYTES = 1 << 20
NOTE_CAP = 500
FINAL_AFTER_SECONDS = 7 * 24 * 3600
UNKNOWNS_BEFORE_WAIT = 2
SYSTEM_WHO = "system"
RETRY_ACTION = "arm_retry_watcher"
LINEAR_URL = "https://api.linear.app/graphql"
LINEAR_KEY = "LINEAR_API_KEY"
GH_KEYS = ("GH_TOKEN", "GITHUB_TOKEN")
DONE_STATE_TYPES = ("completed",)
PASSING = ("SUCCESS",)
BAD_OUTCOMES = ("CANCELLED", "SKIPPED", "FAILURE", "TIMED_OUT", "ACTION_REQUIRED",
                "STARTUP_FAILURE", "STALE", "ERROR")
FROZEN_AT_DONE = ("flagged",)
CHECKERS = ("merged", "recorded", "flagged", "verified", "released")
LD_KEY = "LD_ACCESS_TOKEN"
BT_KEY = "BRAINTRUST_API_KEY"
LD_DEFAULT_PROJECT = "default"
FLAG_BAR = (("production", False), ("stage", True), ("development", True))
FLAG_EXCEPTIONS = ("rules", "targets", "contextTargets")
_PR_REF = re.compile(r"(?:https://github\.com/)?([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(?:#|/pull/)([0-9]+)/?")
_ISSUE_REF = re.compile(r"(?:linear:)?([A-Z][A-Z0-9]*)-([0-9]+)")
_ROOT_CAUSE = re.compile(r"root[ -]cause", re.IGNORECASE)
_FLAG_REF = re.compile(r"(?:([A-Za-z0-9._-]+)/)?([A-Za-z0-9._-]+)")
_EXPERIMENT_REF = re.compile(r"bt:([^/\s]+)/(\S+)")
_SHA = re.compile(r"(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])")
_WAIVER = re.compile(r"waiv", re.IGNORECASE)

_PR_QUERY = (
    "query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name)"
    "{pullRequest(number:$number){state merged mergeCommit{oid} headRefOid "
    "reviewThreads(first:100){totalCount nodes{isResolved}} "
    "commits(last:1){nodes{commit{oid statusCheckRollup{state contexts(first:100){totalCount "
    "nodes{__typename ... on CheckRun{name status conclusion isRequired(pullRequestNumber:$number)} "
    "... on StatusContext{context state isRequired(pullRequestNumber:$number)}}}}}}}}}}"
)
_ISSUE_QUERY = (
    "query($team:String!,$number:Float!){issues(first:5,filter:{team:{key:{eq:$team}},"
    "number:{eq:$number}}){nodes{identifier state{name type} "
    "comments(first:50,filter:{or:[{body:{containsIgnoreCase:\"root cause\"}},"
    "{body:{containsIgnoreCase:\"root-cause\"}}]}){nodes{body createdAt user{id name} "
    "botActor{id name} externalUser{id}}}}}}"
)
# The key reaches curl on stdin (-H @-), never in an argv a process list can show.
_CURL_SCRIPT = ('printf "Authorization: %s\\n" "$LINEAR_API_KEY" | curl -sS --max-time "$2" -H @- '
                '-H "Content-Type: application/json" --data-binary "$1" "$3"')


class Unknown(Exception):
    pass


def _timeout() -> int:
    try:
        value = int(os.environ.get(TIMEOUT_ENV) or DEFAULT_TIMEOUT_SECONDS)
    except ValueError:
        return DEFAULT_TIMEOUT_SECONDS
    return value if value > 0 else DEFAULT_TIMEOUT_SECONDS


def secret(name, path=None):
    try:
        assignments = programme_journal.secret_assignments(path)
    except (OSError, UnicodeDecodeError):
        return None
    found = None
    for key, value in assignments:
        if key == name:
            found = programme_journal.unquote(value) or None
    return found


def _base_env(home=False) -> dict:
    env = {"PATH": os.environ.get("PATH") or "/usr/bin:/bin"}
    if home and os.environ.get("HOME"):
        env["HOME"] = os.environ["HOME"]
    return env


def _note(*parts) -> str:
    text = " ".join(p.decode("utf-8", "replace") if isinstance(p, bytes) else str(p or "")
                    for p in parts).strip()
    return programme_journal.redact(text)[:NOTE_CAP]


def _run(argv, env, cwd=None) -> dict:
    run = verification.run_capped(argv, cwd=cwd, timeout=_timeout(), env=env, cap=OUTPUT_CAP_BYTES,
                                   stdin=subprocess.DEVNULL)
    if not run["ran"]:
        raise Unknown(_note(run["error"]))
    if run["truncated"]:
        raise Unknown(f"{argv[0]} output passed {OUTPUT_CAP_BYTES} bytes")
    return run


def _failed(argv, run):
    return Unknown(_note(f"{argv[0]} exited {run['exit_code']}:", run["stderr"], run["stdout"]))


def _json_of(argv, run):
    try:
        doc = json.loads(run["stdout"].decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise Unknown(_note(f"{argv[0]} gave no JSON:", run["stdout"][:200]))
    if not isinstance(doc, dict):
        raise Unknown(f"{argv[0]} gave JSON that is not an object")
    return doc


def _run_json(argv, env, cwd=None):
    run = _run(argv, env, cwd)
    if run["exit_code"] != 0:
        raise _failed(argv, run)
    return _json_of(argv, run)


def _need(tool, env) -> None:
    if shutil.which(tool, path=env["PATH"]) is None:
        raise Unknown(f"{tool} is not on PATH")


def _dig(doc, *path):
    for key in path:
        if not isinstance(doc, dict):
            return None
        doc = doc.get(key)
    return doc


def parse_pr_ref(ref):
    match = _PR_REF.fullmatch(ref or "")
    if not match:
        raise Unknown(f"merged needs a PR reference owner/repo#N or a PR URL, got {ref!r}")
    return match.group(1), match.group(2), int(match.group(3))


def _gh_env() -> dict:
    env = _base_env(home=True)
    for name in GH_KEYS:
        token = secret(name)
        if token:
            env["GH_TOKEN"] = token
            break
    return env


def _check_outcomes(contexts) -> list:
    out = []
    for node in contexts:
        if not isinstance(node, dict):
            continue
        if node.get("__typename") == "CheckRun":
            outcome = node.get("conclusion") if node.get("status") == "COMPLETED" else "PENDING"
            out.append({"name": node.get("name"), "run": True, "outcome": outcome or "PENDING",
                        "required": node.get("isRequired") is True})
        else:
            out.append({"name": node.get("context"), "run": False, "outcome": node.get("state") or "PENDING",
                        "required": node.get("isRequired") is True})
    return out


def _merged_bar(view, pr, pin) -> dict:
    fields = {"state": view.get("state"), "merge_commit": _dig(view, "mergeCommit", "oid"),
              "head": view.get("headRefOid"), "merged_at": view.get("mergedAt"),
              "merged_by": _dig(view, "mergedBy", "login"), "url": view.get("url")}
    threads = pr.get("reviewThreads") or {}
    nodes = threads.get("nodes") or []
    if not isinstance(threads.get("totalCount"), int) or threads["totalCount"] > len(nodes):
        raise Unknown("review threads past the first page; the unresolved count is not known")
    commits = _dig(pr, "commits", "nodes") or []
    head = _dig(commits[-1], "commit") if commits else None
    if not isinstance(head, dict) or head.get("oid") != fields["head"]:
        raise Unknown("GitHub's two reads disagree on the merged head")
    contexts = _dig(head, "statusCheckRollup", "contexts") or {"totalCount": 0, "nodes": []}
    if not isinstance(contexts.get("totalCount"), int) or contexts["totalCount"] > len(contexts.get("nodes") or []):
        raise Unknown("checks past the first page; the merged head's checks are not all read")
    checks = _check_outcomes(contexts.get("nodes") or [])
    fields["unresolved_threads"] = sum(1 for n in nodes if isinstance(n, dict) and n.get("isResolved") is False)
    fields["checks"] = checks
    if any(c["outcome"] == "PENDING" for c in checks):
        raise Unknown("a check on the merged head has not finished")
    misses = []
    if fields["state"] != "MERGED" or not fields["merge_commit"]:
        misses.append("not merged with a merge commit")
    if pin is not None and pin != fields["head"]:
        misses.append(f"merged head {fields['head']} is not the pinned head {pin}")
    bad = [f"{c['name']} {c['outcome']}" for c in checks if c["outcome"] in BAD_OUTCOMES]
    if bad:
        misses.append("checks cancelled, skipped or failed on the merged head: " + ", ".join(bad))
    if not any(c["run"] and c["outcome"] in PASSING for c in checks):
        misses.append("no check run succeeded on the merged head")
    unmet = [c["name"] for c in checks if c["required"] and c["outcome"] not in PASSING]
    if unmet:
        misses.append("required checks not successful: " + ", ".join(map(str, unmet)))
    if fields["unresolved_threads"]:
        misses.append(f"{fields['unresolved_threads']} unresolved review threads")
    fields["pinned_head"] = pin
    return {"result": "refuted" if misses else "confirmed", "fields": fields, "misses": misses}


def check_merged(ref, pin=None) -> dict:
    owner, name, number = parse_pr_ref(ref)
    env = _gh_env()
    if shutil.which("gh", path=env["PATH"]) is None:
        raise Unknown("gh is not on PATH")
    view = _run_json(["gh", "pr", "view", str(number), "--repo", f"{owner}/{name}", "--json",
                      "headRefOid,mergeCommit,mergedAt,mergedBy,number,state,url"], env)
    graph = _run_json(["gh", "api", "graphql", "-f", "query=" + _PR_QUERY, "-f", f"owner={owner}",
                       "-f", f"name={name}", "-F", f"number={number}"], env)
    if graph.get("errors"):
        raise Unknown(_note("GitHub refused the query:", json.dumps(graph["errors"])[:300]))
    pr = _dig(graph, "data", "repository", "pullRequest")
    if not isinstance(pr, dict) or not view.get("headRefOid"):
        raise Unknown("GitHub returned no pull request")
    verdict = _merged_bar(view, pr, pin)
    verdict["fields"]["pr"] = f"{owner}/{name}#{number}"
    return verdict


def parse_issue_ref(ref):
    match = _ISSUE_REF.fullmatch(ref or "")
    if not match:
        raise Unknown(f"recorded needs a Linear issue key such as AI-123, got {ref!r}")
    return match.group(1), int(match.group(2))


def _comment_nodes(comments) -> list:
    if isinstance(comments, dict):
        comments = comments.get("nodes")
    return [c for c in comments or [] if isinstance(c, dict)]


def _issue_from_board(key):
    env = _base_env(home=True)
    if shutil.which("board", path=env["PATH"]) is None:
        return None
    try:
        doc = _run_json(["board", "linear", "issue", key, "--json"], env)
    except Unknown:
        return None
    issue = doc.get("issue") if isinstance(doc.get("issue"), dict) else doc
    if doc.get("error") or not isinstance(issue.get("state"), dict) or "comments" not in issue:
        return None
    return dict(issue, source="board")


def _issue_from_api(team, number):
    key = secret(LINEAR_KEY)
    if not key:
        raise Unknown(f"no {LINEAR_KEY} in the secrets file and no usable board")
    env = dict(_base_env(), **{LINEAR_KEY: key})
    if shutil.which("curl", path=env["PATH"]) is None:
        raise Unknown("curl is not on PATH")
    body = json.dumps({"query": _ISSUE_QUERY, "variables": {"team": team, "number": float(number)}})
    doc = _run_json(["/bin/sh", "-c", _CURL_SCRIPT, "sh", body, str(_timeout()), LINEAR_URL], env)
    if doc.get("errors"):
        raise Unknown(_note("Linear refused the query:", json.dumps(doc["errors"])[:300]))
    nodes = _dig(doc, "data", "issues", "nodes")
    if not isinstance(nodes, list):
        raise Unknown("Linear returned no issue list")
    hits = [n for n in nodes if isinstance(n, dict) and n.get("identifier") == f"{team}-{number}"]
    return dict(hits[0], source="api") if hits else None


def _person_root_cause(comments):
    for comment in comments:
        if not _ROOT_CAUSE.search(str(comment.get("body") or "")):
            continue
        if comment.get("botActor") or comment.get("externalUser") or not comment.get("user"):
            continue
        return {"author": _dig(comment, "user", "name"), "at": comment.get("createdAt")}
    return None


def check_recorded(ref) -> dict:
    team, number = parse_issue_ref(ref)
    key = f"{team}-{number}"
    issue = _issue_from_board(key) or _issue_from_api(team, number)
    if issue is None:
        raise Unknown(f"Linear has no issue {key}")
    state = issue.get("state") or {}
    comments = _comment_nodes(issue.get("comments"))
    fields = {"issue": key, "state": state.get("name"), "state_type": state.get("type"),
              "read_by": issue["source"], "root_cause_comment": _person_root_cause(comments),
              "bot_root_cause_comments": sum(1 for c in comments if _ROOT_CAUSE.search(str(c.get("body") or ""))
                                             and (c.get("botActor") or c.get("externalUser")))}
    misses = []
    if state.get("type") not in DONE_STATE_TYPES:
        misses.append(f"issue state {state.get('name')!r} is not a done state")
    if fields["root_cause_comment"] is None:
        misses.append("no root-cause comment written by a person")
    return {"result": "refuted" if misses else "confirmed", "fields": fields, "misses": misses}


def _variation(flag, index, where):
    variations = flag.get("variations")
    if isinstance(index, bool) or not isinstance(index, int) or not isinstance(variations, list) \
            or not 0 <= index < len(variations) or not isinstance(variations[index], dict):
        raise Unknown(f"{where}: variation {index!r} is not one of the flag's variations")
    value = variations[index].get("value")
    if not isinstance(value, bool):
        raise Unknown(f"{where}: the flag does not serve booleans")
    return value


def _served_by(flag, entry, where) -> set:
    if entry.get("variation") is not None:
        return {_variation(flag, entry["variation"], where)}
    weights = _dig(entry, "rollout", "variations")
    if not isinstance(weights, list):
        raise Unknown(f"{where} serves neither a variation nor a rollout")
    return {_variation(flag, w.get("variation"), where) for w in weights
            if isinstance(w, dict) and (w.get("weight") or 0) > 0}


def _env_served(flag, name, env) -> dict:
    if not isinstance(env, dict) or not isinstance(env.get("on"), bool):
        raise Unknown(f"the flag read has no {name} environment")
    if not env["on"]:
        return {"on": False, "served": _variation(flag, env.get("offVariation"), name), "others": []}
    fall = env.get("fallthrough") or {}
    if fall.get("variation") is None:
        raise Unknown(f"{name} serves a percentage rollout, not one value")
    others, counts = set(), {}
    for kind in FLAG_EXCEPTIONS:
        entries = [e for e in env.get(kind) or [] if isinstance(e, dict)]
        counts[kind] = len(entries)
        for entry in entries:
            others |= _served_by(flag, entry, f"{name} {kind}")
    if env.get("prerequisites"):
        others.add(_variation(flag, env.get("offVariation"), name))
    return dict(counts, on=True, served=_variation(flag, fall["variation"], name), others=sorted(others))


def check_flagged(ref) -> dict:
    match = _FLAG_REF.fullmatch(ref or "")
    if not match:
        raise Unknown(f"flagged needs a flag key or project/flag-key, got {ref!r}")
    project, key = match.group(1) or LD_DEFAULT_PROJECT, match.group(2)
    token = secret(LD_KEY)
    if not token:
        raise Unknown(f"no {LD_KEY} in the secrets file")
    env = dict(_base_env(), **{LD_KEY: token})
    _need("ldcli", env)
    flag = _run_json(["ldcli", "flags", "get", "--project", project, "--flag", key, "-o", "json"], env)
    envs = flag.get("environments")
    if not isinstance(envs, dict):
        raise Unknown("ldcli returned no environments")
    fields = {"flag": key, "project": project, "environments": {}}
    misses = []
    for name, want in FLAG_BAR:
        state = _env_served(flag, name, envs.get(name))
        fields["environments"][name] = dict(state, bar=want)
        if state["served"] != want:
            misses.append(f"{name} serves {str(state['served']).lower()}")
        elif (not want) in state["others"]:
            misses.append(f"{name} has a rule or target serving {str(not want).lower()}")
    return {"result": "refuted" if misses else "confirmed", "fields": fields, "misses": misses}


def _fill(argv, values) -> list:
    out = []
    for part in argv:
        for name, value in values.items():
            part = part.replace("{" + name + "}", value)
        out.append(part)
    return out


def _repo_keys(item, repo) -> list:
    keys = []
    pr = _dig(item, "deliverables", "merged", "fields", "pr") or _dig(item, "deliverables", "merged", "ref")
    match = _PR_REF.fullmatch(pr or "")
    if match:
        keys.append(f"{match.group(1)}/{match.group(2)}")
    if repo:
        keys.append(os.path.realpath(repo))
    return keys


def _commands(checks, keys):
    for key in keys:
        block = (checks or {}).get(key) or {}
        if all(name in block for name in programme_protocol.CHECK_KEYS):
            return key, {name: block[name]["argv"] for name in programme_protocol.CHECK_KEYS}
    raise Unknown("no adopted verified.lookup and verified.deployed_sha for this repo; a claim alone "
                  "never verifies")


def _adopted_output(argv, cwd) -> str:
    run = _run(argv, _base_env(home=True), cwd)
    if run["exit_code"] != 0:
        raise _failed(argv, run)
    text = run["stdout"].decode("utf-8", "replace").strip()
    if not text:
        raise Unknown(f"{argv[0]} printed nothing")
    return text


def check_verified(ref, context) -> dict:
    item, repo = context.get("item") or {}, context.get("repo")
    merged = _dig(item, "deliverables", "merged") or {}
    merge_commit = _dig(merged, "fields", "merge_commit")
    if merged.get("result") != "confirmed" or not merge_commit:
        raise Unknown("verified needs merged confirmed first, with its merge commit")
    repo_key, argv = _commands(context.get("checks"), _repo_keys(item, repo))
    if not repo:
        raise Unknown("verified needs --repo <clone> to test that the build contains the merge commit")
    values = {"id": ref, "sha": merge_commit, "repo": repo_key}
    lookup = _adopted_output(_fill(argv["verified.lookup"], values), repo)
    shas = _SHA.findall(_adopted_output(_fill(argv["verified.deployed_sha"], values), repo))
    if not shas:
        raise Unknown("verified.deployed_sha printed no 40-character commit sha")
    build = shas[0]
    fields = {"id": ref, "repo": repo_key, "repo_path": os.path.realpath(repo), "merge_commit": merge_commit,
              "build_sha": build, "lookup": _note(lookup)}
    git = ["git", "-C", fields["repo_path"], "merge-base", "--is-ancestor", merge_commit, build]
    run = _run(git, _base_env(home=True))
    if run["exit_code"] not in (0, 1):
        raise Unknown(_note(f"the clone cannot compare {build} with the merge commit:", run["stderr"]))
    misses = [] if run["exit_code"] == 0 else [f"build {build} does not contain the merge commit {merge_commit}"]
    return {"result": "refuted" if misses else "confirmed", "fields": fields, "misses": misses}


def _registry(build, repo) -> dict:
    env = _base_env(home=True)
    _need("npm", env)
    spec = f"{build['package']}@{build['version']}"
    argv = ["npm", "view", spec, "dist.shasum", "dist.integrity", "version", "--json"]
    run = _run(argv, env, os.path.realpath(repo) if repo else None)
    if run["exit_code"] == 0:
        return _json_of(argv, run)
    try:
        code = _dig(_json_of(argv, run), "error", "code")
    except Unknown:
        code = None
    if code == "E404" and repo:
        return {"missing": spec}
    raise _failed(argv, run)


def _experiment(ref):
    match = _EXPERIMENT_REF.fullmatch(ref or "")
    if not match:
        return None
    project, name = match.group(1), match.group(2)
    env = _base_env(home=True)
    key = secret(BT_KEY)
    if key:
        env[BT_KEY] = key
    _need("bt", env)
    argv = ["bt", "experiments", "view", name, "--project", project, "--json", "--no-input"]
    run = _run(argv, env)
    try:
        doc = _json_of(argv, run)
    except Unknown:
        raise _failed(argv, run) if run["exit_code"] else Unknown("bt gave no JSON")
    message = str(_dig(doc, "error", "message") or "")
    if run["exit_code"] == 0 and not doc.get("error"):
        return {"experiment": name, "experiment_project": project, "experiment_id": doc.get("id")}
    if "not found" in message.lower():
        return {"experiment": name, "experiment_project": project, "experiment_id": None}
    raise Unknown(_note(f"bt exited {run['exit_code']}:", message or run["stderr"]))


def check_released(ref, context) -> dict:
    item, repo = context.get("item") or {}, context.get("repo")
    build = item.get("tested_build") or {}
    if not all(build.get(k) for k in ("shasum", "package", "version")):
        raise Unknown("no tested build with a package and version; run record-tested-build first")
    doc = _registry(build, repo)
    tested = build["shasum"]
    published = doc.get("dist.integrity") if "-" in tested else doc.get("dist.shasum")
    fields = {"package": build["package"], "version": build["version"], "tested_shasum": tested,
              "registry_shasum": published, "registry_version": doc.get("version"),
              "repo_path": os.path.realpath(repo) if repo else None, "waiver": None, "experiment": None}
    misses = []
    if doc.get("missing"):
        misses.append(f"the registry has no {doc['missing']}")
    elif published != tested:
        misses.append(f"registry shasum {published} does not match the tested shasum {tested}")
    elif doc.get("version") != build["version"]:
        misses.append(f"registry version {doc.get('version')} is not the tested version {build['version']}")
    if misses:
        return {"result": "refuted", "fields": fields, "misses": misses}
    waivers = context.get("waivers") or []
    if waivers:
        fields["waiver"] = waivers[0].get("id")
    else:
        found = _experiment(ref)
        if found is None:
            misses.append("no eval experiment and no active waiver")
        else:
            fields.update(found)
            if not found["experiment_id"]:
                misses.append(f"no eval experiment {found['experiment']} in {found['experiment_project']}")
    return {"result": "refuted" if misses else "confirmed", "fields": fields, "misses": misses}


def _pin_for(run_id, item, ref):
    pin = None
    for row in programme_journal.read(run_id):
        payload = row.get("payload") or {}
        if row.get("kind") == "merge_pinned" and payload.get("item") == item and payload.get("ref") == ref:
            pin = payload.get("head")
    return pin


def run_check(run_id, item, deliverable, ref, context=None) -> dict:
    context = context or {}
    try:
        if deliverable == "merged":
            verdict = check_merged(ref, pin=_pin_for(run_id, item, ref))
        elif deliverable == "recorded":
            verdict = check_recorded(ref)
        elif deliverable == "flagged":
            verdict = check_flagged(ref)
        elif deliverable == "verified":
            verdict = check_verified(ref, context)
        elif deliverable == "released":
            verdict = check_released(ref, context)
        else:
            raise Unknown(f"no checker for {deliverable!r}")
    except Unknown as exc:
        return {"result": "unknown", "fields": {}, "misses": [], "note": str(exc)}
    except Exception as exc:  # noqa: BLE001 -- a checker bug must read as unknown, never confirmed
        return {"result": "unknown", "fields": {}, "misses": [], "note": _note(type(exc).__name__, exc)}
    return dict(verdict, note=None)



def _ref_token(value):
    if value is None:
        return None
    ref = programme_sanitize.token(value)
    if ref is None:
        raise programme_record.RecordError(f"--ref must be one short word with no spaces: {value!r}")
    return ref


def _resolve(programme, item_id) -> str:
    items = programme.get("items") or {}
    if item_id in items:
        return item_id
    for key, item in items.items():
        if item_id in (item.get("aliases") or []):
            return key
    raise programme_record.RecordError(f"no item {item_id!r} in this programme")


def _claimed_ref(home, key, deliverable):
    ref = None
    for row in programme_journal.read_path(programme_record.claims_path(home)):
        payload = row.get("payload") or {}
        if payload.get("item") == key and payload.get("deliverable") == deliverable:
            ref = payload.get("ref")
    return ref


def _default_ref(key, deliverable, item):
    source, _, rest = key.partition(":")
    if deliverable == "recorded" and source == "linear":
        return rest
    if deliverable == "merged" and source in ("github", "pr"):
        return rest
    if deliverable == "verified":
        wait = item.get("waiting_on") or {}
        return wait.get("trace_id") or wait.get("job_id")
    build = item.get("tested_build") or {}
    if deliverable == "released" and build.get("package") and build.get("version"):
        return f"{build['package']}@{build['version']}"
    return None


def _repo_arg(value):
    if value is None:
        return None
    if not os.path.isdir(value):
        raise ValueError(f"--repo must be a local clone directory, got {value!r}")
    return os.path.realpath(value)


def _context(host, programme, key, deliverable, repo, cache=None) -> dict:
    item = programme["items"][key]
    context = {"item": item, "repo": repo, "checks": {}, "waivers": []}
    if deliverable == "verified":
        cache = {} if cache is None else cache
        keys = _repo_keys(item, None)
        mark = (repo, keys[0] if keys else None)
        if mark not in cache:
            cache[mark] = programme_protocol.load(repo_path=repo, repo_key=mark[1],
                                                  prompt_lookup=host.prompt_lookup)["checks"]
        context["checks"] = cache[mark]
    if deliverable == "released":
        context["waivers"] = [e for e in host.active_instructions(programme) if e.get("applies_to") == key
                              and _WAIVER.search(f"{e.get('quote') or ''} {e.get('why') or ''}")]
    return context


def _age(stamp, now):
    when = run_record_core.parse_iso(stamp) if isinstance(stamp, str) else None
    return None if when is None else (now - when).total_seconds()


def _slug(key) -> str:
    return "retry-" + re.sub(r"[^A-Za-z0-9._-]", "-", key)[:100]


def _clear_retry(programme, key, item) -> None:
    wait = item.get("waiting_on") or {}
    if wait.get("who") == SYSTEM_WHO and wait.get("watcher") == _slug(key):
        item.update(state="open", waiting_on=None)
    queue = programme["working_model"].get("queue") or []
    programme["working_model"]["queue"] = [q for q in queue if not (
        isinstance(q, dict) and q.get("action") == RETRY_ACTION and q.get("item") == key)]


def _wait_on_system(programme, run_id, key, item, deliverable) -> dict:
    watcher = _slug(key)
    entry = dict((programme.setdefault("watchers", {})).get(watcher) or {})
    entry.update(item=key, retry={"deliverable": deliverable, "argv": [
        "programme.sh", "check-deliverable", key, deliverable, "--run", run_id]})
    entry.setdefault("last_beat_at", None)
    programme["watchers"][watcher] = entry
    spec = {"who": SYSTEM_WHO, "watcher": watcher, "reporter": None}
    item.update(state="waiting", waiting_on=spec)
    queue = programme["working_model"].setdefault("queue", [])
    if not any(isinstance(q, dict) and q.get("action") == RETRY_ACTION and q.get("item") == key for q in queue):
        queue.append({"id": "q" + secrets.token_hex(3), "action": RETRY_ACTION, "item": key,
                      "why": f"{deliverable} checked unknown {UNKNOWNS_BEFORE_WAIT} times in a row",
                      "at": run_record_core.now_iso()})
    item["history"].append({"at": run_record_core.now_iso(), "kind": "waiting", "who": SYSTEM_WHO,
                            "watcher": watcher})
    return spec


def _store(programme, run_id, key, deliverable, ref, verdict) -> dict:
    item = programme["items"].get(key)
    if item is None:
        raise programme_record.RecordError(f"item {key!r} left the programme during the check")
    if deliverable not in (item.get("deliverables") or {}):
        raise programme_record.RecordError(f"{deliverable!r} is no longer a deliverable of {key!r}")
    now = run_record_core.now_iso()
    old = dict(item["deliverables"].get(deliverable) or {})
    entry = {"result": verdict["result"], "ref": ref, "checked_at": now, "fields": verdict["fields"],
             "misses": verdict["misses"], "note": verdict["note"],
             "confirmed_at": old.get("confirmed_at") if verdict["result"] == "confirmed" else None,
             "unknown_streak": old.get("unknown_streak", 0) + 1 if verdict["result"] == "unknown" else 0}
    if verdict["result"] == "confirmed" and not entry["confirmed_at"]:
        entry["confirmed_at"] = now
    item["deliverables"][deliverable] = entry
    out = {"item": key, "deliverable": deliverable, "result": verdict["result"],
           "previous": old.get("result"), "ref": ref, "fields": verdict["fields"],
           "misses": verdict["misses"], "note": verdict["note"]}
    if verdict["result"] != "confirmed":
        item["done_at"] = None
        out["claim"] = "unconfirmed"
    if verdict["result"] == "unknown" and entry["unknown_streak"] >= UNKNOWNS_BEFORE_WAIT \
            and item.get("state") in programme_record.WAITABLE_STATES:
        out["waiting_on"] = _wait_on_system(programme, run_id, key, item, deliverable)
    elif verdict["result"] != "unknown":
        _clear_retry(programme, key, item)
    if programme_predicate.evidence_complete(item) and not item.get("done_at"):
        item["done_at"] = now
    out["done_at"] = item.get("done_at")
    return out


def _h_check_deliverable(host, argv):
    positional, opts = host._parse(argv, values=("run", "ref", "repo"))
    if len(positional) != 2:
        raise ValueError("usage: check-deliverable <item> <deliverable> [--ref <reference>] [--repo <clone>]")
    item_id = programme_record.check_item_id(positional[0])
    deliverable = positional[1]
    if deliverable not in programme_home.DELIVERABLES:
        raise ValueError(f"deliverable must be one of {list(programme_home.DELIVERABLES)}")
    run_id, home, record = host._locate(opts)
    host._guard(home, record)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    key = _resolve(programme, item_id)
    if deliverable not in (programme["items"][key].get("deliverables") or {}):
        raise programme_record.RecordError(f"{deliverable!r} is not a deliverable of {key!r}")
    entry = programme["items"][key]["deliverables"].get(deliverable) or {}
    ref = (_ref_token(opts.get("ref")) or _claimed_ref(home, key, deliverable)
           or entry.get("ref") or _default_ref(key, deliverable, programme["items"][key]))
    if not ref:
        raise programme_record.RecordError(
            f"no reference for {key} {deliverable}: no claim names one; pass --ref")
    repo = _repo_arg(opts.get("repo")) or _dig(entry, "fields", "repo_path")
    verdict = run_check(run_id, key, deliverable, ref,
                        _context(host, programme, key, deliverable, repo))

    def change(programme, prompt, rec):
        return _store(programme, run_id, _resolve(programme, key), deliverable, ref, verdict)

    return host._write(dict(opts, run=run_id), change, "evidence_checked")


def _due(record, now) -> tuple:
    programme = programme_home.normalize_programme(record.get("programme") or {})
    cadence = programme_home.cadence_seconds(record)
    due, skipped = [], []
    for key, item in sorted(programme["items"].items()):
        if item.get("state") in ("handed", "dropped"):
            continue
        done = programme_predicate.effective_state(item) == "done"
        if done:
            age = _age(item.get("done_at"), now)
            if age is None or age >= FINAL_AFTER_SECONDS:
                skipped.append({"item": key, "why": "final"})
                continue
        for name, entry in sorted((item.get("deliverables") or {}).items()):
            entry = entry or {}
            if entry.get("result") != "confirmed":
                continue
            if done and name in FROZEN_AT_DONE:
                skipped.append({"item": key, "deliverable": name, "why": "frozen"})
            elif name not in CHECKERS:
                skipped.append({"item": key, "deliverable": name, "why": "no_checker"})
            elif (_age(entry.get("checked_at"), now) or float("inf")) < cadence:
                skipped.append({"item": key, "deliverable": name, "why": "fresh"})
            elif not entry.get("ref"):
                skipped.append({"item": key, "deliverable": name, "why": "no_ref"})
            else:
                due.append((key, name, entry["ref"], _dig(entry, "fields", "repo_path")))
    return due, skipped


def _apply_validate(programme, run_id, checked) -> dict:
    now = run_record_core.now_iso()
    rows, refuted = [], []
    for key, name, ref, verdict in checked:
        item = (programme["items"] or {}).get(key)
        entry = (item or {}).get("deliverables", {}).get(name)
        if not isinstance(entry, dict) or entry.get("result") != "confirmed":
            continue
        rows.append({"item": key, "deliverable": name, "result": verdict["result"]})
        if verdict["result"] == "unknown":
            entry["validate"] = {"at": now, "result": "unknown", "note": verdict["note"]}
            continue
        entry.update(checked_at=now, fields=verdict["fields"], misses=verdict["misses"], note=None)
        if verdict["result"] == "refuted":
            entry.update(result="refuted", confirmed_at=None)
            item.update(state="open", done_at=None, waiting_on=None)
            item["history"].append({"at": now, "kind": "reopened", "by": "validate", "deliverable": name})
            refuted.append({"item": key, "deliverable": name, "ref": ref, "misses": verdict["misses"]})
    return {"rechecked": rows, "refuted": refuted}


def _h_validate(host, argv):
    _, opts = host._parse(argv, values=("run",))
    run_id, home, record = host._locate(opts)
    host._guard(home, record)
    now = datetime.datetime.now(datetime.timezone.utc)
    due, skipped = _due(record, now)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    cache = {}
    checked = [(key, name, ref, run_check(run_id, key, name, ref,
                                          _context(host, programme, key, name, repo, cache)))
               for key, name, ref, repo in due]

    def change(programme, prompt, rec):
        return dict(_apply_validate(programme, run_id, checked), skipped=skipped)

    def after(payload):
        sid = driver_session.driving_session_id()
        for hit in payload.get("refuted") or []:
            programme_journal.append(run_id, "evidence_refuted", sid, dict(hit, reopened=True))
        return {}

    return host._write(dict(opts, run=run_id), change, "validate_pass", after=after)


_SPECS = (
    ("check-deliverable", _h_check_deliverable,
     "<item> <deliverable> [--ref <reference>] [--repo <clone>] [--run <id>]",
     "a deliverable the item does not require; no reference (no claim, no --ref, no issue key in the "
     "item id). Stores confirmed, refuted or unknown from the checker; never takes a result."),
    ("validate", _h_validate, "[--run <id>]",
     "nothing; re-checks confirmed evidence older than one cadence on open items and on items done "
     "less than 7 days ago. A refutation reopens the item. Flagged evidence is frozen once its item "
     "is done."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
