"""host: print which terminal host this session resolves to and which fact decided it."""
from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402


def verb(host, argv) -> int:
    if argv[1:]:
        raise ValueError("usage: host")
    host._emit(load_lib_module("terminal_host").explain())
    return 0
