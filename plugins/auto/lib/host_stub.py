"""A test-only terminal host. terminal_host.detect() returns it only while AUTO_TEST_HOST=stub, so the
suites can exercise host-keyed state without Rex or Ghostty; no production path sets that variable.
It reads its pane facts from AUTO_TEST_STUB_* variables, which is exactly what KTD3 forbids a real host to do."""
from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

terminal_host = load_lib_module("terminal_host")


class StubHost(terminal_host.TerminalHost):
    name = "stub"

    def own_pane(self, env, **_):
        pane = env.get("AUTO_TEST_STUB_PANE")
        server, workspace = env.get("AUTO_TEST_STUB_SERVER"), env.get("AUTO_TEST_STUB_WORKSPACE")
        if not (pane and server and workspace):
            return terminal_host.refuse("the stub host has no pane", fix="set AUTO_TEST_STUB_PANE, _SERVER and _WORKSPACE")
        return terminal_host.native({"pane_id": pane, "server": server, "workspace": workspace,
                                     "terminal_id": env.get("AUTO_TEST_STUB_TERMINAL"),
                                     "tab_space_name": env.get("AUTO_TEST_STUB_TAB")})
