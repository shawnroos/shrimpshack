#!/usr/bin/env python3
"""Shared dispatch for the verb-table CLIs (``run_record.py``, ``programme.py``)."""

from __future__ import annotations

import sys


def dispatch(argv, verbs, *, prog, errors=()) -> int:
    if not argv:
        sys.stderr.write(f"usage: {prog} <subcommand> ...\n")
        return 2
    verb = verbs.get(argv[0])
    if verb is None:
        sys.stderr.write(
            f"{prog}: unknown subcommand {argv[0]!r}\n"
            f"  run `python3 lib/{prog} describe` for the authoritative verb set.\n"
        )
        return 2
    try:
        return verb.handler(argv)
    except tuple(errors) as e:
        sys.stderr.write(f"{prog}: {e}\n")
        return 1
    except (IndexError, ValueError) as e:
        sys.stderr.write(f"{prog}: bad arguments: {e}\n")
        return 2
