#!/usr/bin/env bash
# The board configuration: which Linear field each herdr level groups by, and
# which tickets are on the board. Sourced, never executed. This file only reads;
# writing the configuration is U3's.
#
# WHY DEFAULT-DENY (KTD6)
# Every key, level kind and filter value is checked against a closed set, and a
# single fault anywhere -- one override included -- refuses the whole file. A
# validator that lets through what it does not recognise leaks one unenumerated
# case per review, and a board built from half a configuration moves panes and
# writes Linear on a mapping nobody wrote.
#
# WHY A BAD MODE IS NOT "ABSENT" (R7)
# The binding records read a wrong owner or mode as no record. Here that would
# mean "no mapping", which silently puts the plugin back on today's placement --
# the defaults R7 forbids continuing on. So every fault is a named refusal, and
# only a file that does not exist is absent.

HERDR_LINEAR_STORE_DIR="${HERDR_LINEAR_STORE_DIR:-$HOME/.claude/work}"
HERDR_LINEAR_BOARD_CONFIG_VERSION=1

HERDR_LINEAR_BOARD_OK=0
HERDR_LINEAR_BOARD_ABSENT=1      # no configuration file: no mapping, no warning
HERDR_LINEAR_BOARD_REFUSED=2     # the file exists and must not be used
HERDR_LINEAR_BOARD_USAGE=3       # the caller asked something malformed
HERDR_LINEAR_BOARD_NOT_LEVEL=4   # the field is valid but groups no level

HERDR_LINEAR_BOARD_FIELD_KINDS="team project milestone cycle assignee state priority parent"

herdr_linear::_board_config_path() {
    printf '%s/board.json' "$HERDR_LINEAR_STORE_DIR"
}

# One python3 pass does the stat, the parse, the validation and every answer, so
# no verb can reach a mapping without the whole file having been checked.
herdr_linear::_board_py() {
    HERDR_LINEAR_BOARD_CONFIG_VERSION="$HERDR_LINEAR_BOARD_CONFIG_VERSION" \
    HERDR_LINEAR_BOARD_FIELD_KINDS="$HERDR_LINEAR_BOARD_FIELD_KINDS" \
    HERDR_LINEAR_BOARD_OK="$HERDR_LINEAR_BOARD_OK" \
    HERDR_LINEAR_BOARD_ABSENT="$HERDR_LINEAR_BOARD_ABSENT" \
    HERDR_LINEAR_BOARD_REFUSED="$HERDR_LINEAR_BOARD_REFUSED" \
    HERDR_LINEAR_BOARD_USAGE="$HERDR_LINEAR_BOARD_USAGE" \
    HERDR_LINEAR_BOARD_NOT_LEVEL="$HERDR_LINEAR_BOARD_NOT_LEVEL" \
        python3 - "$@" <<'PYEOF'
import json, os, re, stat, sys

env = os.environ
VERSION = int(env["HERDR_LINEAR_BOARD_CONFIG_VERSION"])
FIELDS = env["HERDR_LINEAR_BOARD_FIELD_KINDS"].split()
OK, ABSENT, REFUSED, USAGE, NOT_LEVEL = (int(env[k]) for k in (
    "HERDR_LINEAR_BOARD_OK", "HERDR_LINEAR_BOARD_ABSENT", "HERDR_LINEAR_BOARD_REFUSED",
    "HERDR_LINEAR_BOARD_USAGE", "HERDR_LINEAR_BOARD_NOT_LEVEL"))

LEVELS = ("space", "tab", "column", "row")
STATE_TYPES = ("triage", "backlog", "unstarted", "started", "completed", "canceled")
# R32. Computed onto the resolved filter, never read from the file, so the file
# cannot switch the default off except by naming states.
DEFAULT_EXCLUDED = ["triage", "backlog"]
STRING_FILTER_KEYS = ("team", "project", "milestone", "cycle", "assignee", "state", "parent", "label")
FILTER_KEYS = STRING_FILTER_KEYS + ("state-type", "priority")
ALLOWED_KINDS = ("a single-valued field (%s), a label group (label-group:<name>), ticket, or sub-ticket"
                 % ", ".join(FIELDS))
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


class Refusal(Exception):
    pass


def shown(value):
    # A fault quotes text a person typed; an ESC or OSC title rewrite in it must
    # never reach the terminal raw.
    text = json.dumps(value, ensure_ascii=True)
    return text if len(text) <= 80 else text[:77] + "..."


def no_dupes(pairs):
    seen = set()
    for k, _ in pairs:
        if k in seen:
            raise Refusal("an object repeats the key %s; only one may be given" % shown(k))
        seen.add(k)
    return dict(pairs)


def no_constant(name):
    raise Refusal("the JSON holds %s, which is not a number" % name)


def text_ok(value):
    return isinstance(value, str) and value != "" and not CONTROL.search(value)


def check_keys(obj, allowed, where):
    for k in obj:
        if k not in allowed:
            raise Refusal("%s has unknown key %s; allowed: %s" % (where, shown(k), ", ".join(allowed)))


def check_kind(kind, where):
    if not isinstance(kind, str):
        raise Refusal("%s is %s, not a string; a level is %s" % (where, shown(kind), ALLOWED_KINDS))
    if kind in FIELDS or kind in ("ticket", "sub-ticket"):
        return
    if kind.startswith("label-group:"):
        if text_ok(kind[len("label-group:"):]):
            return
        raise Refusal("%s is %s, a label-group with no usable name; a level is %s"
                      % (where, shown(kind), ALLOWED_KINDS))
    raise Refusal("%s is %s, which is not a level kind; a level is %s" % (where, shown(kind), ALLOWED_KINDS))


def check_filter(flt, where):
    if not isinstance(flt, dict):
        raise Refusal("%s is not a JSON object" % where)
    if not flt:
        raise Refusal("%s names no keys; a board filter must select something" % where)
    for k, v in flt.items():
        if k not in FILTER_KEYS:
            raise Refusal("%s has unknown filter key %s; allowed: %s" % (where, shown(k), ", ".join(FILTER_KEYS)))
        at = "%s key %s" % (where, shown(k))
        values = v if isinstance(v, list) else [v]
        if isinstance(v, list) and not v:
            raise Refusal("%s is an empty list; leave the key out instead" % at)
        for item in values:
            if k == "priority":
                if isinstance(item, bool) or not isinstance(item, int) or not 0 <= item <= 4:
                    raise Refusal("%s holds %s; a priority is an integer from 0 to 4" % (at, shown(item)))
            elif isinstance(item, str) and item == "":
                raise Refusal("%s holds an empty string, which is refused rather than read as absent" % at)
            elif not text_ok(item):
                raise Refusal("%s holds %s; a value is a non-empty string without control characters"
                              % (at, shown(item)))
            elif k == "state-type" and item not in STATE_TYPES:
                raise Refusal("%s holds %s; a state type is one of %s" % (at, shown(item), ", ".join(STATE_TYPES)))


def check_mapping(m, where):
    if not isinstance(m, dict):
        raise Refusal("%s is not a JSON object" % where)
    check_keys(m, ("levels", "filter"), where)
    if "levels" not in m:
        raise Refusal("%s has no levels" % where)
    if "filter" not in m:
        raise Refusal("%s has no filter; a mapping must state which tickets are on the board" % where)
    levels = m["levels"]
    if not isinstance(levels, dict):
        raise Refusal("%s levels is not a JSON object" % where)
    if not levels:
        raise Refusal("%s levels names no level; a mapping needs at least one level" % where)
    seen = {}
    for name, kind in levels.items():
        if name not in LEVELS:
            raise Refusal("%s has unknown level %s; the levels are %s" % (where, shown(name), ", ".join(LEVELS)))
        check_kind(kind, "%s level %s" % (where, name))
        if kind in seen:
            raise Refusal("%s sets levels %s and %s to the same kind %s; levels must be distinct"
                          % (where, seen[kind], name, shown(kind)))
        seen[kind] = name
    check_filter(m["filter"], "%s filter" % where)


def load(path):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as e:
        raise Refusal("cannot be examined: %s" % e.strerror)
    if not stat.S_ISREG(st.st_mode):
        raise Refusal("is not a regular file; a symlink or directory is not followed")
    if st.st_uid != os.getuid():
        raise Refusal("is owned by uid %d, not by you (uid %d)" % (st.st_uid, os.getuid()))
    mode = stat.S_IMODE(st.st_mode)
    if mode & 0o020:
        raise Refusal("is writable by group (mode %o); run chmod 600 on it" % mode)
    if mode & 0o002:
        raise Refusal("is writable by other (mode %o); run chmod 600 on it" % mode)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        raise Refusal("cannot be read: %s" % (getattr(e, "strerror", None) or e.__class__.__name__))
    try:
        doc = json.loads(text, object_pairs_hook=no_dupes, parse_constant=no_constant)
    except ValueError as e:
        raise Refusal("is not valid JSON: %s" % e)
    if not isinstance(doc, dict):
        raise Refusal("is not a JSON object at the top level")
    check_keys(doc, ("version", "global", "spaces"), "the file")
    v = doc.get("version")
    if isinstance(v, bool) or not isinstance(v, int) or v < 1:
        raise Refusal("has version %s; a version is a positive integer" % shown(v))
    if v > VERSION:
        raise Refusal("has version %d, newer than this plugin reads (%d); update the plugin" % (v, VERSION))
    if "global" not in doc:
        raise Refusal("has no global mapping; a space mapping replaces the global one, so one must exist")
    check_mapping(doc["global"], "the global mapping")
    spaces = doc.get("spaces", {})
    if not isinstance(spaces, dict):
        raise Refusal("spaces is not a JSON object")
    for name, m in spaces.items():
        if not text_ok(name):
            raise Refusal("has space name %s; a space name is non-empty text without control characters"
                          % shown(name))
        check_mapping(m, "the mapping for space %s" % shown(name))
    doc.setdefault("spaces", {})
    return doc


def resolved(m, source):
    flt = dict(m["filter"])
    if "state" not in flt and "state-type" not in flt:
        flt["state-type-not"] = list(DEFAULT_EXCLUDED)
    return {"source": source, "levels": m["levels"], "filter": flt}


def level_matches(kind, field):
    if field in ("label", "labels"):
        return kind.startswith("label-group:")
    return kind == field


def main():
    verb, path = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    if verb == "level-of":
        field = args[0] if args else ""
        if not (field in FIELDS or field in ("ticket", "sub-ticket", "label", "labels")
                or (field.startswith("label-group:") and text_ok(field[len("label-group:"):]))):
            sys.stderr.write("field %s is not a Linear field a board level can use; allowed: %s, or label for any label group\n"
                             % (shown(field), ALLOWED_KINDS))
            return USAGE
    if (verb == "mapping-for" and not (args and text_ok(args[0]))) \
            or (verb == "level-of" and len(args) > 1 and not text_ok(args[1])):
        sys.stderr.write("a space name is required to resolve a mapping; got %s\n" % shown(args[-1] if args else ""))
        return USAGE
    try:
        doc = load(path)
    except Refusal as r:
        sys.stderr.write("board configuration %s %s; it was not used and no default mapping was applied\n"
                         % (json.dumps(path, ensure_ascii=True)[1:-1], r))
        return REFUSED
    if doc is None:
        return ABSENT

    if verb == "load":
        out = {"version": doc["version"], "global": resolved(doc["global"], "global"),
               "spaces": {n: resolved(m, "space") for n, m in doc["spaces"].items()}}
        print(json.dumps(out))
        return OK
    if verb == "mapping-for":
        name = args[0]
        if name in doc["spaces"]:
            print(json.dumps(resolved(doc["spaces"][name], "space")))
        else:
            print(json.dumps(resolved(doc["global"], "global")))
        return OK
    if verb == "level-of":
        field = args[0]
        if len(args) > 1:
            name = args[1]
            if name in doc["spaces"]:
                candidates = [("space", name, doc["spaces"][name])]
            else:
                candidates = [("global", None, doc["global"])]
        else:
            candidates = [("global", None, doc["global"])] + [("space", n, m) for n, m in doc["spaces"].items()]
        hits = [{"mapping": src, "space": name, "level": level}
                for src, name, m in candidates
                for level in LEVELS
                if level in m["levels"] and level_matches(m["levels"][level], field)]
        if not hits:
            return NOT_LEVEL
        print(json.dumps(hits))
        return OK
    return USAGE


sys.exit(main())
PYEOF
}

# herdr_linear::board_config_load
# Prints the validated configuration with each filter resolved, or returns ABSENT
# (no file, silent) or REFUSED (named on stderr).
herdr_linear::board_config_load() {
    herdr_linear::_board_py load "$(herdr_linear::_board_config_path)"
}

# herdr_linear::board_mapping_for <space-name>
# Prints {source, levels, filter} for the space's own mapping, or the global one
# when the space declares none (R5).
herdr_linear::board_mapping_for() {
    herdr_linear::_board_py mapping-for "$(herdr_linear::_board_config_path)" "${1-}"
}

# herdr_linear::board_level_of <field> [space-name]
# OK with a JSON list of where the field sits when it groups a level; NOT_LEVEL
# when it groups none. Without a space name every mapping counts, which is what
# an agent needs to know whether its Linear write can move a pane anywhere.
herdr_linear::board_level_of() {
    if [ "$#" -ge 2 ]; then
        herdr_linear::_board_py level-of "$(herdr_linear::_board_config_path)" "${1-}" "$2"
    else
        herdr_linear::_board_py level-of "$(herdr_linear::_board_config_path)" "${1-}"
    fi
}
