#!/usr/bin/env python3
"""Checks a ritual may carry: a short fixed list, each one plugin code that reads a repo and never runs it.

A ritual stores only a check *name*. The name maps to a function in this module, so adding a check is
a reviewed code change and never a command string in a ritual.
"""

from __future__ import annotations

NAMES = ("versions-bumped",)
RESULTS = ("pass", "fail", "error")
