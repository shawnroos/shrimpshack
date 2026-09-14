#!/usr/bin/env bash
# The board's placement engine and classifier (U6). Sourced, never executed.
#
# PURE: one JSON document in, one JSON document out. Nothing here calls herdr
# or Linear, reads the store, or sources another lib, so the same inputs always
# produce the same bytes and every decision can be tested from fixtures.
#
# INPUT (a file path):
#   config          board_config_load output: {version, global:{levels,filter},
#                   spaces:{name:{levels,filter}}}; spaces in configuration order
#   reads           [{mapping:"global"|<space>, complete:bool, tickets:[issue]}]
#                   one board_issues result per mapping. A mapping claims a
#                   ticket when the ticket is in its read; the engine never
#                   evaluates a filter itself.
#   snapshot        `herdr api snapshot` output, wrapped or bare
#   layouts         {tab_id: layout.export result ({root} or the bare tree)}
#   ledger          {space: {issue_id: board-store ledger entry}}
#   previous        sync-state record ({rendered}); rendered order is how a
#                   column or row index is read back as a group
#   aliases         {old pane_id: current pane_id}, from `pane get`
#   in_use          {invoking_pane_id, treat_all_in_use}
#   writes_enabled  false unless Linear writes are on (shadow mode is the default)
#   default_space   space name when the global mapping has no space level
#
# OUTPUT: {complete, members, rendered, spaces:[{name, mapping, tabs:[{name,
#   value, tree}]}], actions:[...]}. Group values are Linear ids (priority as
#   "1".."4"), null for a "No <level>" group; names are display only (KTD1).
#
# EXIT: 0 plan printed; 2 refused (input unreadable or malformed, named on
# stderr); 3 usage.

HERDR_LINEAR_BOARD_PLAN_OK=0
HERDR_LINEAR_BOARD_PLAN_REFUSED=2
HERDR_LINEAR_BOARD_PLAN_USAGE=3

# herdr_linear::board_plan <input.json>
herdr_linear::board_plan() {
    [ "$#" -eq 1 ] && [ -n "$1" ] || {
        printf 'usage: herdr_linear::board_plan <input.json>\n' >&2
        return "$HERDR_LINEAR_BOARD_PLAN_USAGE"
    }
    python3 - "$1" <<'PYEOF'
import json, re, sys

REFUSED = 2
LEVELS = ("space", "tab", "column", "row")
FIELD_KINDS = ("team", "project", "milestone", "cycle", "assignee", "state", "priority", "parent")
STATE_ORDER = ("triage", "backlog", "unstarted", "started", "completed", "canceled")
PRIORITY_NAMES = {"1": "Urgent", "2": "High", "3": "Medium", "4": "Low"}
WRITE_FIELD = {"team": "teamId", "project": "projectId", "milestone": "projectMilestoneId",
               "cycle": "cycleId", "assignee": "assigneeId", "state": "stateId",
               "priority": "priority", "parent": "parentId", "sub-ticket": "parentId"}
KIND_ORDER = ("relink", "unhide", "hide", "place", "recreate-pointer", "agreement", "move",
              "move-question", "write-back-candidate", "conflict-question", "close-question", "forget")
DEFAULT_TAB = "Board"
ANY = "*"


class Refusal(Exception):
    pass


class Mark:
    def __init__(self, name):
        self.name = name

    def __repr__(self):
        return self.name


UNKNOWN = Mark("UNKNOWN")      # position not readable; no claim either way
AMBIG = Mark("AMBIG")          # an ambiguous shape: any reading is a conflict
MISSING = Mark("MISSING")      # the ledger holds no value for this kind
OUTSIDE = Mark("OUTSIDE")      # a space or tab the board did not render


def want(cond, msg):
    if not cond:
        raise Refusal(msg)


def is_str(v):
    return isinstance(v, str)


def natural(identifier):
    m = re.match(r"^(.*?)-(\d+)$", identifier or "")
    return (m.group(1), int(m.group(2))) if m else (identifier or "", 0)


def node_id(n):
    return n.get("id") if isinstance(n, dict) and is_str(n.get("id")) else None


def load_input(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except OSError as e:
        raise Refusal("input %s cannot be read: %s" % (json.dumps(path), e.strerror))
    except ValueError as e:
        raise Refusal("input %s is not valid JSON: %s" % (json.dumps(path), e))
    want(isinstance(doc, dict), "input is not a JSON object")
    known = {"config", "reads", "snapshot", "layouts", "ledger", "previous", "aliases",
             "in_use", "writes_enabled", "default_space"}
    extra = sorted(set(doc) - known)
    want(not extra, "input has unknown key(s): %s" % ", ".join(extra))

    cfg = doc.get("config")
    want(isinstance(cfg, dict), "config is not the board_config_load object")
    want(isinstance(cfg.get("global"), dict), "config has no global mapping")
    spaces = cfg.get("spaces", {})
    want(isinstance(spaces, dict), "config spaces is not an object")
    for name, m in [("global", cfg["global"])] + list(spaces.items()):
        want(isinstance(m, dict) and isinstance(m.get("levels"), dict) and m["levels"],
             "mapping %s has no levels" % json.dumps(name))
        for level, kind in m["levels"].items():
            want(level in LEVELS, "mapping %s has unknown level %s" % (json.dumps(name), json.dumps(level)))
            want(is_str(kind) and (kind in FIELD_KINDS or kind in ("ticket", "sub-ticket")
                                    or (kind.startswith("label-group:") and len(kind) > 12)),
                 "mapping %s level %s has unknown kind %s" % (json.dumps(name), level, json.dumps(kind)))
    want("global" not in spaces, "a space mapping may not be named global")

    reads = doc.get("reads")
    want(isinstance(reads, list), "reads is not a list")
    seen = set()
    for r in reads:
        want(isinstance(r, dict) and is_str(r.get("mapping")), "a read names no mapping")
        want(r["mapping"] == "global" or r["mapping"] in spaces,
             "a read names mapping %s, which the configuration does not hold" % json.dumps(r["mapping"]))
        want(r["mapping"] not in seen, "two reads name mapping %s" % json.dumps(r["mapping"]))
        seen.add(r["mapping"])
        want(isinstance(r.get("complete"), bool), "read %s has no complete flag" % json.dumps(r["mapping"]))
        want(isinstance(r.get("tickets"), list), "read %s has no ticket list" % json.dumps(r["mapping"]))
        for t in r["tickets"]:
            want(isinstance(t, dict) and is_str(t.get("id")) and t["id"],
                 "read %s holds a ticket with no id" % json.dumps(r["mapping"]))

    snap = doc.get("snapshot")
    if isinstance(snap, dict) and isinstance(snap.get("result"), dict):
        snap = snap["result"].get("snapshot")
    want(isinstance(snap, dict), "snapshot is not a herdr snapshot object")
    for key in ("workspaces", "tabs", "panes"):
        want(isinstance(snap.get(key, []), list), "snapshot %s is not a list" % key)

    for key in ("layouts", "ledger", "previous", "aliases", "in_use"):
        want(isinstance(doc.get(key, {}), dict), "%s is not an object" % key)
    for space, entries in doc.get("ledger", {}).items():
        want(isinstance(entries, dict), "ledger for space %s is not an object" % json.dumps(space))
        for issue, e in entries.items():
            want(isinstance(e, dict) and is_str(e.get("pane_id")) and e.get("role") in ("home", "pointer")
                 and isinstance(e.get("groups"), dict) and isinstance(e.get("board_created"), bool)
                 and isinstance(e.get("hidden"), bool) and is_str(e.get("hidden_fingerprint"))
                 and isinstance(e.get("pending_linear_change"), bool),
                 "ledger entry %s in space %s is not a board-store ledger entry"
                 % (json.dumps(issue), json.dumps(space)))
    want(isinstance(doc.get("writes_enabled", False), bool), "writes_enabled is not a boolean")
    want(is_str(doc.get("default_space", "Board")), "default_space is not a string")
    doc["snapshot"] = snap
    return doc


class Engine:
    def __init__(self, doc):
        self.doc = doc
        cfg = doc["config"]
        self.overrides = list(cfg.get("spaces", {}).keys())
        self.mappings = {"global": cfg["global"]}
        self.mappings.update(cfg.get("spaces", {}))
        self.default_space = doc.get("default_space", "Board")
        reads = {r["mapping"]: r for r in doc["reads"]}
        self.reads = {m: reads.get(m, {"mapping": m, "complete": False, "tickets": []})
                      for m in ["global"] + self.overrides}
        self.complete = all(r["complete"] for r in self.reads.values())
        self.writes = doc.get("writes_enabled", False)
        self.previous = doc.get("previous", {}).get("rendered", {})
        if not isinstance(self.previous, dict):
            self.previous = {}
        self.ledger = doc.get("ledger", {})
        self.aliases = doc.get("aliases", {})
        self.layouts = doc.get("layouts", {})

        self.tickets = {}
        for m in ["global"] + self.overrides:
            for t in self.reads[m]["tickets"]:
                cur = self.tickets.get(t["id"])
                if cur is None or str(t.get("updatedAt") or "") > str(cur.get("updatedAt") or ""):
                    self.tickets[t["id"]] = t
        self.in_read = {m: {t["id"] for t in self.reads[m]["tickets"]} for m in self.reads}

        snap = doc["snapshot"]
        self.ws_label = {w.get("workspace_id"): w.get("label") for w in snap.get("workspaces", []) if isinstance(w, dict)}
        self.tab_info = {t.get("tab_id"): t for t in snap.get("tabs", []) if isinstance(t, dict)}
        self.panes = {p.get("pane_id"): p for p in snap.get("panes", []) if isinstance(p, dict) and is_str(p.get("pane_id"))}
        use = doc.get("in_use", {})
        self.all_in_use = use.get("treat_all_in_use") is True
        busy = {use.get("invoking_pane_id"), snap.get("focused_pane_id")}
        busy |= {pid for pid, p in self.panes.items() if p.get("focused") is True or p.get("agent") is not None}
        busy |= {a.get("pane_id") for a in snap.get("agents", []) or [] if isinstance(a, dict)}
        self.busy = {b for b in busy if is_str(b)}

        self.names = {}
        self.sorts = {}
        self.label_ambiguous = set()
        for t in sorted(self.tickets.values(), key=lambda t: t["id"]):
            for m in self.mappings.values():
                for kind in m["levels"].values():
                    self.value(t, kind)
        self.actions = []

    # ---------------------------------------------------------------- groups

    def none_name(self, kind):
        if kind.startswith("label-group:"):
            return "No %s" % kind[len("label-group:"):]
        return "No %s" % kind

    def remember(self, kind, value, name, sort):
        self.names.setdefault(kind, {})[value] = name
        self.sorts.setdefault(kind, {})[value] = sort

    def value(self, t, kind):
        """A ticket's group value for a level kind, recording its name and order."""
        v, name, sort = None, None, None
        if kind in ("team", "project", "assignee", "parent"):
            n = t.get(kind)
            v = node_id(n)
            if v:
                name = n.get("key") if kind == "team" else n.get("identifier") if kind == "parent" else n.get("name")
                name = name if is_str(name) else v
                sort = natural(name) if kind == "parent" else (name.casefold(), v)
        elif kind == "milestone":
            n = t.get("projectMilestone")
            v = node_id(n)
            if v:
                name = n.get("name") if is_str(n.get("name")) else v
                sort = (name.casefold(), v)
        elif kind == "cycle":
            n = t.get("cycle")
            v = node_id(n)
            if v:
                num = n.get("number")
                name = n.get("name") if is_str(n.get("name")) else ("Cycle %s" % num if num is not None else v)
                sort = (num if isinstance(num, int) else 0, name.casefold(), v)
        elif kind == "state":
            n = t.get("state")
            v = node_id(n)
            if v:
                name = n.get("name") if is_str(n.get("name")) else v
                typ = n.get("type")
                sort = (STATE_ORDER.index(typ) if typ in STATE_ORDER else len(STATE_ORDER), name.casefold(), v)
        elif kind == "priority":
            p = t.get("priority")
            if isinstance(p, int) and not isinstance(p, bool) and 1 <= p <= 4:
                v = str(p)
                name, sort = PRIORITY_NAMES[v], (p,)
        elif kind == "ticket":
            v, name = t["id"], t.get("identifier") or t["id"]
            sort = natural(name)
        elif kind == "sub-ticket":
            parent = t.get("parent")
            if node_id(parent):
                v, name = parent["id"], parent.get("identifier") or parent["id"]
            else:
                v, name = t["id"], t.get("identifier") or t["id"]
            sort = natural(name)
        elif kind.startswith("label-group:"):
            group = kind[len("label-group:"):]
            nodes = ((t.get("labels") or {}).get("nodes") or [])
            hits = sorted(((n.get("name") or "", n["id"]) for n in nodes
                           if node_id(n) and isinstance(n.get("parent"), dict)
                           and n["parent"].get("name") == group), key=lambda x: (x[0].casefold(), x[1]))
            if len(hits) > 1:
                self.label_ambiguous.add((t["id"], kind))
            if hits:
                name, v = hits[0]
                name = name or v
                sort = (name.casefold(), v)
        if v is None:
            self.remember(kind, None, self.none_name(kind), (1,))
            return None
        self.remember(kind, v, name, (0,) + tuple(sort))
        return v

    def name_of(self, kind, value, fallback=None):
        if kind is None:
            return DEFAULT_TAB
        if value is None:
            return self.none_name(kind)
        known = self.names.get(kind, {})
        if value in known:
            return known[value]
        if kind == "priority" and value in PRIORITY_NAMES:
            return PRIORITY_NAMES[value]
        return fallback if fallback is not None else str(value)

    def sort_of(self, kind, value, name):
        if value is None:
            return (1,)
        return self.sorts.get(kind, {}).get(value, (0, str(name).casefold(), str(value)))

    def levels(self, mapping):
        return self.mappings[mapping]["levels"]

    def mapping_of_space(self, space):
        return space if space in self.overrides else "global"

    def dims(self, mapping):
        lv = self.levels(mapping)
        order = LEVELS if mapping == "global" else LEVELS[1:]
        return [(level, lv[level]) for level in order if level in lv]

    def groups_for(self, t, mapping):
        return {kind: self.value(t, kind) for _, kind in self.dims(mapping)}

    def global_space(self, t):
        kind = self.levels("global").get("space")
        if kind is None:
            return self.default_space
        return self.name_of(kind, self.value(t, kind))

    # ---------------------------------------------------------------- claims

    def ledger_home(self, issue):
        homes = sorted(s for s, entries in self.ledger.items()
                       if issue in entries and entries[issue]["role"] == "home")
        return homes

    def placements(self):
        out = {}
        for issue in sorted(set(self.tickets)):
            t = self.tickets[issue]
            homes = self.ledger_home(issue)
            gspace = self.global_space(t)
            global_claim = issue in self.in_read["global"] or (
                not self.reads["global"]["complete"]
                and any(self.mapping_of_space(s) == "global" for s in homes))
            if gspace in self.overrides:
                global_claim = False
            claimers = []
            for name in self.overrides:
                if issue in self.in_read[name] or (
                        not self.reads[name]["complete"] and issue in self.ledger.get(name, {})):
                    claimers.append(name)
            spaces = []
            if global_claim:
                spaces.append((gspace, "global", "home"))
                spaces += [(n, n, "pointer") for n in claimers]
            elif claimers:
                spaces.append((claimers[0], claimers[0], "home"))
                spaces += [(n, n, "pointer") for n in claimers[1:]]
            for space, mapping, role in spaces:
                out[(issue, role, space)] = {"issue": issue, "space": space, "mapping": mapping, "role": role,
                                             "groups": self.groups_for(t, mapping)}
        return out

    # ---------------------------------------------------------------- herdr reading

    def resolve(self, entry, issue):
        pid = entry["pane_id"]
        if pid in self.panes:
            return pid, None
        alias = self.aliases.get(pid)
        if is_str(alias) and alias in self.panes:
            return alias, "alias"
        label = "board:%s" % issue
        found = sorted(p for p, pane in self.panes.items() if pane.get("label") == label)
        if found:
            return found[0], "board-label"
        return None, None

    def in_use(self, pane_id):
        return self.all_in_use or pane_id in self.busy

    def tree_of(self, tab_id):
        lay = self.layouts.get(tab_id)
        if isinstance(lay, dict) and isinstance(lay.get("result"), dict):
            lay = lay["result"]
        if isinstance(lay, dict) and isinstance(lay.get("root"), dict):
            lay = lay["root"]
        return lay if isinstance(lay, dict) and lay.get("type") in ("split", "pane") else None

    @staticmethod
    def flatten(node, direction):
        if node.get("type") == "split" and node.get("direction") == direction \
                and isinstance(node.get("first"), dict) and isinstance(node.get("second"), dict):
            return Engine.flatten(node["first"], direction) + Engine.flatten(node["second"], direction)
        return [node]

    @staticmethod
    def leaves(node):
        if node.get("type") == "split":
            out = []
            for k in ("first", "second"):
                if isinstance(node.get(k), dict):
                    out += Engine.leaves(node[k])
            return out
        return [node.get("pane_id")]

    def ordered(self, space, kind, values):
        """The previous render's order of a tab's groups, or None when unknown."""
        order = self.previous.get(space, {}).get(kind)
        if not isinstance(order, list) or any(v not in order for v in values):
            return None
        return [v for v in order if v in values]

    def previous_tab(self, space, tab_value):
        mapping = self.mapping_of_space(space)
        lv = self.levels(mapping)
        tk, ck, rk = lv.get("tab"), lv.get("column"), lv.get("row")
        entries = {i: e for i, e in self.ledger.get(space, {}).items()
                   if not e["hidden"] and (tk is None or e["groups"].get(tk, MISSING) == tab_value)}
        cols = [ANY] if ck is None else self.ordered(space, ck, {e["groups"].get(ck) for e in entries.values()})
        rows, heights = None, None
        if rk is not None:
            rows = self.ordered(space, rk, {e["groups"].get(rk) for e in entries.values()})
            if rows is not None and cols is not None:
                heights = []
                for r in rows:
                    counts = [sum(1 for e in entries.values()
                                  if (ck is None or e["groups"].get(ck) == c) and e["groups"].get(rk) == r)
                              for c in cols]
                    heights.append(max(counts + [1]))
        return entries, cols, rows, heights

    def tab_lost(self, space, tab_value, tab_id):
        entries, _, _, _ = self.previous_tab(space, tab_value)
        for issue, e in entries.items():
            pid, _ = self.resolve(e, issue)
            if pid is None or self.panes[pid].get("tab_id") != tab_id:
                return True
        return False

    def label_value(self, space, kind, label, own):
        """A herdr space or tab label read back as a group value of <kind>."""
        if label == self.none_name(kind):
            return None
        known = [v for v, n in self.names.get(kind, {}).items() if v is not None and n == label]
        if kind == "priority":
            known = sorted(set(known) | {v for v, n in PRIORITY_NAMES.items() if n == label})
        if len(known) == 1:
            return known[0]
        if len(known) > 1:
            return AMBIG
        if own is not MISSING and own is not None and own not in self.names.get(kind, {}):
            return own
        return OUTSIDE

    def read_position(self, space, entry, issue, pane_id):
        """Where herdr has a pane: ({kind: value | UNKNOWN | AMBIG}, target space, lost flag),
        or OUTSIDE when it sits in a space or tab the board did not render."""
        mapping = self.mapping_of_space(space)
        pane = self.panes[pane_id]
        tab = self.tab_info.get(pane.get("tab_id"), {})
        ws_label = self.ws_label.get(pane.get("workspace_id"))
        lv = self.levels(mapping)
        E = entry["groups"]
        H = {}
        target = space
        if ws_label != space:
            if mapping != "global" or ws_label in self.overrides or not is_str(ws_label):
                return OUTSIDE
            sk = lv.get("space")
            if sk is None:
                return OUTSIDE
            v = self.label_value(space, sk, ws_label, MISSING)
            rendered = {pl["space"] for pl in self.desired.values() if pl["mapping"] == "global"} | \
                       {s for s in self.ledger if self.mapping_of_space(s) == "global"}
            if v is OUTSIDE or v is AMBIG or ws_label not in rendered:
                return OUTSIDE
            H[sk] = v
            target = ws_label
        elif mapping == "global" and "space" in lv:
            H[lv["space"]] = E.get(lv["space"], MISSING) if E.get(lv["space"], MISSING) is not MISSING \
                else self.label_value(space, lv["space"], ws_label, MISSING)

        tk = lv.get("tab")
        if tk is None:
            if tab.get("label") != DEFAULT_TAB:
                return OUTSIDE
            tab_value = None
        else:
            own = E.get(tk, MISSING) if target == space else MISSING
            v = self.label_value(target, tk, tab.get("label"), own)
            if v is OUTSIDE or v is AMBIG:
                return OUTSIDE
            rendered_tabs = {e["groups"].get(tk) for e in self.ledger.get(target, {}).values()}
            rendered_tabs |= {pl["groups"].get(tk) for pl in self.desired.values() if pl["space"] == target}
            if v not in rendered_tabs:
                return OUTSIDE
            H[tk] = v
            tab_value = v

        ck, rk = lv.get("column"), lv.get("row")
        lost = False
        if ck is not None or rk is not None:
            tree = self.tree_of(pane.get("tab_id"))
            _, cols, rows, heights = self.previous_tab(target, tab_value)
            lost = self.tab_lost(target, tab_value, pane.get("tab_id"))
            col_v, row_v = UNKNOWN, UNKNOWN
            if tree is not None:
                columns = self.flatten(tree, "right")
                for ci, col in enumerate(columns):
                    members = self.flatten(col, "down")
                    for ri, member in enumerate(members):
                        if pane_id not in self.leaves(member):
                            continue
                        if member.get("type") != "pane":
                            col_v, row_v = AMBIG, AMBIG
                            break
                        if cols is not None and len(columns) == len(cols):
                            col_v = cols[ci]
                        if rows is not None and heights is not None and len(members) == sum(heights) \
                                and all(m.get("type") == "pane" for m in members) and col_v is not UNKNOWN:
                            acc = 0
                            for r, h in zip(rows, heights):
                                if ri < acc + h:
                                    row_v = r
                                    break
                                acc += h
                    else:
                        continue
                    break
            if ck is not None:
                H[ck] = col_v
            if rk is not None:
                H[rk] = row_v
        return H, target, lost

    # ---------------------------------------------------------------- actions

    def act(self, kind, space, issue, role, pane_id=None, reason=None, **extra):
        t = self.tickets.get(issue, {})
        a = {"kind": kind, "space": space, "issue_id": issue, "identifier": t.get("identifier"),
             "role": role, "pane_id": pane_id, "reason": reason, "in_use": False, "tab": None}
        a.update(extra)
        self.actions.append(a)
        return a

    def tab_name_for(self, mapping, groups):
        tk = self.levels(mapping).get("tab")
        return DEFAULT_TAB if tk is None else self.name_of(tk, groups.get(tk))

    def classify_dim(self, kind, level, L, E, H, pending, role, lost, issue):
        if E is MISSING:
            if H is AMBIG:
                return "conflict", "ambiguous-layout"
            return ("linear", None) if H is UNKNOWN or H != L else ("agree", None)
        if H is AMBIG:
            return "conflict", "ambiguous-layout"
        if H is UNKNOWN or H == E:
            return ("none", None) if L == E else ("linear", None)
        if pending:
            if H == L:
                return "agree", None
            return ("restore", None) if L == E else ("linear", None)
        if L == E:
            if lost and level in ("column", "row"):
                return "conflict", "tab-lost-a-pane"
            if role == "pointer":
                return "restore", None
            if kind == "ticket" or (issue, kind) in self.label_ambiguous \
                    or (kind == "sub-ticket" and H == issue):
                return "conflict", "not-writable"
            return ("writeback", None) if self.writes else ("restore", None)
        if H == L:
            return "agree", None
        if lost and level in ("column", "row"):
            return "conflict", "tab-lost-a-pane"
        return "conflict", "both-changed"

    def run(self):
        desired = self.desired = self.placements()
        items = []   # leaves for the desired tree: (space, mapping, issue, role, groups, pane_id, hold)
        consumed = set()

        rebuilt = set()
        for space, entries in self.ledger.items():
            live = [(i, e) for i, e in entries.items() if not e["hidden"]]
            if live and all(self.resolve(e, i)[0] is None for i, e in live):
                rebuilt.add(space)

        for key in sorted(desired, key=lambda k: (k[0], k[1], k[2])):
            issue, role, space = key
            pl = desired[key]
            t = self.tickets[issue]
            mapping = pl["mapping"]
            L = pl["groups"]
            tab_name = self.tab_name_for(mapping, L)
            for _, kind in self.dims(mapping):
                if (issue, kind) in self.label_ambiguous:
                    self.act("conflict-question", space, issue, role, reason="label-group-ambiguous",
                             fields=[kind], tab=tab_name)

            if role == "home":
                homes = self.ledger_home(issue)
                lspace = space if space in homes else (homes[0] if homes else None)
            else:
                e = self.ledger.get(space, {}).get(issue)
                lspace = space if e is not None and e["role"] == "pointer" else None
            if lspace is None:
                self.act("place", space, issue, role, reason="entered", groups=L, tab=tab_name)
                items.append((space, mapping, issue, role, L, None, False))
                continue
            consumed.add((lspace, issue))
            entry = self.ledger[lspace][issue]

            was_hidden = entry["hidden"]
            if was_hidden:
                if entry["hidden_fingerprint"] == str(t.get("updatedAt") or ""):
                    continue
                self.act("unhide", lspace, issue, role, pane_id=entry["pane_id"], reason="ticket-changed")
                entry = dict(entry, hidden=False)

            if lspace in rebuilt:
                kind = "recreate-pointer" if role == "pointer" else "place"
                self.act(kind, space, issue, role, reason="rebuilt", groups=L, tab=tab_name)
                items.append((space, mapping, issue, role, L, None, False))
                continue

            pane_id, how = self.resolve(entry, issue)
            if pane_id is None:
                if role == "pointer":
                    self.act("recreate-pointer", space, issue, role, reason="pane-missing", groups=L, tab=tab_name)
                    items.append((space, mapping, issue, role, L, None, False))
                elif was_hidden:
                    self.act("place", space, issue, role, reason="ticket-changed", groups=L, tab=tab_name)
                    items.append((space, mapping, issue, role, L, None, False))
                else:
                    self.act("hide", lspace, issue, role, pane_id=entry["pane_id"], reason="pane-missing",
                             fingerprint=str(t.get("updatedAt") or ""))
                continue
            if how is not None:
                self.act("relink", lspace, issue, role, pane_id=pane_id, reason=how, previous_pane_id=entry["pane_id"])

            pos = self.read_position(lspace, entry, issue, pane_id)
            if pos is OUTSIDE:
                if role == "pointer":
                    self.moved(space, mapping, issue, role, L, pane_id, entry, "restore", items, tab_name)
                else:
                    self.act("hide", lspace, issue, role, pane_id=pane_id, reason="moved-out-of-board",
                             fingerprint=str(t.get("updatedAt") or ""))
                continue
            H, _, lost = pos
            E = dict(entry["groups"])
            if mapping == "global" and "space" in self.levels("global") and lspace != space:
                sk = self.levels("global")["space"]
                E.setdefault(sk, MISSING)
            outcome = {}
            for level, kind in self.dims(mapping):
                e_v = E.get(kind, MISSING)
                h_v = H.get(kind, e_v if e_v is not MISSING else L.get(kind))
                outcome[kind] = (level,) + self.classify_dim(kind, level, L.get(kind), e_v, h_v,
                                                            entry["pending_linear_change"], role, lost, issue)
                outcome[kind] += (h_v, e_v)

            conflicts = [(k, o) for k, o in outcome.items() if o[1] == "conflict"]
            if conflicts:
                reasons = [o[2] for _, o in conflicts]
                reason = next(r for r in ("ambiguous-layout", "tab-lost-a-pane", "not-writable", "both-changed")
                              if r in reasons)
                self.act("conflict-question", lspace, issue, role, pane_id=pane_id, reason=reason,
                         fields=sorted(k for k, _ in conflicts), in_use=self.in_use(pane_id),
                         tab=self.tab_name_for(mapping, L))
                hold = {k: (v if v is not MISSING else L.get(k)) for k, v in
                        ((k, E.get(k, MISSING)) for _, k in self.dims(mapping))}
                items.append((lspace, self.mapping_of_space(lspace), issue, role, hold, pane_id, True))
                continue

            tree_groups = dict(L)
            for kind, o in outcome.items():
                if o[1] == "writeback":
                    tree_groups[kind] = o[3]
                    self.act("write-back-candidate", space, issue, role, pane_id=pane_id, reason="herdr-move",
                             field=kind, write_field=WRITE_FIELD.get(kind, "labelGroup"),
                             target_value=o[3], target_name=self.name_of(kind, o[3]), from_value=o[4],
                             restore_groups=L, tab=self.tab_name_for(mapping, L))
            if any(o[1] == "agree" for o in outcome.values()):
                self.act("agreement", space, issue, role, pane_id=pane_id, reason="both-moved",
                         groups=tree_groups, tab=self.tab_name_for(mapping, tree_groups))
            kinds = {o[1] for o in outcome.values()}
            if "linear" in kinds or "restore" in kinds or lspace != space:
                reason = "linear-change" if ("linear" in kinds or lspace != space) else "restore"
                self.moved(space, mapping, issue, role, tree_groups, pane_id, entry, reason, items,
                           self.tab_name_for(mapping, tree_groups))
            else:
                items.append((space, mapping, issue, role, tree_groups, pane_id, False))

        for space in sorted(self.ledger):
            for issue in sorted(self.ledger[space]):
                if (space, issue) in consumed:
                    continue
                entry = self.ledger[space][issue]
                role = entry["role"]
                mapping = self.mapping_of_space(space)
                pane_id, _ = self.resolve(entry, issue)
                if not self.complete:
                    if not entry["hidden"] and pane_id is not None:
                        items.append((space, mapping, issue, role, dict(entry["groups"]), pane_id, True))
                    continue
                if entry["hidden"] or pane_id is None or not entry["board_created"]:
                    self.act("forget", space, issue, role, pane_id=entry["pane_id"], reason="left-view")
                    continue
                self.act("close-question", space, issue, role, pane_id=pane_id, reason="left-view",
                         in_use=self.in_use(pane_id))

        return self.render(items)

    def moved(self, space, mapping, issue, role, groups, pane_id, entry, reason, items, tab_name):
        items.append((space, mapping, issue, role, groups, pane_id, False))
        if not entry["board_created"]:
            return
        busy = self.in_use(pane_id)
        self.act("move-question" if busy else "move", space, issue, role, pane_id=pane_id, reason=reason,
                 groups=groups, in_use=busy, tab=tab_name)

    # ---------------------------------------------------------------- the desired tree

    def fallback_name(self, kind, value, pane_id, level):
        if pane_id is None or pane_id not in self.panes:
            return None
        pane = self.panes[pane_id]
        if level == "tab":
            return self.tab_info.get(pane.get("tab_id"), {}).get("label")
        if level == "space":
            return self.ws_label.get(pane.get("workspace_id"))
        return None

    @staticmethod
    def chain(nodes, direction):
        if len(nodes) == 1:
            return nodes[0]
        return {"type": "split", "direction": direction, "ratio": round(1.0 / len(nodes), 4),
                "first": nodes[0], "second": Engine.chain(nodes[1:], direction)}

    def render(self, items):
        by_space = {}
        for space, mapping, issue, role, groups, pane_id, hold in items:
            by_space.setdefault(space, (mapping, []))[1].append((issue, role, groups, pane_id, hold))

        rendered = {}
        spaces_out = []

        def space_order(name):
            if name in self.overrides:
                return (1, self.overrides.index(name), name)
            sk = self.levels("global").get("space")
            if sk is None:
                return (0, (0,), name)
            vals = [g.get(sk) for _, _, g, _, _ in by_space[name][1]]
            v = vals[0] if vals else None
            return (0, self.sort_of(sk, v, name), name)

        for space in sorted(by_space, key=space_order):
            mapping, leaves = by_space[space]
            lv = self.levels(mapping)
            tk, ck, rk = lv.get("tab"), lv.get("column"), lv.get("row")
            if mapping == "global" and "space" in lv:
                rendered.setdefault(space, {})[lv["space"]] = sorted(
                    {g.get(lv["space"]) for _, _, g, _, _ in leaves},
                    key=lambda v: (self.sort_of(lv["space"], v, self.name_of(lv["space"], v)), str(v)))

            def ordered_values(kind, subset, level):
                vals = {g.get(kind) for _, _, g, _, _ in subset}
                names = {}
                for _, _, g, pid, _ in subset:
                    names.setdefault(g.get(kind), self.name_of(kind, g.get(kind), self.fallback_name(kind, g.get(kind), pid, level)))
                return sorted(vals, key=lambda v: (self.sort_of(kind, v, names[v]), str(names[v]), str(v))), names

            tabs_out = []
            if tk is not None:
                tab_values, tab_names = ordered_values(tk, leaves, "tab")
                rendered.setdefault(space, {})[tk] = tab_values
            else:
                tab_values, tab_names = [None], {None: DEFAULT_TAB}
            for tv in tab_values:
                in_tab = [x for x in leaves if tk is None or x[2].get(tk) == tv]
                if ck is not None:
                    col_values, _ = ordered_values(ck, in_tab, "column")
                    rendered.setdefault(space, {}).setdefault(ck, [])
                    for v in col_values:
                        if v not in rendered[space][ck]:
                            rendered[space][ck].append(v)
                else:
                    col_values = [ANY]
                row_values = None
                if rk is not None:
                    row_values, _ = ordered_values(rk, in_tab, "row")
                    rendered.setdefault(space, {}).setdefault(rk, [])
                    for v in row_values:
                        if v not in rendered[space][rk]:
                            rendered[space][rk].append(v)

                def leaf(x):
                    issue, role, groups, pane_id, hold = x
                    t = self.tickets.get(issue, {})
                    node = {"type": "pane", "issue_id": issue, "identifier": t.get("identifier"), "role": role,
                            "pane_id": pane_id, "board_label": "board:%s" % issue}
                    if hold:
                        node["hold"] = True
                    return node

                def cell_order(x):
                    issue = x[0]
                    heads = any(x[2].get(k) == issue for k in (ck, rk) if k == "sub-ticket")
                    return (0 if heads else 1, natural(self.tickets.get(issue, {}).get("identifier") or issue), issue)

                cells = {}
                for x in in_tab:
                    c = ANY if ck is None else x[2].get(ck)
                    r = ANY if rk is None else x[2].get(rk)
                    cells.setdefault((c, r), []).append(x)
                heights = {}
                if rk is not None:
                    for r in row_values:
                        heights[r] = max([len(cells.get((c, r), [])) for c in col_values] + [1])
                columns = []
                for c in col_values:
                    if rk is None:
                        slots = [leaf(x) for x in sorted(cells.get((c, ANY), []), key=cell_order)]
                    else:
                        slots = []
                        for r in row_values:
                            here = [leaf(x) for x in sorted(cells.get((c, r), []), key=cell_order)]
                            here += [{"type": "anchor", "column": c, "row": r}] * (heights[r] - len(here))
                            slots += here
                    columns.append(self.chain(slots, "down"))
                tabs_out.append({"name": tab_names[tv] if tk is not None else DEFAULT_TAB,
                                 "value": tv, "tree": self.chain(columns, "right")})
            spaces_out.append({"name": space, "mapping": mapping, "tabs": tabs_out})

        members = sorted({t for r in self.reads.values() for t in (x["id"] for x in r["tickets"])})
        order = {k: i for i, k in enumerate(KIND_ORDER)}
        actions = sorted(self.actions, key=lambda a: (a["space"], a["issue_id"], order[a["kind"]],
                                                       str(a.get("field") or ""), a["role"]))
        return {"complete": self.complete, "members": members, "rendered": rendered,
                "spaces": spaces_out, "actions": actions}


def main():
    try:
        doc = load_input(sys.argv[1])
        plan = Engine(doc).run()
    except Refusal as r:
        sys.stderr.write("refused: board plan input %s\n" % r)
        return REFUSED
    sys.stdout.write(json.dumps(plan, sort_keys=True))
    sys.stdout.write("\n")
    return 0


sys.exit(main())
PYEOF
}
