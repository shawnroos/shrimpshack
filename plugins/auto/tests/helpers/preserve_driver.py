#!/usr/bin/env python3
"""Test driver for programme_preserve: one call per process, JSON in and out."""

import json
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module  # noqa: E402

pp = load_lib_module("programme_preserve")
ph = load_lib_module("programme_home")


def main():
    cmd = sys.argv[2]
    args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    try:
        if cmd == "create":
            out = {"run": ph.create_programme(["w2"], "sess-pm")["run"]}
        elif cmd == "capture":
            out = pp.capture(args["run"], args["path"], extras=args.get("extras", ()),
                             include_ignored=args.get("ignored", ()), operation_id=args.get("op"))
        elif cmd == "verify":
            out = pp.verify(args["run"], args["source"])
        elif cmd == "restore":
            out = pp.restore(args["run"], args["source"], args["dest"])
        elif cmd == "cleanup":
            out = pp.cleanup_check(args["run"], args["source"])
        elif cmd == "scan":
            admission = pp.admit_binary(bytes.fromhex(args["hex"]))
            out = {"decision": admission.decision}
        elif cmd == "bundle":
            with open(args["file"], "rb") as fh:
                out = pp.check_bundle(fh.read())
        else:
            raise SystemExit(f"unknown command {cmd}")
    except pp.PreserveError as exc:
        print(json.dumps({"ok": False, "code": exc.code, "message": str(exc)}))
        return
    print(json.dumps(dict({"ok": True}, **out), default=str))


main()
