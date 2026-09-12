"""Which logged call answers which source."""

from canon import canonical_json
from sources import CommandSource, Stop, clean_name, join_words

BASH_IGNORED = ("description", "timeout", "run_in_background", "dangerouslyDisableSandbox")
AMPLITUDE_IGNORED = ("rationale",)
MAX_NAMED = 6
RUN_AGAIN = {"finish": "run_finish_again", "save": "run_save_again"}


def _ignored(tool):
    if tool == "Bash":
        return BASH_IGNORED
    if "amplitude" in tool.lower():
        return AMPLITUDE_IGNORED
    return ()


def _kept(tool, args):
    return {k: v for k, v in args.items() if k not in _ignored(tool)}


def _same(tool, args, call):
    return (
        call["tool"] == tool
        and isinstance(call["input"], dict)
        and canonical_json(_kept(tool, args)) == canonical_json(_kept(tool, call["input"]))
    )


def _diff(saved, made, path=""):
    found = []
    for key in sorted(set(saved) | set(made), key=str):
        where = f"{path}.{key}" if path else str(key)
        if key not in made:
            found.append(("removed", where))
        elif key not in saved:
            found.append(("added", where))
        elif isinstance(saved[key], dict) and isinstance(made[key], dict):
            found.extend(_diff(saved[key], made[key], where))
        elif canonical_json(saved[key]) != canonical_json(made[key]):
            found.append(("changed", where))
    return found


def _made_diff(source, call):
    return _diff(_kept(source.tool, source.args), _kept(source.tool, call["input"]))


def _distance(source, call):
    return len(_made_diff(source, call))


def _not_made(source, verb):
    if verb == "save":
        return Stop(
            f"{source.which()}'s call was not found on this conversation's branch. It was made "
            "before the conversation was compacted or cleared, or on another branch, so it "
            "must be made again before saving.",
            "make_calls",
        )
    return Stop(
        f"{source.which()}'s call to {clean_name(source.tool)} was not made after prepare. Make each "
        "call exactly as prepare listed it, then run finish again.",
        "make_calls",
    )


def _difference(source, call, verb):
    found = _made_diff(source, call)
    named = [f"{kind} {clean_name(where)}" for kind, where in found[:MAX_NAMED]]
    if len(found) > MAX_NAMED:
        named.append(f"{len(found) - MAX_NAMED} more")
    if verb == "save":
        head, tail = "the draft's call", "Make the call exactly as the draft holds it, then run save again."
    else:
        head, tail = "the saved call", "Make the call exactly as prepare listed it, then run finish again."
    # Only argument paths are named. A value may be a literal the agent typed, even a secret.
    return Stop(
        f"{source.which()}'s call to {clean_name(source.tool)} is not {head}: "
        f"{join_words(named) or 'its arguments differ'}. {tail}",
        "make_calls",
    )


def _pair_exact(sources, calls, verb):
    used = set()
    for source in sources:
        if source.expected() is None:
            continue
        for call in reversed(calls):
            if _same(source.tool, source.args, call):
                source.call = call
                used.add(call["id"])
                break
    for source in sources:
        if source.expected() is None or source.call is not None:
            continue
        rivals = [c for c in calls if c["id"] not in used and source.claims(c)]
        if len(rivals) == 1:
            raise _difference(source, rivals[0], verb)
        raise _not_made(source, verb)


def _pair_loose(sources, calls, verb):
    groups = {}
    for source in sources:
        if source.expected() is None:
            continue
        key = ("command", source.output) if isinstance(source, CommandSource) else ("tool", source.tool)
        groups.setdefault(key, []).append(source)
    for group in groups.values():
        pool = [c for c in calls if group[0].claims(c)]
        if len(pool) < len(group):
            raise _not_made(group[len(pool)], verb)
        if len(group) == 1:
            group[0].call = pool[-1]
            continue
        for source in group:
            source.call = _closest(source, pool)
            pool = [c for c in pool if c["id"] != source.call["id"]]


def _closest(source, pool):
    least = min(_distance(source, c) for c in pool)
    nearest = [c for c in pool if _distance(source, c) == least]
    # Calls with the same arguments are one call retried, so the latest of them stands.
    if len({canonical_json(_kept(source.tool, c["input"])) for c in nearest}) > 1:
        raise Stop(
            f"{source.which()}: more than one call to {clean_name(source.tool)} after prepare is as close "
            "to its saved call as any other, so which block each belongs to cannot be told. Make one "
            "call per block, then run finish again.",
            "make_calls",
        )
    return nearest[-1]


def _require_foreground(sources, verb):
    for source in sources:
        call = source.call
        if call is not None and call["tool"] == "Bash" and call["input"].get("run_in_background") is True:
            raise Stop(
                f"{source.which()}'s command ran in the background, so its output may not be complete. "
                f"Run the command in the foreground, exactly as listed, then run {verb} again.",
                "make_calls",
            )


def _require_results(sources, verb):
    for source in sources:
        call = source.call
        if call is not None and not call["has_result"]:
            raise Stop(
                f"{source.which()}'s call has no result yet. Run {verb} again in a later message, "
                "after every result has returned.",
                RUN_AGAIN[verb],
            )


def pair(sources, calls, exact, verb="finish"):
    (_pair_exact if exact else _pair_loose)(sources, calls, verb)
    _require_foreground(sources, verb)
    _require_results(sources, verb)
