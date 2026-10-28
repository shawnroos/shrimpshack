"""The Ghostty terminal host. Its commands arrive with the Ghostty adapter; until then every capability refuses with the table's fix line."""
from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

terminal_host = load_lib_module("terminal_host")


class GhosttyHost(terminal_host.TerminalHost):
    name = "ghostty"
