#!/usr/bin/env python3
"""Behind on-pretooluse-action.sh: the tracker, settings, behaviours and send guards, and `no-destructive-commands`.

The limit reads only the programme record, through programme_checks. It refuses one Bash call and
journals it. Nothing pauses, and a session a limit does not bind is not checked.

The list is a best-effort match on the command text. It does not catch the flag-reorder class
(`rm -vrf`, `rm --recursive --force`), a refspec force-push (`git push origin +<ref>`), a compound
`a; rm -rf b`, eval or other obfuscation, or a write through an MCP tool. Write `content` is not read:
plans and reviews quote these commands.

rel-001: ALWAYS exit 0 at the process level.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

# ──────────────────────────────────────────────────────────────────────────
# Destructive pattern set. Each entry is (human_label, compiled_regex). The label
# goes into the refusal, never the raw regex source. The shell shim's text test
# must match anything these match: tests/integration/check-settings.test.sh pins it.
# The two rm labels are named constants because the path-scoping exemption keys
# off them by value (``_PATH_SCOPED_RM_LABELS`` below): if a label string here
# and there ever drift apart, path-scoping silently becomes a dead no-op and
# every ephemeral rm starts being refused. Sharing the constant makes that
# impossible.
DESTRUCTIVE_LIMIT = "no-destructive-commands"
_RM_RF_LABEL = "rm -rf"
_RM_FR_LABEL = "rm -fr"

_DESTRUCTIVE_PATTERNS = [
    # Force-push in ANY flag position (fix-round-5 P1). `push` always precedes
    # its force flag in real git, so match by ORDER (`push` ... force flag), not
    # by adjacency — the prior `push\s+--force` anchoring missed the canonical
    # flag-last spelling `git push origin main --force` / `-f` /
    # `--force-with-lease`, which is at least as common as flag-first and is NOT a
    # documented residual (KTD-4 residuals are shell-syntax bypasses only).
    # `--force\b` matches inside `--force-with-lease` (word boundary between `e`
    # and `-`), so the lease form needs no separate pattern. The `\s-f\b` (leading
    # whitespace) keeps benign branch names like `git push origin my-feature` /
    # `git push origin wolf` from matching the short flag.
    ("git push --force / -f / --force-with-lease",
     re.compile(r"\bpush\b.*(?:--force\b|\s-f\b)")),
    ("git reset --hard", re.compile(r"reset\s+--hard\b")),
    # Whole-tree discard family — the trailing ` .` pathspec discards the entire
    # working tree regardless of the intervening flags/tree-ish, so match it in
    # any spelling (`checkout .`, `checkout -- .`, `checkout HEAD -- .`,
    # `restore -- .`, `restore --source=HEAD~1 .`). The `\s\.` requires the `.`
    # to be its own whitespace-delimited pathspec, so a scoped pathspec
    # (`checkout -- file.py`, `restore --staged x`) and benign forms
    # (`checkout -b`, `checkout main`) correctly do NOT fire.
    ("git checkout . (discard working tree)", re.compile(r"checkout\b[^\n]*\s\.(?:\s|$)")),
    ("git restore . (discard working tree)", re.compile(r"restore\b[^\n]*\s\.(?:\s|$)")),
    ("git clean -f / -fdx", re.compile(r"clean\s+-[a-z]*f")),
    ("git branch -D (force-delete)", re.compile(r"branch\s+-D\b")),
    (_RM_RF_LABEL, re.compile(r"\brm\s+-rf\b")),
    (_RM_FR_LABEL, re.compile(r"\brm\s+-fr\b")),  # the one flag-reorder residual we DO catch
    # Known external-publish / irreversible-GitHub endpoints (KTD-4). Minimal,
    # explicit set — extend deliberately, not speculatively. `npm publish` /
    # `gh release create` are the concrete irreversible publishes in this
    # project's orbit. The destructive `gh` subcommands below (fix-round-5 P2)
    # run through the already-gated Bash channel — the global CLAUDE.md instructs
    # preferring `gh` for GitHub ops — and are equivalent-destruction to the git
    # set: `gh repo delete` (irreversible), `gh release delete` (irreversible),
    # `gh pr merge --admin` (bypasses branch protection / required reviews).
    ("npm publish", re.compile(r"npm\s+publish\b")),
    ("gh release create", re.compile(r"gh\s+release\s+create\b")),
    ("gh repo delete", re.compile(r"gh\s+repo\s+delete\b")),
    ("gh release delete", re.compile(r"gh\s+release\s+delete\b")),
    ("gh pr merge --admin", re.compile(r"gh\s+pr\s+merge\b.*--admin\b")),
]


# ──────────────────────────────────────────────────────────────────────────
# Path-scoping for the rm family. An rm is exempt ONLY when EVERY path target
# provably resolves under a known-ephemeral root: an allowlist, so anything not
# provably ephemeral (relative paths, $HOME, the temp root ITSELF, traversal,
# unparseable commands) is still matched.
_PATH_SCOPED_RM_LABELS = frozenset({_RM_RF_LABEL, _RM_FR_LABEL})

# Drift guard: every rm-family pattern MUST participate in path-scoping. Without
# this, adding a third `rm ` variant to _DESTRUCTIVE_PATTERNS but forgetting to
# list its label here would make that variant gate ALL ephemeral teardown again
# (a silent regression of the fix). Enforced at import, so the test suite catches
# it immediately.
assert all(
    label in _PATH_SCOPED_RM_LABELS
    for label, _ in _DESTRUCTIVE_PATTERNS
    if label.startswith("rm ")
), "every 'rm ' label in _DESTRUCTIVE_PATTERNS must be in _PATH_SCOPED_RM_LABELS"

# Ephemeral roots are ABSOLUTE, literal prefixes. Each carries a trailing
# separator AND ``_under_ephemeral_root`` additionally requires the target to be
# a real child (``norm != rootdir``), so deleting the temp ROOT itself
# (`rm -rf /tmp` / `rm -rf /tmp/`) is NOT exempted — only deletions UNDER it.
# `$TMPDIR` is handled separately (``_resolve_tmpdir_target``), NOT as a literal
# prefix: matching the literal token would exempt a string whose RUNTIME value
# the classifier cannot see — and exemption (unlike gating) must be conservative
# about expansion, or `rm -rf "$TMPDIR/"` with TMPDIR unset (the common case in a
# hook subprocess / CI) expands to `rm -rf /`.
_EPHEMERAL_ABS_PREFIXES = (
    "/tmp/",
    "/private/tmp/",
    "/var/folders/",          # full macOS user-temp tree: T/ (temp) AND C/
    "/private/var/folders/",  # (regenerable caches) — both ephemeral-safe for rm.
)
_TMPDIR_TOKENS = ("$TMPDIR/", "${TMPDIR}/")
# Metacharacters whose runtime expansion the classifier cannot resolve — a target
# containing any of these is NEVER provably ephemeral, so it gates: command
# substitution (`$(`, backtick), globs (`*`, `?`, `[`), brace expansion (`{`).
# (`$`-variables are handled separately: only an exact $TMPDIR/ prefix resolves.)
_UNRESOLVABLE_METACHARS = ("$(", "`", "*", "?", "[", "{")


def _under_ephemeral_root(path: str) -> bool:
    """True iff a FULLY-LITERAL path is a real child strictly UNDER an ephemeral
    root — never the root itself, never via a ``..`` segment."""
    if ".." in path.split("/"):
        return False  # traversal evasion (e.g. /tmp/../etc) -> gate.
    norm = os.path.normpath(path)
    for root in _EPHEMERAL_ABS_PREFIXES:
        rootdir = root.rstrip("/")
        if norm != rootdir and norm.startswith(rootdir + "/"):
            return True
    return False


def _resolve_tmpdir_target(t: str):
    """Resolve a ``$TMPDIR/<rest>`` / ``${TMPDIR}/<rest>`` token to its literal
    runtime path, or None when it cannot be SAFELY resolved (→ gate).

    Gates (returns None) on: a bare-root token (`$TMPDIR/` with empty remainder,
    which expands to the temp root or — if TMPDIR is unset — to `/`), a nested
    variable in the remainder, or an unset/empty TMPDIR (the `rm -rf /` hole).
    The resolved path is still subject to ``_under_ephemeral_root`` by the caller,
    so a `$TMPDIR/../x` remainder is caught there.
    """
    for tok in _TMPDIR_TOKENS:
        if t.startswith(tok):
            rest = t[len(tok):]
            if not rest or "$" in rest:
                return None  # bare temp root, or a further unresolvable var.
            base = os.environ.get("TMPDIR")
            if not base:
                return None  # unset/empty -> `$TMPDIR/x` expands to `/x` -> gate.
            return base.rstrip("/") + "/" + rest
    return None


def _rm_targets_all_ephemeral(command: str) -> bool:
    """True iff ``command`` is an ``rm`` whose EVERY path target provably resolves
    to a real child under an ephemeral-temp root.

    Returns False (→ still matched) on anything not
    provably ephemeral — a relative target (resolves under cwd = repo root), a
    ``$HOME``/repo path, the temp root itself, a ``..`` traversal, a glob /
    command-substitution / brace target whose expansion is unknowable, an
    unresolvable ``$TMPDIR``, an unparseable command, or zero targets. Requires at
    least one target. Documented residual (NOT chased): an inline
    ``TMPDIR=/repo rm -rf "$TMPDIR/x"`` resolves against the hook's outer TMPDIR —
    this is the eval/obfuscation residual class (see module docstring).
    """
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False  # unbalanced quotes / unparseable -> gate.
    # Locate the rm invocation (bare `rm` or a `/path/to/rm`); classify only the
    # tokens after it. A compound command (`rm -rf /tmp/a && rm -rf /repo`) is a
    # documented residual that still gates here: the shell operators (`&&`, `;`)
    # and the second command's tokens are collected as non-ephemeral targets and
    # fail the check below, so it is not exempt.
    idx = next(
        (i for i, t in enumerate(tokens) if t == "rm" or t.endswith("/rm")),
        None,
    )
    if idx is None:
        return False
    targets = []
    end_of_opts = False
    for tok in tokens[idx + 1:]:
        if not end_of_opts and tok == "--":
            end_of_opts = True
            continue
        if not end_of_opts and tok.startswith("-"):
            continue  # an rm flag (-rf, -r, -f, --verbose, ...).
        targets.append(tok)
    if not targets:
        return False
    for t in targets:
        # Resolve a leading $TMPDIR FIRST (its `${...}` braces are not brace
        # EXPANSION), then run the metachar + root checks on the literal result.
        # Any other `$`-var is unresolvable -> gate.
        if "$" in t:
            t = _resolve_tmpdir_target(t)
            if t is None:
                return False  # unresolvable $-var (incl. $HOME, $(...), /tmp/$X).
        if any(m in t for m in _UNRESOLVABLE_METACHARS):
            return False  # glob / command-subst / brace -> unknowable -> gate.
        if not _under_ephemeral_root(t):
            return False  # relative / $HOME / repo / temp-root-itself -> gate.
    return True


def _matched_destructive(command: str):
    """Return the human label of the first destructive match, or None.

    rm-family matches are PATH-SCOPED: an ``rm -rf``/``rm -fr`` whose targets are
    all ephemeral-temp (``_rm_targets_all_ephemeral``) is treated as benign and
    skipped — so a real destructive op spelled differently can still match a
    LATER pattern, and a genuinely destructive rm still returns its label.
    """
    if not command:
        return None
    for label, pat in _DESTRUCTIVE_PATTERNS:
        if pat.search(command):
            if label in _PATH_SCOPED_RM_LABELS and _rm_targets_all_ephemeral(command):
                continue  # ephemeral-temp teardown -> not gated (path-scoping).
            return label
    return None


def _command_text(stdin_data: dict) -> str:
    """tool_input.command, or empty. Write `content` is DELIBERATELY NOT read: plans and reviews quote these commands."""
    ti = stdin_data.get("tool_input") or {}
    if not isinstance(ti, dict):
        return ""
    val = ti.get("command")
    return val if isinstance(val, str) else ""


def _read_stdin(raw: str):
    """Parse PreToolUse stdin -> (session_id, command_text). ((None, "") on failure)."""
    if not raw:
        return None, ""
    try:
        data = json.loads(raw)
    except Exception:
        return None, ""
    if not isinstance(data, dict):
        return None, ""
    sid = data.get("session_id")
    sid = sid if isinstance(sid, str) and sid else None
    return sid, _command_text(data)


def destructive_denial(stdin_raw: str) -> tuple | None:
    session_id, command = _read_stdin(stdin_raw)
    label = _matched_destructive(command)
    if label is None or session_id is None:
        return None
    checks = load_lib_module("programme_checks")
    if not checks.hook_checks(session_id)["states"][DESTRUCTIVE_LIMIT]:
        return None
    return checks.limit_refusal(DESTRUCTIVE_LIMIT, session_id, "Bash", f"runs `{label}`", command=command)


def driver_send_denial(stdin_raw: str) -> tuple | None:
    session_id, command = _read_stdin(stdin_raw)
    if not command:
        return None
    return load_lib_module("send_guard").denial(session_id, command)


DONE_STATE_NAMES = frozenset({"done", "completed", "complete", "canceled", "cancelled",
                              "duplicate", "closed"})
DONE_STATE_TYPES = frozenset({"completed", "canceled", "cancelled"})
_STATE_FIELDS = ("state", "stateId", "status", "stateType", "type")
_STRICT_STATE_FIELDS = ("state", "stateId")
_COMMENT_FIELDS = ("body", "comment")
_ISSUE_FIELDS = ("issueId", "issue")
_ISSUE_TOOLS = ("save_issue", "update_issue")
_ISSUE_KEY = re.compile(r"[A-Z][A-Z0-9]{0,7}-[0-9]{1,6}")
_STATE_ID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def _is_tracker_tool(name) -> bool:
    if not isinstance(name, str) or not name.startswith("mcp__"):
        return False
    server = name[len("mcp__"):].rpartition("__")[0]
    return "linear" in server.lower()


def _driven_programme(session_id):
    if not session_id:
        return None
    programme_home = load_lib_module("programme_home")
    runs = {}
    for lease in programme_home.leases_for_session(session_id):
        status, read = programme_home.lease_state(lease)
        if status in programme_home.HELD_LEASE_STATES and runs.get(lease.get("run")) is None:
            runs[lease.get("run")] = read
    for run_id in sorted(r for r in runs if isinstance(r, str)):
        record, hold = runs[run_id] or programme_home.read_programme(run_id)
        if hold is not None:
            return run_id, None
        programme = record.get("programme") if isinstance(record, dict) else None
        if (isinstance(programme, dict) and not programme.get("ended")
                and record.get("driving_session_id") == session_id):
            return run_id, programme
    return None


def _recorded_states(programme) -> list:
    issues = (programme.get("recorded_issues") or {}).get("issues")
    return [i for i in issues.values() if isinstance(i, dict)] if isinstance(issues, dict) else []


def _done_type(issue) -> bool:
    return str(issue.get("state_type") or "").casefold() in DONE_STATE_TYPES


def _done_state(value, programme, strict):
    if value is None:
        return None
    if not isinstance(value, str):
        return f"a state given as {type(value).__name__}, which cannot be checked" if strict else None
    text = value.strip()
    if text.casefold() in DONE_STATE_NAMES or text.casefold() in DONE_STATE_TYPES:
        return f"the done state {value!r}"
    recorded = _recorded_states(programme)
    if _STATE_ID.fullmatch(text):
        known = [i for i in recorded if i.get("state_id") == text]
        if not known or any(_done_type(i) for i in known):
            return f"the state id {text!r}, which the recorded issues do not show as open; pass the state by name"
        return None
    if any(str(i.get("state") or "").casefold() == text.casefold() and _done_type(i) for i in recorded):
        return f"{value!r}, a done state in the recorded issues"
    return None


def _proof_write(tool_input, programme):
    for field in _STATE_FIELDS:
        found = _done_state(tool_input.get(field), programme, field in _STRICT_STATE_FIELDS)
        if found:
            return f"sets {found}"
    if tool_input.get("duplicateOf"):
        return "marks the issue a duplicate, which closes it"
    root_cause = load_lib_module("programme_evidence")._ROOT_CAUSE
    for field in _COMMENT_FIELDS:
        text = tool_input.get(field)
        if text is not None and not isinstance(text, str):
            return f"posts a {field} that cannot be checked"
        if text and root_cause.search(text):
            return "posts a root-cause comment"
    return None


def _ref_hit(entries, value) -> bool:
    wanted = {str(v).casefold() for v in (_dict_or_empty(value).get("id"), _dict_or_empty(value).get("name")) if v}
    return any(wanted & {str(v).casefold() for v in (e.get("key"), e.get("id"), e.get("name")) if v}
               for e in entries if isinstance(e, dict))


def _dict_or_empty(value) -> dict:
    return value if isinstance(value, dict) else {}


def _issue_refs(tool_name, tool_input) -> list:
    fields = list(_ISSUE_FIELDS) + (["id"] if tool_name.endswith(_ISSUE_TOOLS) else [])
    return [tool_input[f] for f in fields if tool_input.get(f) is not None]


def _remit_write(tool_name, tool_input, programme):
    scope = _dict_or_empty(_dict_or_empty(programme.get("remit")).get("tracker"))
    teams = [t for t in scope.get("teams") or [] if isinstance(t, dict)]
    team = tool_input.get("team")
    if teams and team is not None and not _ref_hit(teams, {"name": team}):
        return f"creates an issue in team {team!r}, outside the remit's teams"
    issues = _dict_or_empty(_dict_or_empty(programme.get("recorded_issues")).get("issues"))
    for ref in _issue_refs(tool_name, tool_input):
        key = ref.strip().upper() if isinstance(ref, str) else ""
        if teams:
            if not _ISSUE_KEY.fullmatch(key):
                return f"names the issue {ref!r}, which cannot be checked against the remit; pass the issue key"
            if key.split("-")[0] not in {t.get("key") for t in teams}:
                return f"writes to {key}, outside the remit's teams"
        recorded = _dict_or_empty(issues.get(key))
        projects, initiatives = scope.get("projects") or [], scope.get("initiatives") or []
        if (projects or initiatives) and recorded.get("project") and not _ref_hit(projects, recorded["project"]) \
                and not any(_ref_hit(initiatives, i) for i in recorded.get("initiatives") or []):
            return f"writes to {key}, whose project is outside the remit"
    return None


def tracker_write_denial(stdin_raw: str) -> tuple | None:
    data = json.loads(stdin_raw) if stdin_raw else None
    if not isinstance(data, dict) or not _is_tracker_tool(data.get("tool_name")):
        return None
    session_id = data.get("session_id") if isinstance(data.get("session_id"), str) else None
    driven = _driven_programme(session_id)
    if driven is None:
        return None
    run_id, programme = driven
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    if programme is None:
        what = "comes from a programme whose authority cannot be read, so its remit cannot be checked"
    else:
        what = _proof_write(tool_input, programme)
        if what is None:
            what = _remit_write(data["tool_name"], tool_input, programme)
            if what and not load_lib_module("programme_checks").run_state("tracker-outside-remit", run_id, session_id):
                what = None
    if what is None:
        return None
    row = (run_id, "blocked_tracker_write", session_id, {
        "tool": data["tool_name"][:200], "reason": what[:300]})
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            f"auto: the programme's PM may not make this tracker write; this call {what}. "
            "A done or canceled state and a root-cause comment come from a worker or Shawn, "
            "and the PM writes only inside the remit."),
    }}, row


# The hook is killed at its 10 s timeout and a killed hook denies nothing, so a guard never
# waits out a held programme store: each read gives up quickly (a hold denies), and the
# journal row is written after the deny is on stdout, giving up if the lock stays held.
JOURNAL_LOCK_WAIT = 1.0
COMMAND_CAP = 2000


def _journal(row) -> None:
    if row is None:
        return
    try:
        run_id, kind, session_id, payload = row
        journal = load_lib_module("programme_journal")
        if isinstance(payload.get("command"), str):
            # Redact before truncating: a cut can split a secret so the redactor no longer sees it.
            payload = dict(payload, command=journal.redact(payload["command"])[:COMMAND_CAP])
        journal.append(run_id, kind, session_id, payload, lock_timeout=JOURNAL_LOCK_WAIT)
    except Exception:
        pass


def _emit(decision) -> None:
    json.dump(decision, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()


def _guarded(check, stdin_raw):
    try:
        return check(stdin_raw) or (None, None)
    except Exception:
        return None, None


def _decision_of(module):
    return lambda raw: load_lib_module(module).decision(raw)


def _cli() -> int:
    stdin_raw = ""
    if not sys.stdin.isatty():
        try:
            stdin_raw = sys.stdin.read()
        except Exception:
            stdin_raw = ""
    try:
        store = load_lib_module("programme_store")
        store.bound_waits(store.HOOK_WAIT_MS)
        load_lib_module("programme_home").cache_reads()
    except Exception:
        pass
    tracker_denial, tracker_row = _guarded(tracker_write_denial, stdin_raw)
    if tracker_denial is not None:
        _emit(tracker_denial)
        _journal(tracker_row)
        return 0
    results = [_guarded(guard, stdin_raw) for guard in (
        destructive_denial,
        _decision_of("programme_settings_guard"),
        _decision_of("programme_behaviour_guard"),
        driver_send_denial,
        _decision_of("programme_limits"),
    )]
    decision = next((denial for denial, _row in results if denial), None)
    if decision is not None:
        _emit(decision)
    for _denial, row in results:
        _journal(row)
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
