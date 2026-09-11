#!/usr/bin/env python3
"""The report CLI the agent drives: list, prepare, finish, save, delete and rename.

Every number comes from the session log or from a file this script named. The agent passes
none, so it cannot talk past a stop. Output is one JSON object on stdout.
"""

import argparse
import datetime
import json
import math
import os
import re
import secrets
import stat
import string
import sys
import textwrap
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import changes  # noqa: E402
import constants  # noqa: E402
import credentials  # noqa: E402
import mapping  # noqa: E402
import pairing  # noqa: E402
import present as presenter  # noqa: E402
import session_log  # noqa: E402
import sources  # noqa: E402
import templates  # noqa: E402
import validate  # noqa: E402
from credentials import CredentialError  # noqa: E402
from mapping import MappingError  # noqa: E402
from session_log import LogError  # noqa: E402
from sources import CommandSource, Stop, ToolSource, clean_name, join_words  # noqa: E402
from templates import TemplateError  # noqa: E402

RELAY = (
    "Show `block` verbatim inside a plain triple-backtick fence with no language tag. "
    "When status is not ok, relay `message` instead: do not show the numbers another way, "
    "and do not edit the saved call and retry."
)
PREPARE_RELAY = (
    "Make each call exactly as listed. When every result has returned, run finish in a later "
    "message: report.py finish {name} --marker {marker}"
)
START_OVER = (
    "The conversation was compacted or rewound since prepare ran; run the report again from prepare."
)
OPEN_CAVEAT = "The last point may still have been open when fetched."
PREVIEW_REASON = "this preview becomes the report's first baseline when saved"
MARKER = re.compile(r"dp-[0-9a-f]{16}")
LIST_FILLER = ("report", "the", "show", "me")
UTC = datetime.timezone.utc
OK_STATUSES = ("ok", "stopped", "refused")
STALE_OUTPUT_SECONDS = 24 * 3600


class UsageError(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    # argparse exits the process on bad usage, which would skip the JSON fault response.
    def error(self, message):
        raise UsageError(f"{self.prog}: {message}")


def _response(status, next_move="none", message="", block="", found=None, notes=None, relay=RELAY, **extra):
    out = {
        "status": status,
        "next": next_move,
        "message": message,
        "block": block,
        "changes": found or [],
        "notes": notes or [],
        "relay": relay,
    }
    out.update(extra)
    return out


def _local(stamp):
    moment = changes.parse_time(stamp)
    if moment is None:
        return "at an unknown time"
    local = moment.astimezone()
    offset = local.strftime("%z")
    return f"{local:%Y-%m-%d %H:%M} UTC{offset[:3]}:{offset[3:]}"


def _wrap(text, width):
    clean = validate.clean_text(text, math.inf, [], "a report line")
    out = []
    lines = textwrap.wrap(clean, width, subsequent_indent="  ", break_long_words=False, break_on_hyphens=False)
    for line in lines or [""]:
        # Only a word longer than the width reaches here, and no number is that long.
        while len(line) > width:
            cut = width
            head = line[:cut]
            if (len(head) - len(head.rstrip("\\"))) % 2:
                cut -= 1
            out.append(line[:cut])
            line = "  " + line[cut:]
        out.append(line)
    return out


def _mapping_stop(number, err, rebuild=True, variation=False):
    if err.kind == "source_error":
        return Stop(f"Block {number}: {err} This report stopped; do not retry the call.")
    if variation:
        return Stop(
            f"Block {number}: the variation changed the data's shape, so it cannot be read the way "
            f"this report expects. {err}"
        )
    if rebuild:
        return Stop(
            f"Block {number}: the result can no longer be read the way this report expects. {err} "
            "The report needs to be rebuilt.",
            "offer_rebuild_template",
        )
    return Stop(f"Block {number}: the result cannot be read the way the draft's mapping says. {err}")


def _collect(template, found, needle, verb, variation=False):
    # finish reads only calls after prepare and checks fingerprints; save reads the whole
    # branch and takes them.
    marker = needle if verb == "finish" else None
    log = session_log.load(session_log.find_log())
    branch = log.branch(log.find_invocation(needle))
    if marker is None:
        calls, prepared_at = log.calls(branch), None
    else:
        prepared, calls = log.run(branch, marker)
        if prepared is None:
            raise Stop(START_OVER, "start_over")
        prepared_at = changes.parse_time(prepared)
    pairing.pair(found, calls, exact=not variation, verb=verb)
    for source in found:
        source.read(prepared_at, check_age=marker is not None)
    of_block = sources.by_block(found)
    mapped = []
    for number, block in enumerate(template["blocks"], start=1):
        text = of_block[number].text
        try:
            reading = mapping.read(text, block["mapping"])
            if marker is None:
                block["fingerprint"] = reading.fingerprint()
            else:
                reading.check(block["fingerprint"])
            mapped.append(reading.mapped())
        except MappingError as err:
            raise _mapping_stop(number, err, rebuild=marker is not None, variation=variation) from None
    return mapped


def _baseline(name, template):
    try:
        record = templates.load_run(name)
    except TemplateError:
        return None, changes.BAD_RECORD
    return changes.baseline(record, templates.template_hash(template), len(template["blocks"]))


def _labels(previous_x, current_x):
    union = list(previous_x) + [x for x in current_x if x not in set(previous_x)]
    labels = dict(zip(union, mapping.display_x(union))) if union else {}
    labels.update(zip(current_x, mapping.display_x(current_x)))
    return labels


def _render(template, found, mapped, width, label, previous_blocks, reason):
    of_block = sources.by_block(found)
    sections, found_all, notes, currents = [], [], [], []
    for number, spec in enumerate(template["blocks"], start=1):
        source, rows, settings = of_block[number], mapped[number - 1], spec["present"]
        changes.screen(number, rows)
        size = width or settings.get("width") or constants.COLUMN_BUDGET
        shown = presenter.present({
            "x": mapping.display_x(rows["x"]),
            "series": rows["series"],
            "title": settings.get("title"),
            "units": settings.get("units"),
            "type": settings.get("type", "auto"),
            "width": size,
        })
        if shown["status"] != "ok":
            raise Stop(f"Block {number}: {shown['message']}", "none", "refused")
        replied_at = source.replied_at
        lines = _wrap(label, size) + _wrap(f"Fetched {_local(replied_at)}", size)
        for caveat in template.get("caveats", []):
            lines += _wrap(f"Caveat: {caveat}", size)
        if changes.open_x(rows["x"], replied_at) is not None:
            lines += _wrap(OPEN_CAVEAT, size)
        top = changes.topn_line(source.call["input"]) if isinstance(source, ToolSource) and source.call else None
        if top:
            lines += _wrap(top, size)
        if rows["not_shown"]:
            lines += _wrap("Not shown: " + ", ".join(rows["not_shown"]), size)
        current = changes.record_block(rows, replied_at)
        previous = previous_blocks[number - 1] if previous_blocks is not None else None
        labels = _labels(previous["x"] if previous else [], rows["x"])
        if previous is None:
            found_here = changes.compare(None, current, reason)
        else:
            found_here = changes.compare(previous, current)
            lines += _wrap(f"Changes since {_local(previous.get('replied_at'))}:", size)
        lines += changes.render_lines(found_here, size, lambda raw, labels=labels: labels.get(raw, str(raw)))
        sections.append(shown["block"] + "\n\n" + "\n".join(lines))
        found_all.extend(dict(change, block=number) for change in found_here)
        notes.extend(shown["notes"])
        currents.append(current)
    return "\n\n".join(sections), found_all, notes, currents


def cmd_list(args):
    words = []
    for word in " ".join(args.phrase).lower().split():
        word = word.strip(string.punctuation)
        if word and word not in LIST_FILLER:
            words.append(word)
    found = []
    for name, purpose in templates.list_templates():
        haystack = f"{name} {purpose}".lower()
        if all(word in haystack for word in words):
            found.append({"name": name, "purpose": purpose})
    ask = bool(args.phrase) and len(found) > 1
    message = ""
    if not found:
        message = "No saved report matches that request." if args.phrase else "No reports are saved yet."
    elif ask:
        message = "More than one saved report matches. Ask the person which one they mean."
    return _response("ok", "ask_which_template" if ask else "none", message, templates=found)


def cmd_prepare(args):
    template = templates.load(args.name)
    unset = []
    for block in template["blocks"]:
        for variable in credentials.env_names(block["source"]):
            if not os.environ.get(variable) and variable not in unset:
                unset.append(variable)
    if unset:
        raise Stop(
            f"Set {join_words(unset)} in the environment before running {args.name}. Only the names "
            "are shown here, never a value.",
            "ask_user_to_set_env",
        )
    marker = "dp-" + secrets.token_hex(8)
    templates.ensure_dirs()
    _sweep_outputs(args.name)
    calls = [source.listed_call() for source in sources.for_run(template, args.name, marker)]
    return _response(
        "ok", "make_calls", marker=marker, calls=calls,
        relay=PREPARE_RELAY.format(name=args.name, marker=marker),
    )


def _sweep_outputs(name):
    folder = os.path.join(templates.root(), "out")
    own = re.compile(re.escape(name) + "-" + MARKER.pattern + r"-\d+\.json")
    cutoff = time.time() - STALE_OUTPUT_SECONDS
    for item in os.listdir(folder):
        if not own.fullmatch(item):
            continue
        path = os.path.join(folder, item)
        try:
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode) and info.st_mtime < cutoff:
                os.unlink(path)
        except OSError:
            # Another prepare or finish may remove the same file first; that is not a failure.
            pass


def cmd_finish(args):
    template = templates.load(args.name)
    if not MARKER.fullmatch(args.marker):
        raise Stop("That marker was not issued by prepare. " + START_OVER, "start_over")
    found = sources.for_run(template, args.name, args.marker)
    keep = False
    try:
        return _finish(args, template, found)
    except Stop as stop:
        # The command may still be writing its output; finish will read it next time.
        keep = stop.next == "run_finish_again"
        raise
    finally:
        if not keep:
            for source in found:
                if isinstance(source, CommandSource):
                    source.remove_output()


def _finish(args, template, found):
    try:
        last = templates.load_run(args.name)
    except TemplateError:
        last = None
    if changes.finished_by(last, args.marker):
        raise Stop(
            "This run was already finished, and its report was shown then. To run the report "
            "again, start from prepare.",
            "start_over",
        )
    mapped = _collect(template, found, args.marker, "finish", args.variation)
    previous, reason = _baseline(args.name, template)
    if args.variation:
        label = f"Variation of {args.name}: not the saved report, not remembered"
    else:
        label = f"Report: {args.name}"
    block, changed, notes, currents = _render(template, found, mapped, args.width, label, previous, reason)
    if args.variation:
        return _response(
            "ok", "offer_save_variation",
            f"This is a variation of {args.name}, not the saved report, and it is not remembered. "
            f"Offer to save it as a new report with /data-presentation:new, or to update {args.name}.",
            block, changed, notes,
        )
    templates.write_run(args.name, changes.run_record(templates.template_hash(template), currents, args.marker))
    return _response("ok", "none", "", block, changed, notes)


def _read_draft(path):
    try:
        with open(path, encoding="utf-8") as f:
            draft = json.load(f)
    except OSError as err:
        raise Stop(f"The draft {path} cannot be read ({err.strerror}).") from None
    except ValueError as err:
        raise Stop(f"The draft {path} is not JSON: {err}.") from None
    if not isinstance(draft, dict) or not isinstance(draft.get("blocks"), list):
        raise Stop("The draft must be a template object with a list of blocks.")
    return draft


def _from_draft(draft):
    template = {k: v for k, v in draft.items() if k != "created_at"}
    blocks, outputs = [], []
    for number, block in enumerate(draft["blocks"], start=1):
        if not isinstance(block, dict):
            raise Stop(f"Block {number} of the draft must be an object.")
        block = {k: v for k, v in block.items() if k != "fingerprint"}
        source = block.get("source")
        output = None
        if isinstance(source, dict) and source.get("kind") == "command":
            source = dict(source)
            output = source.pop("output", None)
            if not isinstance(output, str) or not os.path.isabs(output):
                raise Stop(
                    f"Block {number}'s command source needs output: the absolute path the build "
                    "run wrote to."
                )
            block["source"] = source
        blocks.append(block)
        outputs.append(output)
    template["blocks"] = blocks
    return template, outputs


def _gate_draft(template, snapshot):
    shape = dict(template, blocks=[dict(b, fingerprint={}) for b in template["blocks"]])
    try:
        templates.validate(shape)
        for block in template["blocks"]:
            credentials.scan_source(block["source"])
            mapping.validate_mapping(block["mapping"])
    except MappingError as err:
        raise Stop(f"The draft's mapping cannot be used: {err}") from None
    if snapshot:
        return
    dated = []
    for number, block in enumerate(template["blocks"], start=1):
        if block["source"]["kind"] == "tool":
            dated += [f"block {number} {clean_name(p)}" for p in templates.absolute_dates(block["source"]["args"])]
    if dated:
        raise Stop(
            f"The call holds an absolute date or time ({join_words(dated[:pairing.MAX_NAMED])}), so it would "
            "return the same window forever. Ask the person: keep it as a fixed snapshot (save "
            "again with --snapshot), or make the call again with a relative range first.",
            "ask_snapshot_or_relative",
        )


def cmd_save(args):
    path = os.path.abspath(args.draft)
    template, outputs = _from_draft(_read_draft(path))
    _gate_draft(template, args.snapshot)
    name = template["name"]
    if not args.replace and templates.exists(name):
        raise Stop(f"A report named {name!r} already exists. Replacing it needs an explicit replace request.")
    found = sources.for_draft(template, outputs)
    mapped = _collect(template, found, path, "save")
    templates.validate(template)
    block, changed, notes, currents = _render(
        template, found, mapped, None, f"Report: {name}", None, PREVIEW_REASON
    )
    if not args.confirm:
        return _response(
            "ok", "confirm_save",
            f"This is a preview of {name}. Show it, and save only after the person confirms: run "
            "save again with --confirm.",
            block, changed, notes,
        )
    template["created_at"] = datetime.datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    templates.save(template, replace=args.replace)
    templates.write_run(name, changes.run_record(templates.template_hash(template), currents))
    return _response("ok", "none", f"Saved {name}. Its preview is the first baseline.", block, changed, notes)


def cmd_delete(args):
    templates.check_name(args.name)
    if not templates.exists(args.name):
        raise Stop(f"There is no saved report named {args.name!r}.")
    if not args.confirm:
        return _response(
            "ok", "confirm_delete",
            f"Deleting {args.name} also deletes its run record. Ask the person to confirm, then run "
            "delete again with --confirm.",
        )
    templates.delete(args.name)
    return _response("ok", "none", f"Deleted {args.name} and its run record.")


def cmd_rename(args):
    templates.rename(args.old, args.new)
    return _response("ok", "none", f"Renamed {args.old} to {args.new}. Its run record moved with it.")


def _parser():
    parser = _Parser(prog="report.py")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("list")
    p.add_argument("phrase", nargs="*")
    p.set_defaults(run=cmd_list)
    p = sub.add_parser("prepare")
    p.add_argument("name")
    p.set_defaults(run=cmd_prepare)
    p = sub.add_parser("finish")
    p.add_argument("name")
    p.add_argument("--marker", required=True)
    p.add_argument("--width", type=int)
    p.add_argument("--variation", action="store_true")
    p.set_defaults(run=cmd_finish)
    p = sub.add_parser("save")
    p.add_argument("--draft", required=True)
    p.add_argument("--confirm", action="store_true")
    p.add_argument("--replace", action="store_true")
    p.add_argument("--snapshot", action="store_true")
    p.set_defaults(run=cmd_save)
    p = sub.add_parser("delete")
    p.add_argument("name")
    p.add_argument("--confirm", action="store_true")
    p.set_defaults(run=cmd_delete)
    p = sub.add_parser("rename")
    p.add_argument("old")
    p.add_argument("new")
    p.set_defaults(run=cmd_rename)
    return parser


def main(argv=None):
    try:
        args = _parser().parse_args(argv)
        return args.run(args)
    except Stop as stop:
        return _response(stop.status, stop.next, str(stop))
    except (TemplateError, LogError, CredentialError) as err:
        return _response("stopped", "none", str(err))
    except Exception as exc:  # noqa: BLE001
        return _response("fault", "none", f"{type(exc).__name__}: {exc}")


def exit_code(result):
    return 0 if result.get("status") in OK_STATUSES else 1


if __name__ == "__main__":
    outcome = main(sys.argv[1:])
    print(json.dumps(outcome, ensure_ascii=False, indent=2))
    sys.exit(exit_code(outcome))
