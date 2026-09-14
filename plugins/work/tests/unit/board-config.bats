#!/usr/bin/env bats

load setup_common

# U2. The board configuration is read once, validated whole, and refused loudly
# when wrong. Every refusal asserts the exact status, an empty stdout, the file
# path and the fault: a refusal that printed a usable mapping, or a 127 from an
# undefined function, would otherwise pass a bare non-zero check.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    # shellcheck source=/dev/null
    . "$ROOT/lib/board-config.sh"
    mkdir -p "$HERDR_LINEAR_STORE_DIR"
    CFG="$HERDR_LINEAR_STORE_DIR/board.json"
}

write_cfg() {
    printf '%s\n' "$1" >"$CFG"
    chmod 600 "$CFG"
}

GOOD='{
  "version": 1,
  "global": {
    "levels": {"space": "team", "tab": "assignee", "column": "state", "row": "label-group:Area"},
    "filter": {"team": ["acme-web", "acme-api"]}
  },
  "spaces": {
    "Mine": {
      "levels": {"space": "assignee", "tab": "project"},
      "filter": {"assignee": "me", "state-type": ["backlog", "started"]}
    }
  }
}'

refused() {
    [ "$status" -eq "$HERDR_LINEAR_BOARD_REFUSED" ]
    [ -z "$output" ]
    [[ "$stderr" == *"$CFG"* ]]
}

# ------------------------------------------------------------------ the file

@test "an absent file yields no mapping and no warning" {
    run --separate-stderr herdr_linear::board_config_load
    [ "$status" -eq "$HERDR_LINEAR_BOARD_ABSENT" ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "an absent file resolves no mapping for any space and names no level" {
    run --separate-stderr herdr_linear::board_mapping_for Mine
    [ "$status" -eq "$HERDR_LINEAR_BOARD_ABSENT" ]
    [ -z "$stderr" ]
    run --separate-stderr herdr_linear::board_level_of team
    [ "$status" -eq "$HERDR_LINEAR_BOARD_ABSENT" ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "a valid file loads and prints the whole configuration" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_config_load
    [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ]
    [ -z "$stderr" ]
    printf '%s' "$output" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d["version"] == 1
assert d["global"]["levels"]["row"] == "label-group:Area"
assert "Mine" in d["spaces"]'
}

# AE10. Covers R7.
@test "a file writable by group is refused, naming the file and the mode fault" {
    write_cfg "$GOOD"
    chmod 660 "$CFG"
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"writable by group"* ]]
    [[ "$stderr" == *"660"* ]]
}

@test "a file writable by other is refused, naming the mode fault" {
    write_cfg "$GOOD"
    chmod 606 "$CFG"
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"writable by other"* ]]
}

@test "a refused mode refuses the resolver and the level read too, not only load" {
    write_cfg "$GOOD"
    chmod 660 "$CFG"
    run --separate-stderr herdr_linear::board_mapping_for Mine
    refused
    run --separate-stderr herdr_linear::board_level_of team
    refused
}

@test "a symlink in place of the file is refused rather than followed" {
    printf '%s\n' "$GOOD" >"$BATS_TEST_TMPDIR/elsewhere.json"
    chmod 600 "$BATS_TEST_TMPDIR/elsewhere.json"
    ln -s "$BATS_TEST_TMPDIR/elsewhere.json" "$CFG"
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"not a regular file"* ]]
}

@test "a malformed JSON file is refused with the parse fault and no defaults" {
    write_cfg '{"version": 1, "global": {'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"not valid JSON"* ]]
    run --separate-stderr herdr_linear::board_mapping_for anything
    refused
}

@test "a top level that is not an object is refused" {
    write_cfg '[1, 2]'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"not a JSON object"* ]]
}

@test "a key repeated in one object is refused rather than keeping the last" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "team", "tab": "project"}, "filter": {"team": "acme"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"repeats the key"* ]]
    [[ "$stderr" == *"tab"* ]]
}

# ---------------------------------------------------------------- top level

@test "an unknown top-level key is refused" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "team"}, "filter": {"team": "acme"}}, "theme": "dark"}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *'unknown key "theme"'* ]]
}

@test "a version above the code's is refused" {
    write_cfg "{\"version\": $((HERDR_LINEAR_BOARD_CONFIG_VERSION + 1)), \"global\": {\"levels\": {\"tab\": \"team\"}, \"filter\": {\"team\": \"acme\"}}}"
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"version $((HERDR_LINEAR_BOARD_CONFIG_VERSION + 1))"* ]]
    [[ "$stderr" == *"newer"* ]]
}

@test "a missing, boolean or string version is refused" {
    local v
    for v in '' '"version": true, ' '"version": "1", ' '"version": 0, '; do
        write_cfg "{${v}\"global\": {\"levels\": {\"tab\": \"team\"}, \"filter\": {\"team\": \"acme\"}}}"
        run --separate-stderr herdr_linear::board_config_load
        refused
        [[ "$stderr" == *"version"* ]]
    done
}

@test "a file with no global mapping is refused" {
    write_cfg '{"version": 1, "spaces": {"Mine": {"levels": {"tab": "team"}, "filter": {"team": "acme"}}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"global"* ]]
}

# ------------------------------------------------------------------- levels

# AE1. Covers R2.
@test "a level of labels in general is refused, naming the allowed kinds" {
    write_cfg '{"version": 1, "global": {"levels": {"space": "team", "tab": "labels"}, "filter": {"team": "acme"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *'"labels"'* ]]
    [[ "$stderr" == *"single-valued field"* ]]
    [[ "$stderr" == *"label-group:<name>"* ]]
    [[ "$stderr" == *", ticket, or sub-ticket"* ]]
    [[ "$stderr" == *"assignee"* ]]
}

@test "every kind in the closed enum is accepted as a level" {
    local kind
    for kind in $HERDR_LINEAR_BOARD_FIELD_KINDS ticket sub-ticket label-group:Area; do
        write_cfg "{\"version\": 1, \"global\": {\"levels\": {\"tab\": \"$kind\"}, \"filter\": {\"team\": \"acme\"}}}"
        run --separate-stderr herdr_linear::board_config_load
        [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ] || { printf 'kind %s refused: %s\n' "$kind" "$stderr" >&2; return 1; }
    done
}

@test "a label group with no name is refused" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "label-group:"}, "filter": {"team": "acme"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"label-group"* ]]
}

@test "a level name outside space, tab, column and row is refused" {
    write_cfg '{"version": 1, "global": {"levels": {"pane": "team"}, "filter": {"team": "acme"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *'unknown level "pane"'* ]]
    [[ "$stderr" == *"space, tab, column, row"* ]]
}

@test "a mapping with no levels is refused" {
    write_cfg '{"version": 1, "global": {"levels": {}, "filter": {"team": "acme"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"at least one level"* ]]
}

@test "a level set to something other than a string is refused" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": ["team"]}, "filter": {"team": "acme"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"tab"* ]]
}

# Covers R3.
@test "two levels with the same kind are refused" {
    write_cfg '{"version": 1, "global": {"levels": {"space": "team", "column": "team"}, "filter": {"team": "acme"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"same kind"* ]]
    [[ "$stderr" == *'"team"'* ]]
}

@test "two different label groups are distinct levels" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "label-group:Area", "column": "label-group:Size"}, "filter": {"team": "acme"}}}'
    run --separate-stderr herdr_linear::board_config_load
    [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ]
}

# ------------------------------------------------------------------ filters

@test "a mapping with no filter is refused" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "team"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"filter"* ]]
}

@test "a filter key outside the known set is refused" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "team"}, "filter": {"estimate": "3"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *'unknown filter key "estimate"'* ]]
}

@test "an empty string filter value is refused, not treated as absent" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "team"}, "filter": {"assignee": ""}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"assignee"* ]]
    [[ "$stderr" == *"refused rather than read as absent"* ]]
}

@test "an empty string inside a filter list and an empty list are refused" {
    local value
    for value in '["acme", ""]' '[]' 'null' '3'; do
        write_cfg "{\"version\": 1, \"global\": {\"levels\": {\"tab\": \"team\"}, \"filter\": {\"team\": $value}}}"
        run --separate-stderr herdr_linear::board_config_load
        refused
        [[ "$stderr" == *"team"* ]]
    done
}

@test "a state type outside Linear's set is refused, naming the set" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "team"}, "filter": {"state-type": "doing"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *'"doing"'* ]]
    [[ "$stderr" == *"triage, backlog, unstarted, started, completed, canceled"* ]]
}

@test "a priority outside 0 to 4 is refused" {
    local value
    for value in '5' 'true' '"high"'; do
        write_cfg "{\"version\": 1, \"global\": {\"levels\": {\"tab\": \"team\"}, \"filter\": {\"priority\": $value}}}"
        run --separate-stderr herdr_linear::board_config_load
        refused
        [[ "$stderr" == *"priority"* ]]
    done
}

@test "a control character in a value is refused and never echoed raw" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "team"}, "filter": {"team": "acme\u001b]2;owned\u0007"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" != *$'\033'* ]]
    [[ "$stderr" != *$'\a'* ]]
}

# Covers AE12, R32.
@test "a filter with no states excludes triage and backlog" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_mapping_for acme-web
    [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ]
    printf '%s' "$output" | python3 -c '
import sys, json
f = json.load(sys.stdin)["filter"]
assert sorted(f["state-type-not"]) == ["backlog", "triage"], f
assert "state-type" not in f, f'
}

@test "a filter naming backlog includes it and adds no exclusion" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_mapping_for Mine
    [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ]
    printf '%s' "$output" | python3 -c '
import sys, json
f = json.load(sys.stdin)["filter"]
assert "state-type-not" not in f, f
assert "backlog" in f["state-type"], f'
}

@test "a filter naming a state by name adds no exclusion" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "team"}, "filter": {"state": "Triage"}}}'
    run --separate-stderr herdr_linear::board_mapping_for any
    [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ]
    printf '%s' "$output" | python3 -c '
import sys, json
f = json.load(sys.stdin)["filter"]
assert "state-type-not" not in f, f'
}

@test "the computed exclusion cannot be written into the file" {
    write_cfg '{"version": 1, "global": {"levels": {"tab": "team"}, "filter": {"state-type-not": ["canceled"]}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *'unknown filter key "state-type-not"'* ]]
}

# ------------------------------------------------------------- per space (R5)

@test "an invalid per-space mapping refuses the whole file, not only that space" {
    write_cfg '{"version": 1,
      "global": {"levels": {"tab": "team"}, "filter": {"team": "acme"}},
      "spaces": {"Broken": {"levels": {"tab": "labels"}, "filter": {"team": "acme"}}}}'
    run --separate-stderr herdr_linear::board_mapping_for acme-web
    refused
    [[ "$stderr" == *"Broken"* ]]
    run --separate-stderr herdr_linear::board_config_load
    refused
}

@test "an unknown key inside a space mapping is refused" {
    write_cfg '{"version": 1,
      "global": {"levels": {"tab": "team"}, "filter": {"team": "acme"}},
      "spaces": {"Mine": {"levels": {"tab": "team"}, "filter": {"team": "acme"}, "color": "red"}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *'unknown key "color"'* ]]
}

@test "an empty space name is refused" {
    write_cfg '{"version": 1,
      "global": {"levels": {"tab": "team"}, "filter": {"team": "acme"}},
      "spaces": {"": {"levels": {"tab": "team"}, "filter": {"team": "acme"}}}}'
    run --separate-stderr herdr_linear::board_config_load
    refused
    [[ "$stderr" == *"space name"* ]]
}

@test "a space name with its own mapping resolves to it" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_mapping_for Mine
    [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ]
    printf '%s' "$output" | python3 -c '
import sys, json
m = json.load(sys.stdin)
assert m["source"] == "space", m
assert m["levels"] == {"space": "assignee", "tab": "project"}, m'
}

@test "an unknown space name resolves to the global mapping" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_mapping_for acme-web
    [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ]
    printf '%s' "$output" | python3 -c '
import sys, json
m = json.load(sys.stdin)
assert m["source"] == "global", m
assert m["levels"]["tab"] == "assignee", m'
}

@test "the resolver refuses a missing space name rather than guessing one" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_mapping_for ""
    [ "$status" -eq "$HERDR_LINEAR_BOARD_USAGE" ]
    [ -z "$output" ]
    [[ "$stderr" == *"space name"* ]]
}

# ------------------------------------------------- is this field a board level

@test "a field that is a level in any mapping is reported with where it sits" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_level_of project
    [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ]
    printf '%s' "$output" | python3 -c '
import sys, json
hits = json.load(sys.stdin)
assert hits == [{"mapping": "space", "space": "Mine", "level": "tab"}], hits'
}

@test "a field that is no level anywhere reports not a level" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_level_of cycle
    [ "$status" -eq "$HERDR_LINEAR_BOARD_NOT_LEVEL" ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "a field asked about one space is answered from that space's mapping only" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_level_of team Mine
    [ "$status" -eq "$HERDR_LINEAR_BOARD_NOT_LEVEL" ]
    run --separate-stderr herdr_linear::board_level_of team acme-web
    [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ]
    printf '%s' "$output" | python3 -c '
import sys, json
hits = json.load(sys.stdin)
assert hits == [{"mapping": "global", "space": None, "level": "space"}], hits'
}

@test "a level read for an empty space name is a usage refusal, as the resolver's is" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_level_of team ""
    [ "$status" -eq "$HERDR_LINEAR_BOARD_USAGE" ]
    [ -z "$output" ]
    [[ "$stderr" == *"space name"* ]]
}

@test "labels in general matches any label-group level, since a label edit can move one" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_level_of labels
    [ "$status" -eq "$HERDR_LINEAR_BOARD_OK" ]
    [[ "$output" == *'"row"'* ]]
}

@test "an unknown field name is a usage refusal naming the allowed fields" {
    write_cfg "$GOOD"
    run --separate-stderr herdr_linear::board_level_of estimate
    [ "$status" -eq "$HERDR_LINEAR_BOARD_USAGE" ]
    [ -z "$output" ]
    [[ "$stderr" == *"assignee"* ]]
    [[ "$stderr" == *"label-group:<name>"* ]]
}
