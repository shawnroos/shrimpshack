"""The one door from auto to a terminal host (herdr today; Rex and Ghostty next).

Every method on a host returns a HostResult, never a bare value, so a caller
cannot mistake "this host cannot do that" for an empty answer.
"""
from __future__ import annotations

import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

HOSTS = ("herdr", "rex", "ghostty")
STATUSES = ("native", "degraded", "refuse")
METHODS = ("own_pane", "list_panes", "start_pane", "confirm_started", "send_prompt", "presence",
           "change_token", "notify", "is_host_command")
# is_host_command has no row: its per-host coverage is a required test, not a table cell.
CAPABILITY_OF = {"own_pane": "find_own_pane", "list_panes": "list_panes", "start_pane": "start_pane",
                 "confirm_started": "confirm_started", "send_prompt": "send_prompt",
                 "presence": "presence", "change_token": "change_signal", "notify": "notify"}
TABLE_PATH = os.path.join(_LIB_DIR, "terminal_host_capabilities.json")


class HostResult:
    __slots__ = ("status", "why", "fix", "value")

    def __init__(self, status, why=None, fix=None, value=None):
        if status not in STATUSES:
            raise ValueError(f"unknown host status {status!r}")
        self.status, self.why, self.fix, self.value = status, why, fix, value

    @property
    def ok(self) -> bool:
        return self.status != "refuse"


def native(value=None, why=None) -> HostResult:
    return HostResult("native", why=why, value=value)


def degraded(why, value=None) -> HostResult:
    return HostResult("degraded", why=why, value=value)


def refuse(why, fix=None, value=None) -> HostResult:
    return HostResult("refuse", why=why, fix=fix, value=value)


def capability_table() -> dict:
    with open(TABLE_PATH) as fh:
        return json.load(fh)["capabilities"]


class TerminalHost:
    name = ""

    def _unimplemented(self, method) -> HostResult:
        cell = capability_table()[CAPABILITY_OF[method]][self.name]
        return refuse(f"the {self.name} terminal host does not support this yet",
                      fix=cell.get("fix") or cell.get("how"))

    def own_pane(self, env, **_) -> HostResult:
        return self._unimplemented("own_pane")

    def list_panes(self, **_) -> HostResult:
        return self._unimplemented("list_panes")

    def start_pane(self, *_, **__) -> HostResult:
        return self._unimplemented("start_pane")

    def confirm_started(self, *_, **__) -> HostResult:
        return self._unimplemented("confirm_started")

    def send_prompt(self, *_, **__) -> HostResult:
        return self._unimplemented("send_prompt")

    def presence(self, *_, **__) -> HostResult:
        return self._unimplemented("presence")

    def change_token(self, *_, **__) -> HostResult:
        return self._unimplemented("change_token")

    def notify(self, *_, **__) -> HostResult:
        return self._unimplemented("notify")

    def is_host_command(self, argv) -> bool:
        return False


_current = None


def current(env=None) -> TerminalHost:
    """Detection arrives with the Rex and Ghostty hosts; until then every session is herdr."""
    global _current
    if _current is None:
        _current = load_lib_module("host_herdr").HerdrHost()
    return _current
