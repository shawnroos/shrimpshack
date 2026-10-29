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


SEND_VERBS = frozenset({"send", "type", "run"})


class StubHost(terminal_host.TerminalHost):
    name = "stub"
    binaries = ("stubhost",)

    def _unimplemented(self, method):
        return terminal_host.refuse(f"the stub host does not implement {method}", fix="drive it through a real host")

    def is_host_command(self, argv, pane_ids=()):
        if len(argv) > 2 and os.path.basename(argv[0]) == "stubhost" and argv[1] in SEND_VERBS:
            target = next((t for t in argv[2:] if not t.startswith("-")), None)
            if target:
                return argv[1], target
        return super().is_host_command(argv, pane_ids)

    def own_pane(self, env, **_):
        pane = env.get("AUTO_TEST_STUB_PANE")
        server, workspace = env.get("AUTO_TEST_STUB_SERVER"), env.get("AUTO_TEST_STUB_WORKSPACE")
        if not (pane and server and workspace):
            return terminal_host.refuse("the stub host has no pane", fix="set AUTO_TEST_STUB_PANE, _SERVER and _WORKSPACE")
        return terminal_host.native({"pane_id": pane, "server": server, "workspace": workspace,
                                     "terminal_id": env.get("AUTO_TEST_STUB_TERMINAL"),
                                     "tab_space_name": env.get("AUTO_TEST_STUB_TAB")})

    def presence(self, session_id, row, snap, reported, **_):
        """AUTO_TEST_STUB_PRESENCE_SEQ names a file of one state per line; each call consumes the first line."""
        path = os.environ.get("AUTO_TEST_STUB_PRESENCE_SEQ")
        state = "unknown"
        if path and os.path.exists(path):
            with open(path) as fh:
                lines = fh.read().split("\n")
            state = (lines[0] or "unknown") if lines else "unknown"
            with open(path, "w") as fh:
                fh.write("\n".join(lines[1:]))
        return terminal_host.native({
            "state": state, "session_id": session_id, "herdr_reachable": False,
            "registry_pane": (row or {}).get("pane_id"), "pane_in_snapshot": None, "session_reported": None,
            "pane_id": (row or {}).get("pane_id"), "pane_label": None, "tab_label": None,
            "why": f"the stub host reports the session {state}"})
