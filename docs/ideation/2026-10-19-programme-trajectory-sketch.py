#!/usr/bin/env python3
# Disposable decision sketch, round 2. Display only, fake data. Needs a Nerd Font (octicons).
import curses

I = {
    "done": "",     # oct-check_circle_fill
    "now": "\uf500",      # oct-play
    "plan": "",     # oct-circle
    "new": "",      # oct-plus
    "drop": "",     # oct-x
    "goal": "",     # oct-goal
    "agent": "",    # oct-copilot
    "pane": "",     # oct-terminal
    "item": "",     # oct-issue_opened
    "wait": "󰔟", # md-timer_sand
    "pulse": "",    # oct-pulse
    "sync": "",     # oct-sync
    "branch": "",   # oct-git_branch
}

SESSIONS = [
    {
        "tab": "AI-Editor", "pane": "owner-history", "item": "Export owner history",
        "done": ["Read view builder", "Add owner history field"],
        "now": "Write view test", "wait": None,
        "plan": ["Run auto suite", "Open PR"],
        "replan": {"at": 0, "dropped": ["Run auto suite"], "added": ["Fix fixture drift", "Run auto suite"],
                   "why": "test showed fixture drift"},
        "finish": "PR open, CI green",
    },
    {
        "tab": "AI-Editor", "pane": "retry-watcher", "item": "Retry watcher",
        "done": ["Reproduce stale wait"],
        "now": "Waiting on CI", "wait": "watcher live · 40s",
        "plan": ["Check retry result", "Hand to Shawn"],
        "replan": {"at": 1, "dropped": ["Hand to Shawn"], "added": ["Close item"],
                   "why": "answer already recorded"},
        "finish": "item closed with evidence",
    },
    {
        "tab": "Infra", "pane": "linux-check", "item": "Linux browser check",
        "done": [],
        "now": "Install toolchain", "wait": None,
        "plan": ["Build", "Run browser check", "Report"],
        "replan": {"at": 0, "dropped": ["Build", "Run browser check"], "added": ["Ask PM: is this needed?"],
                   "why": "not part of acceptance"},
        "finish": "report filed",
    },
]

VIEWS = {"1": "Statusline (prompt band)", "2": "List (side pane)", "3": "Todo tree (side pane)", "4": "Contract (side pane)"}

CITES = {
    "Write view test": "autonomy · run tests", "Run auto suite": "autonomy · run tests", "Open PR": "autonomy · open PR",
    "Fix fixture drift": None, "Waiting on CI": "stop rule", "Check retry result": "autonomy · read CI",
    "Hand to Shawn": "instruction · ask before closing", "Close item": "autonomy · close item",
    "Install toolchain": None, "Build": None, "Run browser check": None, "Report": "remit",
    "Ask PM: is this needed?": "instruction · Linux not in acceptance",
}

C_ICON = {"law": "\uf495", "code": "\uf510", "guide": "\uf4f6", "unread": "\uf4a3", "alert": "\uf421",
          "note": "\uf41f", "draft": "\uf4e7", "history": "\uf464", "eye": "\uf441"}

AGREEMENT = [
    # key, value, binds, cited_by, set_by, why
    ("remit", "AI-Editor tab", "code", 4, "you · 12 Oct", "the herdr space it started in"),
    ("stop rule", "nothing it can act on", "code", 1, "default", ""),
    ("autonomy", "ask first", "guide", 6, "you · 12 Oct", "early in the project"),
    ("cadence", "every 15 min", "code", 0, "default", ""),
    ("tools of record", "Linear, GitHub", "unread", 0, "you · 12 Oct", ""),
]
INSTRUCTIONS = [
    ("ask before closing", "programme", "inherited", 1),
    ("Linux not in acceptance", "Linux browser check", "own", 1),
]
CONTRACT = {"redline": False, "readback": False}


def plan_of(s, replanned):
    if not replanned:
        return list(s["plan"])
    r = s["replan"]
    keep = [p for p in s["plan"] if p not in r["dropped"]]
    return keep[: r["at"]] + r["added"] + keep[r["at"]:]


def is_new(s, p, replanned):
    return replanned and p in s["replan"]["added"]


def dropped(s, replanned):
    return [d for d in s["replan"]["dropped"] if d not in plan_of(s, replanned)] if replanned else []


def put(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if 0 <= y < h - 1 and x < w - 1:
        win.addnstr(y, x, text, max(0, w - x - 1), attr)
    return x + len(text)


def where(s):
    return f"{s['tab']} › {s['pane']}"


FA = {"done": "\uf111", "plan": "\uf10c", "new": "\uf192"}  # fa-circle, fa-circle_o, fa-dot_circle_o
CAP_L, CAP_R = "\ue0b6", "\ue0b4"  # ple-left/right_half_circle_thick


def pill(win, y, x, text, attr):
    x = put(win, y, x, CAP_L, attr)
    x = put(win, y, x, f" {text} ", attr | curses.A_REVERSE)
    return put(win, y, x, CAP_R, attr)


BAND = {"focus": 0, "cursor": {}, "hits": []}  # hits: (y, x0, x1, session index, step index or None)


def steps_of(s, replanned):
    rows = [("done", d) for d in s["done"]]
    rows.append(("now", s["now"]))
    rows += [("plan", p) for p in plan_of(s, replanned)]
    return rows


def active_index(s):
    return len(s["done"])


def step_icon(kind, s, text, replanned):
    if kind == "done":
        return FA["done"]
    if kind == "now":
        return I["wait"] if s["wait"] else FA["done"]
    return FA["new"] if is_new(s, text, replanned) else FA["plan"]


def step_attr(kind, idx, s, text, C, replanned):
    if kind == "done":
        return C["done"]
    if kind == "now":
        return C["now"]
    if idx == active_index(s) + 1:
        return C["new"] if is_new(s, text, replanned) else C["plan"]
    return 0


def draw_segment(win, y, x, si, s, C, replanned, focused, record=True):
    rows = steps_of(s, replanned)
    cursor = BAND["cursor"].get(si, active_index(s)) if focused else None
    x0 = x
    x = put(win, y, x, s["item"] + " ", curses.A_BOLD if focused else 0)
    for idx, (kind, text) in enumerate(rows):
        if idx:
            x = put(win, y, x, "━" if rows[idx - 1][0] == "done" else "┄", C["dim"])
        attr = step_attr(kind, idx, s, text, C, replanned)
        sx = x
        if focused and idx == cursor:
            label = (I["wait"] + " " if kind == "now" and s["wait"] else "") + text
            x = pill(win, y, x, label, attr or C["dim"])
        else:
            x = put(win, y, x, step_icon(kind, s, text, replanned), attr)
        if record:
            BAND["hits"].append((y, sx, x, si, idx))
    x = put(win, y, x, "┄", C["dim"])
    x = put(win, y, x, I["goal"] + " ")
    x = put(win, y, x, s["finish"], curses.A_DIM)
    if replanned:
        x = put(win, y, x + 1, I["sync"], C["new"])
    if focused:
        x = put(win, y, x + 2, f"{I['pane']} {where(s)}", curses.A_DIM)
    if record:
        BAND["hits"].append((y, x0, x, si, None))
    return x


class Measure:
    def __init__(self): self.x = 0
    def getmaxyx(self): return (60, 10_000)
    def addnstr(self, y, x, t, n, a=0): self.x = max(self.x, x + len(t))


def seg_width(si, s, C, replanned, focused):
    m = Measure()
    return draw_segment(m, 0, 0, si, s, C, replanned, focused, record=False)


def view_statusline(win, y, C, replanned, sessions=None):
    sessions = sessions or SESSIONS * 2
    BAND["hits"] = []
    BAND["focus"] %= len(sessions)
    h, w = win.getmaxyx()
    line, x, shown = 0, 1, 0
    for si, s in enumerate(sessions):
        focused = si == BAND["focus"]
        need = seg_width(si, s, C, replanned, focused) + 3
        if x > 1 and x + need > w - 8:
            if line == 1:
                break
            line, x = 1, 1
        if x > 1:
            x = put(win, y + line, x, "  │  ", C["dim"])
        x = draw_segment(win, y + line, x, si, s, C, replanned, focused)
        shown += 1
    if shown < len(sessions):
        put(win, y + line, x + 2, f"+{len(sessions) - shown} more", curses.A_BOLD)
    put(win, y + 3, 1, "Tab / Shift-Tab: next / previous task · ← →: move through steps · mouse: hover a task, click a dot",
        C["dim"])
    put(win, y + 4, 1, "Collapsed: task · dots · deliverable.  Focused: the selected step opens as a pill, location appears.",
        C["dim"])


def band_key(k, n_sessions, replanned, sessions=None):
    sessions = sessions or SESSIONS * 2
    f = BAND["focus"]
    s = sessions[f]
    last = len(steps_of(s, replanned)) - 1
    cur = BAND["cursor"].get(f, active_index(s))
    if k == "\t":
        BAND["focus"] = (f + 1) % len(sessions)
    elif k == "KEY_BTAB":
        BAND["focus"] = (f - 1) % len(sessions)
    elif k == "KEY_RIGHT":
        BAND["cursor"][f] = min(last, cur + 1)
    elif k == "KEY_LEFT":
        BAND["cursor"][f] = max(0, cur - 1)


def band_mouse(my, mx, clicked):
    for (y, x0, x1, si, idx) in BAND["hits"]:
        if y == my and x0 <= mx < x1:
            if idx is None:
                if BAND["focus"] != si:
                    BAND["focus"] = si
                continue
            BAND["focus"] = si
            if clicked:
                BAND["cursor"][si] = idx
            return


def view_list(win, y, C, replanned):
    for s in SESSIONS:
        plan = plan_of(s, replanned)
        x = put(win, y, 1, I["item"] + " ", C["item"])
        x = put(win, y, x, s["item"] + "   ", curses.A_BOLD)
        x = put(win, y, x, I["pane"] + " ", curses.A_DIM)
        put(win, y, x, where(s), curses.A_DIM); y += 1
        last = f"  ·  last: {s['done'][-1]}" if s["done"] else ""
        rows = [(I["done"], f"{len(s['done'])} done{last}", C["done"], 0)]
        if s["wait"]:
            rows.append((I["wait"], f"{s['now']}  {I['pulse']} {s['wait']}", C["now"], curses.A_BOLD))
        else:
            rows.append((I["now"], s["now"], C["now"], curses.A_BOLD))
        for i, p in enumerate(plan, 1):
            n = is_new(s, p, replanned)
            rows.append((I["new"] if n else I["plan"], f"{i}. {p}" + ("   new" if n else ""),
                         (C["new"] if n else C["plan"]) if i == 1 else 0, 0))
        rows += [(I["drop"], f"{d}   dropped", 0, curses.A_DIM) for d in dropped(s, replanned)]
        rows.append((I["goal"], s["finish"], 0, 0))
        for ri, (icon, text, iattr, tattr) in enumerate(rows):
            x = put(win, y, 2, "└─ " if ri == len(rows) - 1 else "├─ ", curses.A_DIM)
            x = put(win, y, x, icon + " ", iattr)
            x = put(win, y, x, text, tattr)
            key = text.split(". ", 1)[-1].split("  ")[0].replace("   new", "")
            if key in CITES and "dropped" not in text:
                c = CITES[key]
                if c:
                    x = put(win, y, x + 3, C_ICON["law"] + " ", curses.A_DIM)
                    put(win, y, x, c, curses.A_DIM)
                else:
                    x = put(win, y, x + 3, C_ICON["alert"] + " ", C["new"])
                    put(win, y, x, "no clause", curses.A_DIM)
            y += 1
        if replanned:
            x = put(win, y, 5, I["sync"] + " ", C["new"])
            put(win, y, x, f"plan changed: {s['replan']['why']}"); y += 1
        y += 1


OPTIONS = {
    "remit": ["this herdr space", "AI-Editor tab"],
    "stop rule": ["nothing it can act on", "only when done", "until a set time", "never stop"],
    "autonomy": ["ask first", "act and tell", "act silently"],
    "cadence": ["every 5 min", "every 15 min", "every 30 min"],
    "tools of record": ["Linear", "GitHub", "Datadog", "Amplitude"],
}
TERM_DESC = {
    "remit": "Which work the PM looks after",
    "stop rule": "When the PM may stop working",
    "autonomy": "What the PM may do without asking you",
    "cadence": "How often the PM checks on work",
    "tools of record": "Where work and evidence live; the PM checks these",
}
OPT_DESC = {
    "this herdr space": "Every tab and pane in the space it started in",
    "AI-Editor tab": "Only work in the AI-Editor tab",

    "nothing it can act on": "Stop when every open task waits on someone else",
    "only when done": "Stop only when every task is done, handed or dropped",
    "until a set time": "Keep working until a time you set",
    "never stop": "Keep working until you end the programme",
    "ask first": "Ask you before acting on anything new",
    "act and tell": "Act, then tell you what it did",
    "act silently": "Act without reporting each action",
    "every 5 min": "Check often; uses more budget",
    "every 15 min": "Balanced",
    "every 30 min": "Check rarely; slower to notice changes",
    "Linear": "Tickets and their states",
    "GitHub": "Pull requests, checks and issues",
    "Datadog": "Errors, logs and service health",
    "Amplitude": "Product usage and funnels",
    "every 10 min": "Your custom interval",
    "Sentry": "Added by you",
    "Infra space": "Added by you",
}
MULTI = {"tools of record"}
ADDABLE = {"remit": ("Add a space…", "Infra space"),
           "cadence": ("Set a custom interval…", "every 10 min"),
           "tools of record": ("Add a tool…", "Sentry")}
CHECK_ON, CHECK_OFF, PLUS = "\uf046", "\uf096", "\uf44d"  # fa-check_square_o, fa-square_o, oct-plus
CS = {"sel": 2, "open": {2}, "opt": {}, "proposed": {}, "notes": {2: ["revisit after first week"]},
      "prompt": "", "status": ""}


def term_value(i):
    return AGREEMENT[i][1]


def active_set(i):
    key, value = AGREEMENT[i][0], AGREEMENT[i][1]
    return {v.strip() for v in value.split(",")} if key in MULTI else {value}


def option_rows(i):
    key = AGREEMENT[i][0]
    rows = list(OPTIONS[key])
    if key in ADDABLE:
        rows.append(None)  # the add row
    return rows


def contract_key(k):
    n = len(AGREEMENT)
    i = CS["sel"]
    key, value = AGREEMENT[i][0], AGREEMENT[i][1]
    rows = option_rows(i)
    default = rows.index(value) if value in rows else 0
    oc = CS["opt"].get(i, default)
    if i in CS["open"] and k in ("KEY_DOWN", "j") and oc < len(rows) - 1:
        CS["opt"][i] = oc + 1
    elif i in CS["open"] and k in ("KEY_UP", "k") and oc > 0:
        CS["opt"][i] = oc - 1
    elif k in ("\t", "KEY_DOWN", "j"):
        CS["sel"] = (i + 1) % n
    elif k in ("KEY_BTAB", "KEY_UP", "k"):
        CS["sel"] = (i - 1) % n
    elif k in ("KEY_RIGHT", "l") or (k in ("\n", "KEY_ENTER") and i not in CS["open"]):
        CS["open"].add(i)
    elif k in ("KEY_LEFT", "h"):
        CS["open"].discard(i)
    elif k in (" ", "\n", "KEY_ENTER") and i in CS["open"]:
        choice = rows[oc]
        if choice is None:
            label, typed = ADDABLE[key]
            OPTIONS[key].append(typed)
            CS["opt"][i] = len(OPTIONS[key]) - 1
            choice = typed
            CS["status"] = f'You typed "{typed}" into the field. It is now an option.'
        if key in MULTI:
            cur = set(CS["proposed"].get(i, active_set(i)))
            cur ^= {choice}
            if cur == active_set(i):
                CS["proposed"].pop(i, None)
            else:
                CS["proposed"][i] = cur
        elif choice == value:
            CS["proposed"].pop(i, None); CS["status"] = "Proposal withdrawn."
        else:
            CS["proposed"][i] = choice
        if i in CS["proposed"] and not CS["status"].startswith("You typed"):
            CS["status"] = "Recorded as a proposal. Nothing has changed yet."
    elif k == "a" and i in CS["proposed"]:
        prop = CS["proposed"][i]
        if key in MULTI:
            added = sorted(prop - active_set(i)); removed = sorted(active_set(i) - prop)
            parts = ([f"add {', '.join(added)}"] if added else []) + ([f"remove {', '.join(removed)}"] if removed else [])
            CS["prompt"] = f"Change {key}: {' and '.join(parts)}."
        else:
            CS["prompt"] = f'Change {key} from "{value}" to "{prop}".'
        CS["status"] = "Reply written into your prompt. Read it, then press Enter to accept."
    elif k == "n":
        CS["notes"].setdefault(i, []).append("note added from the UI")
        CS["status"] = "Note added. Notes have no force."
    elif k == "x":
        CS["proposed"].pop(i, None); CS["prompt"] = ""; CS["status"] = "Proposal cleared."
    elif k == "e":
        CS["status"] = "Asked the PM to re-read the agreement."


def view_contract(win, y, C, replanned):
    bind = {"code": (C_ICON["code"], C["done"], "Enforced by code"),
            "guide": (C_ICON["guide"], C["new"], "Written guidance only — no code checks it"),
            "unread": (C_ICON["unread"], C["drop"], "Nothing reads it")}
    RADIO_ON, RADIO_OFF, CARET_R, CARET_D = "\uf192", "\uf10c", "\uf460", "\uf47c"  # fa dot_circle_o, circle_o; oct chevron right/down

    def line(indent, text, icon="", iattr=0, tattr=0):
        nonlocal y
        x = indent
        if icon:
            x = put(win, y, x, icon + "  ", iattr)
        put(win, y, x, text, tattr)
        y += 1

    line(2, "Agreement", C_ICON["law"], C["item"], curses.A_BOLD)
    y += 1
    line(5, "PM last re-read the agreement at 09:10", C_ICON["history"], C["plan"])
    line(5, "1 term changed since then: autonomy", C_ICON["alert"], C["new"])
    if CONTRACT["readback"]:
        y += 1
        line(5, "After compaction, the PM restated the agreement:", C_ICON["eye"], C["new"])
        line(10, 'PM says   autonomy is "act and tell"')
        line(10, 'Record    autonomy is "ask first"')
        line(10, "These differ.", tattr=curses.A_BOLD)
    y += 1
    x = put(win, y, 2, "Terms  ", curses.A_BOLD); put(win, y, x, "─" * 40, curses.A_DIM); y += 2
    for i, (key, value, binds, cited, set_by, why) in enumerate(AGREEMENT):
        sel, is_open = i == CS["sel"], i in CS["open"]
        x = put(win, y, 2, "▌ " if sel else "  ", C["now"])
        x = put(win, y, x, (CARET_D if is_open else CARET_R) + "  ", curses.A_DIM)
        x = put(win, y, x, f"{key:<17}", curses.A_BOLD)
        x = put(win, y, x, f"{value:<28}")
        x = put(win, y, x, TERM_DESC[key], curses.A_DIM)
        if i in CS["proposed"]:
            x = put(win, y, x + 3, C_ICON["draft"] + "  ", C["drop"])
            pv = CS["proposed"][i]
            put(win, y, x, "proposed: " + (", ".join(sorted(pv)) if isinstance(pv, set) else pv), curses.A_DIM)
        y += 1
        if not is_open:
            continue
        y += 1
        icon, attr, label = bind[binds]
        line(9, label, icon, attr, curses.A_DIM)
        line(9, ("1 step relies on this" if cited == 1 else f"{cited} steps rely on this") if cited else "No step relies on this",
             C_ICON["law"], 0, curses.A_DIM)
        line(9, f"Set by {set_by}" + (f" — {why}" if why else ""), C_ICON["note"], 0, curses.A_DIM)
        for note in CS["notes"].get(i, []):
            line(9, f"Your note: {note}  (no force)", C_ICON["note"], 0, curses.A_DIM)
        y += 1
        multi = key in MULTI
        line(9, "Options" + ("  (choose any)" if multi else ""), tattr=curses.A_DIM)
        rows = option_rows(i)
        oc = CS["opt"].get(i, rows.index(value) if value in rows else 0)
        act = active_set(i)
        prop = CS["proposed"].get(i)
        for oi, o in enumerate(rows):
            x = put(win, y, 9, "› " if (sel and oi == oc) else "  ", C["now"])
            if o is None:
                x = put(win, y, x, PLUS + "  ", C["plan"])
                put(win, y, x, ADDABLE[key][0], curses.A_DIM)
                y += 1
                continue
            active = o in act
            if multi:
                chosen = o in (prop if prop is not None else act)
                proposed = prop is not None and (o in prop) != active
                mark = CHECK_ON if chosen else CHECK_OFF
            else:
                proposed = prop == o
                mark = RADIO_ON if active else RADIO_OFF
            x = put(win, y, x, mark + "  ", C["done"] if active else (C["drop"] if proposed else 0))
            x = put(win, y, x, f"{o:<26}", curses.A_BOLD if active else 0)
            x = put(win, y, x, f"{OPT_DESC.get(o, ''):<50}", curses.A_DIM)
            if proposed:
                put(win, y, x, "proposed", curses.A_BOLD)
            elif active:
                put(win, y, x, "active", curses.A_BOLD)
            y += 1
        if i in CS["proposed"]:
            y += 1
            impact = {
                "autonomy": "Would change 3 open tasks: Export owner history, Retry watcher, Linux browser check",
                "tools of record": "The PM would also check the added tools for work and evidence",
                "cadence": "The PM would check on work at the new interval",
                "remit": "The PM would adopt work found in the new scope",
                "stop rule": "Would change when the PM may stop",
            }[key]
            line(9, impact, C_ICON["draft"], C["drop"], curses.A_DIM)
        y += 1
    x = put(win, y, 2, "Instructions  ", curses.A_BOLD); put(win, y, x, "─" * 33, curses.A_DIM); y += 2
    for quote, applies, scope, cited in INSTRUCTIONS:
        line(4, f'"{quote}"', C_ICON["guide"], C["new"], curses.A_BOLD)
        where_txt = "the whole programme" if applies == "programme" else applies
        line(9, f"Applies to {where_txt}  ({scope}) · {cited} step relies on this", tattr=curses.A_DIM)
    y += 1
    if CS["status"]:
        line(2, CS["status"], C_ICON["eye"], C["plan"])
    if CS["prompt"]:
        y += 1
        put(win, y, 2, "╭" + "─" * 70, curses.A_DIM); y += 1
        x = put(win, y, 2, "│ > ", curses.A_DIM); put(win, y, x, CS["prompt"], curses.A_BOLD); y += 1
        put(win, y, 2, "╰" + "─" * 70 + "  your prompt — press Enter to accept", curses.A_DIM); y += 1
    y += 1
    put(win, y, 1, "Tab/↑↓ term · Enter/→ open · ←  close · ↑↓ option · Space propose · a accept (fills prompt) · "
                   "n note · x clear · e ask PM to re-read · b read-back", C["dim"])


def tag(win, y, x, word, attr):
    return put(win, y, x, f" {word} ", attr | curses.A_REVERSE) + 1


def view_tree(win, y, C, replanned):
    for si, s in enumerate(SESSIONS):
        plan = plan_of(s, replanned)
        x = put(win, y, 1, I["item"] + " ", C["item"])
        x = put(win, y, x, s["item"] + "   ", curses.A_BOLD)
        put(win, y, x, f"{I['pane']} {where(s)}", curses.A_DIM); y += 1
        rows = [("DONE", I["done"], d, C["done"]) for d in s["done"]]
        rows.append(("WAIT" if s["wait"] else "NOW", I["wait"] if s["wait"] else I["now"],
                     s["now"] + (f"  {I['pulse']} {s['wait']}" if s["wait"] else ""), C["now"]))
        for pi, p in enumerate(plan):
            n = is_new(s, p, replanned)
            rows.append(("NEW" if n else "TODO", I["new"] if n else I["plan"], p, (C["new"] if n else C["plan"]) if pi == 0 else 0))
        rows += [("DROP", I["drop"], d, 0) for d in dropped(s, replanned)]
        rows.append(("GOAL", I["goal"], s["finish"], 0))
        for ri, (word, icon, text, attr) in enumerate(rows):
            guide = "└─" if ri == len(rows) - 1 else "├─"
            x = put(win, y, 4, f"{guide} ", curses.A_DIM)
            x = tag(win, y, x, f"{word:<4}", attr)
            x = put(win, y, x, icon + " ", attr)
            put(win, y, x, text, curses.A_DIM if word == "DROP" else 0); y += 1
        if replanned:
            x = put(win, y, 7, I["sync"] + " ", C["new"])
            put(win, y, x, s["replan"]["why"]); y += 1
        y += 1


DRAW = {"1": view_statusline, "2": view_list, "3": view_tree, "4": view_contract}


def main(scr):
    curses.curs_set(0)
    curses.use_default_colors()
    C = dict.fromkeys(["head", "done", "now", "plan", "new", "drop", "goal", "pane", "item"], 0)
    C["dim"] = curses.A_DIM
    if curses.has_colors():
        for n, col in enumerate([curses.COLOR_GREEN, curses.COLOR_CYAN, curses.COLOR_YELLOW,
                                 curses.COLOR_BLUE, curses.COLOR_RED, curses.COLOR_MAGENTA], 1):
            curses.init_pair(n, col, -1)
        cp = curses.color_pair
        C.update(done=cp(1), now=cp(2), new=cp(3), plan=cp(4), drop=cp(5), goal=cp(6),
                 pane=cp(4), item=cp(2), dim=curses.A_DIM)
    curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
    print("\x1b[?1003h", end="", flush=True)  # hover reporting
    scr.keypad(True)
    view, replanned = "1", False
    while True:
        scr.erase()
        put(scr, 0, 1, f"Trajectory sketch {view}: {VIEWS[view]}" + ("   [plan changed]" if replanned else ""), curses.A_BOLD)
        put(scr, 1, 1, "1-4 switch view · r toggle a plan change · q quit · fake data, judge the shape", curses.A_DIM)
        DRAW[view](scr, 3, C, replanned)
        scr.refresh()
        k = scr.getkey()
        if k in DRAW:
            view = k
        elif k == "r" and view != "4":
            replanned = not replanned
        elif k == "b":
            CONTRACT["readback"] = not CONTRACT["readback"]
        elif k in ("q", "Q"):
            print("\x1b[?1003l", end="", flush=True)
            return
        elif view == "1" and k == "KEY_MOUSE":
            try:
                _, mx, my, _, bstate = curses.getmouse()
                band_mouse(my, mx, bool(bstate & (curses.BUTTON1_CLICKED | curses.BUTTON1_PRESSED)))
            except curses.error:
                pass
        elif view == "1":
            band_key(k, len(SESSIONS) * 2, replanned)
        elif view == "4":
            contract_key(k)


class PrintWin:
    """Renders the same views as plain ANSI text, for shells without a TTY."""
    def __init__(self, width):
        self.w, self.rows = width, {}

    def getmaxyx(self):
        return (60, self.w)

    def addnstr(self, y, x, text, n, attr=0):
        row = self.rows.setdefault(y, {})
        for i, ch in enumerate(text[:n]):
            row[x + i] = (ch, attr)

    def dump(self):
        out = []
        for y in range(max(self.rows) + 1 if self.rows else 0):
            row, line, cur = self.rows.get(y, {}), [], None
            for x in range(max(row) + 1 if row else 0):
                ch, attr = row.get(x, (" ", 0))
                if attr != cur:
                    line.append("\x1b[0m" + ansi(attr)); cur = attr
                line.append(ch)
            out.append("".join(line) + "\x1b[0m")
        return "\n".join(out)


ANSI_FG = {1: 32, 2: 36, 3: 33, 4: 34, 5: 31, 6: 35}


def ansi(attr):
    codes = []
    if attr & BOLD: codes.append("1")
    if attr & DIM: codes.append("2")
    if attr & REV: codes.append("7")
    pair = (attr >> 8) & 0xff
    if pair in ANSI_FG: codes.append(str(ANSI_FG[pair]))
    return f"\x1b[{';'.join(codes)}m" if codes else ""


BOLD, DIM, REV = 1 << 21, 1 << 20, 1 << 18


def print_all(width):
    curses.A_BOLD, curses.A_DIM, curses.A_REVERSE = BOLD, DIM, REV
    cp = lambda n: n << 8
    C = dict(head=BOLD, done=cp(1), now=cp(2), new=cp(3), plan=cp(4), drop=cp(5), goal=cp(6),
             pane=cp(4), item=cp(2), dim=DIM)
    frames = [
        ("Band · first task focused, current step open", "1", False, 0, {}),
        ("Band · Tab to the second task", "1", False, 1, {}),
        ("Band · second task, → once (next step open)", "1", False, 1, {1: 2}),
        ("Band · after a plan change, first task focused", "1", True, 0, {}),
        ("Side pane list (with the clause each step relies on)", "2", False, 0, {}),
        ("Contract · autonomy open, showing its options", "4", False, 0, {}),
        ("Contract · Space on \"act and tell\" (proposed), then a (reply written into your prompt)", "4", False, 0, {}),
        ("Contract · tools of record: tick Datadog, add Sentry, then a", "4", False, 0, {}),
    ]
    for name, key, replanned, focus, cursor in frames:
        BAND["focus"], BAND["cursor"] = focus, dict(cursor)
        CONTRACT["readback"] = False
        if key == "4":
            CS.update(sel=2, open={2}, opt={}, proposed={}, prompt="", status="")
            OPTIONS["tools of record"] = ["Linear", "GitHub", "Datadog", "Amplitude"]
            if "proposed" in name:
                for k in ("KEY_DOWN", " ", "a"):
                    contract_key(k)
            if "tools of record" in name:
                CS.update(sel=4, open={4})
                for k in ("KEY_DOWN", "KEY_DOWN", " ", "KEY_DOWN", "KEY_DOWN", " ", "a"):
                    contract_key(k)
        w = PrintWin(width)
        DRAW[key](w, 0, C, replanned)
        print(f"\x1b[1m── {name} ──\x1b[0m")
        print(w.dump()); print()


if __name__ == "__main__":
    import sys, shutil
    if "--print" in sys.argv or not sys.stdout.isatty():
        print_all(shutil.get_terminal_size((140, 40)).columns if sys.stdout.isatty() else 140)
    else:
        curses.wrapper(main)
