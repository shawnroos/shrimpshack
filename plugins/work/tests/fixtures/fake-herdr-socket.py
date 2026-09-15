#!/usr/bin/env python3
"""The fake herdr board: one state file, edited by both transports.

fake-herdr.sh hands every board-mode CLI call here (`cli ...`), and `serve`
answers the Unix socket. One mutator for both, so a CLI arm and a socket method
cannot drift apart. Shapes follow herdr 0.9.0's bundled API schema
(`herdr api schema --json`) and docs/board-spikes.md:

  * a tab is a binary LayoutNode tree; a split replaces the target leaf with
    split(target, new), so a column added after its rows nests the way live
    herdr nests it
  * a move inside the pane's own tab does nothing: changed:false, same_tab
  * a move to another workspace gives the pane a new id; the terminal id, label
    and process stay, and the old id resolves as an alias
  * moving or closing the last pane of a tab closes the tab
  * the CLI `pane move` focuses the moved pane unless --no-focus; the socket
    `pane.move` focuses only when asked
  * `layout.apply` is refused: it kills every process in the tab (spike step 1)

Environment:
  FAKE_HERDR_BOARD_STATE   the state file
  FAKE_HERDR_RECORD_DIR    where `socket` (one JSON request per line) is recorded
  FAKE_HERDR_SOCKET_PATH   the socket `serve` binds
  FAKE_HERDR_SNAPSHOT_FAILS            1: every snapshot read fails
  FAKE_HERDR_SNAPSHOT_FAILS_AFTER_MOVE 1: reads fail once a move has been applied
  FAKE_HERDR_SNAPSHOT_FAILS_AFTER_CLOSE 1: reads fail once a close has been applied
  FAKE_HERDR_RENAME_IGNORED 1: `pane rename` answers success and changes nothing
  FAKE_HERDR_KILL_AFTER_MOVES N: once the Nth socket `pane.move` is applied and
                           saved, SIGKILL the process group named in
                           FAKE_HERDR_KILL_PGID_FILE and close the connection
                           unanswered: a sync that dies after herdr moved a
                           pane and before it heard so
  FAKE_HERDR_SLOW_PANE     N: a created pane is unknown to every verb and to the
                           snapshot until N `pane get` probes have missed it, as
                           a live pane registers after `split` returns
  FAKE_HERDR_AGENT_START_FAILS 1: `agent start` answers agent_not_detected and
                           the pane keeps no agent
  FAKE_HERDR_CLOSE_KILLS_PANE  a pane id: once a CLI `pane close` of that pane is
                           applied and saved, SIGKILL the process group named in
                           FAKE_HERDR_CLOSE_KILLS_PGID_FILE, as herdr ends every
                           process in a pane it closes, the closing caller's too

Test helpers: seed <spec>, tree <tab>, restart, set-agent <pane> <agent|none> [status].
"""
import json
import os
import signal
import socketserver
import sys
import threading

STATE = os.environ.get("FAKE_HERDR_BOARD_STATE", "")
REC = os.environ.get("FAKE_HERDR_RECORD_DIR") or os.path.join(os.environ.get("TMPDIR", "/tmp"), "fake-herdr-record")
LOCK = threading.Lock()


class Err(Exception):
    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code
        self.message = message


def load():
    with open(STATE) as f:
        return json.load(f)


def save(st):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, sort_keys=True)
    os.replace(tmp, STATE)


def mark_down(reason):
    os.makedirs(REC, exist_ok=True)
    open(os.path.join(REC, "snapshot-down"), "w").write(reason)


def down():
    return os.environ.get("FAKE_HERDR_SNAPSHOT_FAILS") == "1" or os.path.exists(os.path.join(REC, "snapshot-down"))


def leaf(pid):
    return {"type": "pane", "pane_id": pid}


def compact_to_tree(c):
    if isinstance(c, str):
        return leaf(c)
    return {"type": "split", "direction": c[0], "ratio": 0.5,
            "first": compact_to_tree(c[1]), "second": compact_to_tree(c[2])}


def tree_to_text(n):
    if n["type"] == "pane":
        return n["pane_id"]
    return "%s(%s,%s)" % (n["direction"], flat(n, n["direction"], "first"), flat(n, n["direction"], "second"))


def flat(n, direction, side):
    child = n[side]
    if child["type"] == "split" and child["direction"] == direction:
        return "%s,%s" % (flat(child, direction, "first"), flat(child, direction, "second"))
    return tree_to_text(child)


def leaves(n):
    if n["type"] == "pane":
        return [n["pane_id"]]
    return leaves(n["first"]) + leaves(n["second"])


def remove_leaf(n, pid):
    if n["type"] == "pane":
        return None if n["pane_id"] == pid else n
    a, b = remove_leaf(n["first"], pid), remove_leaf(n["second"], pid)
    if a is None:
        return b
    if b is None:
        return a
    n["first"], n["second"] = a, b
    return n


def insert(n, target, new, direction, ratio):
    if n["type"] == "pane":
        if n["pane_id"] == target:
            return {"type": "split", "direction": direction, "ratio": ratio, "first": n, "second": leaf(new)}
        return n
    n["first"] = insert(n["first"], target, new, direction, ratio)
    n["second"] = insert(n["second"], target, new, direction, ratio)
    return n


def next_seq(st):
    st["seq"] += 1
    return st["seq"]


def find_pane(st, pid, probe=False):
    pid = st["aliases"].get(pid, pid)
    for p in st["panes"]:
        if p["pane_id"] == pid:
            if p.get("pending", 0) > 0:
                if probe:
                    p["pending"] -= 1
                break
            return p
    raise Err("pane_not_found", "pane %s not found" % pid)


def find_tab(st, tid):
    for t in st["tabs"]:
        if t["tab_id"] == tid:
            return t
    raise Err("tab_not_found", "tab %s not found" % tid)


def public_pane(st, p):
    out = {k: v for k, v in p.items() if k not in ("env", "pending")}
    out["focused"] = st["focused_pane_id"] == p["pane_id"]
    out.setdefault("revision", 0)
    return out


def public_tab(st, t):
    out = dict(t)
    out["pane_count"] = len([p for p in st["panes"] if p["tab_id"] == t["tab_id"]])
    return out


def focus(st, p):
    st["focused_pane_id"] = p["pane_id"]
    st["focused_tab_id"] = p["tab_id"]
    st["focused_workspace_id"] = p["workspace_id"]


def detach(st, p):
    """Takes the pane out of its tab's tree; the tab id if that closed the tab."""
    tid = p["tab_id"]
    tree = remove_leaf(st["trees"][tid], p["pane_id"])
    if tree is not None:
        st["trees"][tid] = tree
        return None
    del st["trees"][tid]
    st["tabs"] = [t for t in st["tabs"] if t["tab_id"] != tid]
    return tid


def new_pane(st, tab, cwd, env):
    n = next_seq(st)
    ws = tab["workspace_id"]
    p = {"pane_id": "%s:p%d" % (ws, n), "terminal_id": "term-%d" % n, "tab_id": tab["tab_id"],
         "workspace_id": ws, "label": None, "title": None, "agent": None, "agent_status": "unknown",
         "cwd": cwd, "env": env, "pending": int(os.environ.get("FAKE_HERDR_SLOW_PANE") or 0)}
    st["panes"].append(p)
    return p


# ------------------------------------------------------------------ operations

def op_split(st, target, direction, cwd, env, want_focus, ratio=0.5):
    t = find_pane(st, target)
    tab = find_tab(st, t["tab_id"])
    p = new_pane(st, tab, cwd, env)
    st["trees"][tab["tab_id"]] = insert(st["trees"][tab["tab_id"]], t["pane_id"], p["pane_id"], direction, ratio)
    if want_focus:
        focus(st, p)
    return {"type": "pane_info", "pane": public_pane(st, p)}


def op_tab_create(st, ws, cwd, label, env, want_focus):
    if ws not in [w["workspace_id"] for w in st["workspaces"]]:
        raise Err("workspace_not_found", "workspace %s not found" % ws)
    tab = {"tab_id": "%s:t%d" % (ws, next_seq(st)), "workspace_id": ws, "label": label}
    st["tabs"].append(tab)
    p = new_pane(st, tab, cwd, env)
    st["trees"][tab["tab_id"]] = leaf(p["pane_id"])
    if want_focus:
        focus(st, p)
    return {"type": "tab_created", "tab": public_tab(st, tab), "root_pane": public_pane(st, p)}


def op_move(st, params):
    p = find_pane(st, params.get("pane_id", ""))
    dest = params.get("destination") or {}
    prev = {"previous_pane_id": p["pane_id"], "previous_tab_id": p["tab_id"],
            "previous_workspace_id": p["workspace_id"]}
    created_tab = target = None
    if dest.get("type") == "tab":
        tab = find_tab(st, dest.get("tab_id", ""))
        if p["tab_id"] == tab["tab_id"]:
            res = dict(prev, changed=False, reason="same_tab", pane=public_pane(st, p),
                       closed_tab_id=None, focused_pane_id=st["focused_pane_id"])
            return {"type": "pane_move", "move_result": res}
        target = dest.get("target_pane_id")
        if target is not None:
            target = find_pane(st, target)
            if target["tab_id"] != tab["tab_id"]:
                raise Err("invalid_target", "target pane is not in tab %s" % tab["tab_id"])
    elif dest.get("type") == "new_tab":
        ws = dest.get("workspace_id") or p["workspace_id"]
        if ws not in [w["workspace_id"] for w in st["workspaces"]]:
            raise Err("workspace_not_found", "workspace %s not found" % ws)
        tab = None
    else:
        raise Err("invalid_params", "unsupported destination")

    closed = detach(st, p)
    if tab is None:
        tab = {"tab_id": "%s:t%d" % (ws, next_seq(st)), "workspace_id": ws, "label": dest.get("label")}
        st["tabs"].append(tab)
        created_tab = tab
    if tab["workspace_id"] != p["workspace_id"]:
        old = p["pane_id"]
        new = "%s:p%d" % (tab["workspace_id"], next_seq(st))
        st["aliases"] = {k: (new if v == old else v) for k, v in st["aliases"].items()}
        st["aliases"][old] = new
        if st["focused_pane_id"] == old:
            st["focused_pane_id"] = new
        p["pane_id"] = new
    p["tab_id"], p["workspace_id"] = tab["tab_id"], tab["workspace_id"]
    if created_tab is not None:
        st["trees"][tab["tab_id"]] = leaf(p["pane_id"])
    elif target is not None:
        st["trees"][tab["tab_id"]] = insert(st["trees"][tab["tab_id"]], target["pane_id"], p["pane_id"],
                                            dest.get("split", "right"), dest.get("ratio") or 0.5)
    else:
        st["trees"][tab["tab_id"]] = {"type": "split", "direction": dest.get("split", "right"), "ratio": 0.5,
                                      "first": st["trees"][tab["tab_id"]], "second": leaf(p["pane_id"])}
    if params.get("focus"):
        focus(st, p)
    if os.environ.get("FAKE_HERDR_SNAPSHOT_FAILS_AFTER_MOVE") == "1":
        mark_down("move")
    res = dict(prev, changed=True, reason=None, pane=public_pane(st, p), closed_tab_id=closed,
               created_tab=public_tab(st, created_tab) if created_tab else None,
               focused_pane_id=st["focused_pane_id"])
    return {"type": "pane_move", "move_result": res}


def op_close(st, pid):
    p = find_pane(st, pid)
    detach(st, p)
    st["panes"] = [q for q in st["panes"] if q is not p]
    if st["focused_pane_id"] == p["pane_id"]:
        st["focused_pane_id"] = None
    if os.environ.get("FAKE_HERDR_SNAPSHOT_FAILS_AFTER_CLOSE") == "1":
        mark_down("close")
    return {"type": "ok"}


def op_rename(st, pid, label):
    p = find_pane(st, pid)
    if os.environ.get("FAKE_HERDR_RENAME_IGNORED") != "1":
        p["label"] = label
    return {"type": "pane_info", "pane": public_pane(st, p)}


def op_metadata(st, pid, source, title):
    p = find_pane(st, pid)
    p["title"] = title
    p["metadata_source"] = source
    return {"type": "ok"}


def op_agent_start(st, pid, name, kind):
    p = find_pane(st, pid)
    if os.environ.get("FAKE_HERDR_AGENT_START_FAILS") == "1":
        raise Err("agent_not_detected", "no %s agent was detected in %s" % (kind, pid))
    p["agent"], p["agent_status"], p["agent_name"] = kind, "idle", name
    return {"type": "agent_started", "pane": public_pane(st, p)}


def op_focus(st, pid):
    focus(st, find_pane(st, pid))
    return {"type": "ok"}


def op_layout_export(st, params):
    tid = params.get("tab_id")
    if not tid and params.get("pane_id"):
        tid = find_pane(st, params["pane_id"])["tab_id"]
    tab = find_tab(st, tid or "")
    if down():
        raise Err("unavailable", "server busy")
    ids = leaves(st["trees"][tab["tab_id"]])
    fp = st["focused_pane_id"] if st["focused_pane_id"] in ids else ids[0]
    return {"type": "layout_export", "layout": {"tab_id": tab["tab_id"], "workspace_id": tab["workspace_id"],
                                                "zoomed": False, "focused_pane_id": fp,
                                                "root": st["trees"][tab["tab_id"]]}}


def op_snapshot(st):
    if down():
        raise Err("unavailable", "snapshot failed")
    panes = [public_pane(st, p) for p in st["panes"] if p.get("pending", 0) <= 0]
    agents = [{k: p[k] for k in ("pane_id", "tab_id", "workspace_id", "terminal_id", "agent", "agent_status", "focused")}
              for p in panes if p.get("agent")]
    layouts = []
    for t in st["tabs"]:
        ids = leaves(st["trees"][t["tab_id"]])
        layouts.append({"tab_id": t["tab_id"], "workspace_id": t["workspace_id"], "zoomed": False,
                        "focused_pane_id": st["focused_pane_id"] if st["focused_pane_id"] in ids else ids[0]})
    return {"version": "0.9.0", "protocol": 22, "focused_pane_id": st["focused_pane_id"],
            "focused_tab_id": st.get("focused_tab_id"), "focused_workspace_id": st.get("focused_workspace_id"),
            "workspaces": st["workspaces"], "tabs": [public_tab(st, t) for t in st["tabs"]],
            "panes": panes, "agents": agents, "layouts": layouts}


def mutate(fn, *a):
    with LOCK:
        st = load()
        out = fn(st, *a)
        save(st)
        return out


# ------------------------------------------------------------------ CLI

def flag(args, name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None


def flags_all(args, name):
    return [args[i + 1] for i, a in enumerate(args) if a == name and i + 1 < len(args)]


VALUED = {"--pane", "--direction", "--ratio", "--cwd", "--env", "--right-click", "--tab", "--split",
          "--target-pane", "--workspace", "--label", "--tab-label", "--source", "--title", "--agent",
          "--kind", "--timeout"}


def positional(args):
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
            continue
        if a in VALUED:
            skip = True
            continue
        if a.startswith("--"):
            continue
        out.append(a)
    return out


def env_map(args):
    return dict(e.split("=", 1) for e in flags_all(args, "--env") if "=" in e)


def cli(argv):
    cmd = " ".join(argv[:2])
    rest = argv[2:]
    if cmd == "api snapshot":
        st = load()
        return {"id": "cli:api:snapshot", "result": {"type": "session_snapshot", "snapshot": op_snapshot(st)}}
    if cmd == "pane get":
        def probe(st):
            return {"type": "pane_info", "pane": public_pane(st, find_pane(st, rest[0] if rest else "", probe=True))}
        with LOCK:
            st = load()
            try:
                return {"id": "cli:pane:get", "result": probe(st)}
            finally:
                save(st)
    if cmd == "tab get":
        st = load()
        return {"id": "cli:tab:get", "result": {"type": "tab_info", "tab": public_tab(st, find_tab(st, rest[0] if rest else ""))}}
    if cmd == "pane split":
        pos = positional(rest)
        target = flag(rest, "--pane") or (pos[0] if pos else "")
        return {"id": "cli:pane:split", "result": mutate(op_split, target, flag(rest, "--direction") or "right",
                                                           flag(rest, "--cwd"), env_map(rest), "--no-focus" not in rest)}
    if cmd == "tab create":
        return {"id": "cli:tab:create", "result": mutate(op_tab_create, flag(rest, "--workspace") or "",
                                                           flag(rest, "--cwd"), flag(rest, "--label"), env_map(rest),
                                                           "--no-focus" not in rest)}
    if cmd == "pane move":
        pos = positional(rest)
        if "--new-tab" in rest:
            dest = {"type": "new_tab", "workspace_id": flag(rest, "--workspace"), "label": flag(rest, "--label")}
        else:
            dest = {"type": "tab", "tab_id": flag(rest, "--tab"), "split": flag(rest, "--split") or "right",
                    "target_pane_id": flag(rest, "--target-pane")}
        params = {"pane_id": pos[0] if pos else "", "destination": dest, "focus": "--no-focus" not in rest}
        return {"id": "cli:pane:move", "result": mutate(op_move, params)}
    if cmd == "pane close":
        out = {"id": "cli:pane:close", "result": mutate(op_close, rest[0] if rest else "")}
        if rest and rest[0] == os.environ.get("FAKE_HERDR_CLOSE_KILLS_PANE"):
            pgid = int(open(os.environ["FAKE_HERDR_CLOSE_KILLS_PGID_FILE"]).read().strip() or 0)
            if pgid <= 1:
                raise SystemExit("fake-herdr: refusing to kill process group %d" % pgid)
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        return out
    if cmd == "pane rename":
        pos = positional(rest)
        return {"id": "cli:pane:rename", "result": mutate(op_rename, pos[0] if pos else "", " ".join(pos[1:]) or None)}
    if cmd == "pane report-metadata":
        pos = positional(rest)
        return {"id": "cli:pane:report-metadata", "result": mutate(op_metadata, pos[0] if pos else "",
                                                                     flag(rest, "--source"), flag(rest, "--title"))}
    if cmd == "agent start":
        pos = positional(rest)
        return {"id": "cli:agent:start", "result": mutate(op_agent_start, flag(rest, "--pane") or "",
                                                            pos[0] if pos else "", flag(rest, "--kind") or "")}
    raise Err("unsupported", "fake-herdr board mode: unsupported command '%s'" % " ".join(argv))


# ------------------------------------------------------------------ socket

METHODS = {
    "pane.move": lambda p: mutate(op_move, p),
    "pane.focus": lambda p: mutate(op_focus, p.get("pane_id", "")),
    "layout.export": lambda p: op_layout_export(load(), p),
    "pane.get": lambda p: (lambda st: {"type": "pane_info", "pane": public_pane(st, find_pane(st, p.get("pane_id", "")))})(load()),
}


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        for raw in self.rfile:
            try:
                req = json.loads(raw)
            except ValueError:
                self.wfile.write(b'{"id":"","error":{"code":"invalid_json","message":"bad request"}}\n')
                continue
            with open(os.path.join(REC, "socket"), "a") as f:
                f.write(json.dumps(req, sort_keys=True) + "\n")
            rid = req.get("id", "")
            method = req.get("method", "")
            try:
                if method not in METHODS:
                    raise Err("unsupported_method", "fake socket refuses %s" % method)
                out = {"id": rid, "result": METHODS[method](req.get("params") or {})}
            except Err as e:
                out = {"id": rid, "error": {"code": e.code, "message": e.message}}
            if method == "pane.move" and "result" in out and kill_now():
                return
            self.wfile.write((json.dumps(out) + "\n").encode())
            self.wfile.flush()


def kill_now():
    limit = os.environ.get("FAKE_HERDR_KILL_AFTER_MOVES")
    if not limit:
        return False
    with LOCK:
        path = os.path.join(REC, "moves-applied")
        n = int(open(path).read() or 0) + 1 if os.path.exists(path) else 1
        open(path, "w").write(str(n))
    if n != int(limit):
        return False
    pgid = int(open(os.environ["FAKE_HERDR_KILL_PGID_FILE"]).read().strip())
    if pgid <= 1 or pgid == os.getpgrp():
        raise SystemExit("fake-herdr: refusing to kill its own process group")
    os.killpg(pgid, signal.SIGKILL)
    return True


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve():
    path = os.environ["FAKE_HERDR_SOCKET_PATH"]
    os.makedirs(REC, exist_ok=True)
    if os.path.exists(path):
        os.unlink(path)
    Server(path, Handler).serve_forever()


# ------------------------------------------------------------------ test helpers

def seed(spec):
    spec = json.loads(spec)
    st = {"seq": 100, "aliases": {}, "workspaces": spec["workspaces"], "tabs": [], "panes": [], "trees": {},
          "focused_pane_id": spec.get("focused"), "focused_tab_id": None, "focused_workspace_id": None}
    attrs = spec.get("panes", {})
    for t in spec["tabs"]:
        ws = t["tab_id"].split(":")[0]
        st["tabs"].append({"tab_id": t["tab_id"], "workspace_id": ws, "label": t.get("label")})
        tree = compact_to_tree(t["tree"])
        st["trees"][t["tab_id"]] = tree
        for pid in leaves(tree):
            a = attrs.get(pid, {})
            st["panes"].append({"pane_id": pid, "terminal_id": "term-" + pid.replace(":", "-"),
                                "tab_id": t["tab_id"], "workspace_id": ws, "label": a.get("label"), "title": None,
                                "agent": a.get("agent"), "agent_status": a.get("agent_status", "unknown"),
                                "cwd": a.get("cwd", "/"), "env": {}})
            if pid == st["focused_pane_id"]:
                st["focused_tab_id"], st["focused_workspace_id"] = t["tab_id"], ws
    save(st)


def main(argv):
    if not argv:
        sys.exit(2)
    sub = argv[0]
    if sub == "serve":
        serve()
        return 0
    if sub == "seed":
        seed(argv[1])
        return 0
    if sub == "tree":
        st = load()
        print(tree_to_text(st["trees"][argv[1]]) if argv[1] in st["trees"] else "")
        return 0
    if sub == "restart":
        def restart(st):
            for p in st["panes"]:
                p["terminal_id"] = "term-r%d" % next_seq(st)
                p["agent"], p["agent_status"] = None, "unknown"
            st["aliases"] = {}
        mutate(restart)
        return 0
    if sub == "set-agent":
        def set_agent(st):
            p = find_pane(st, argv[1])
            p["agent"], p["agent_status"] = (None, "unknown") if argv[2] == "none" else (argv[2], argv[3])
        mutate(set_agent)
        return 0
    if sub == "cli":
        try:
            print(json.dumps(cli(argv[1:])))
            return 0
        except Err as e:
            sys.stderr.write(json.dumps({"error": {"code": e.code, "message": e.message}, "id": "cli"}) + "\n")
            return 1
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
