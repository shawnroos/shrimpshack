# Sourced by the U7 end/archive tests after dispatch-fixture.sh: typed prompts, a typed end,
# and a full inventory of a programme home (every path, type, mode, size, mtime and sha256).

HOOKS="${AUTO_ROOT}/.claude/hooks"

typed_in() {
  run_py "$1" "$2" "$3" "${4:-typed}" <<'EOF'
print(fixture_prompt(args[0], args[1], args[2], args[3])["prompt_id"])
EOF
}

# end_typed <run> [session]: Shawn types /auto:programme-end in the driving session, then end runs.
end_typed() {
  local sid="${2:-sess-pm}" pid
  pid="$(typed_in "$1" "$sid" "/auto:programme-end")"
  run_py "$1" "$sid" "$pid" <<'EOF' >/dev/null
pj.append(args[0], "end_request", args[1], {"verb": "end", "text": "/auto:programme-end", "origin": "typed",
                                            "driving": True, "lease_status": "live",
                                            "source": pj.find_prompt(args[0], args[2])["payload"]["source"]},
          cites=[args[2]])
EOF
  CLAUDE_CODE_SESSION_ID="$sid" prog end --run "$1"
}

home_of() { printf '%s/programmes/%s' "$CLAUDE_AUTO_DATA_DIR" "$1"; }

inventory() {
  "$PY" - "$(home_of "$1")" <<'EOF'
import hashlib, os, stat, sys
root = sys.argv[1]
rows = []
for base, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(dirs + files):
        path = os.path.join(base, name)
        st = os.lstat(path)
        kind = "d" if stat.S_ISDIR(st.st_mode) else "l" if stat.S_ISLNK(st.st_mode) else "f"
        digest = ""
        if kind == "f":
            with open(path, "rb") as fh:
                digest = hashlib.sha256(fh.read()).hexdigest()
        rows.append(f"{os.path.relpath(path, root)}|{kind}|{oct(st.st_mode & 0o7777)}|"
                    f"{st.st_size if kind == 'f' else ''}|{st.st_mtime_ns}|{digest}")
st = os.lstat(root)
rows.append(f".|d|{oct(st.st_mode & 0o7777)}||{st.st_mtime_ns}|")
print("\n".join(rows))
EOF
}

arch_field() {
  run_py "$1" "$2" <<'EOF'
run, expr = args
prog = record(run)["programme"]
closure = prog.get("closure") or {}
archive = prog.get("archive") or {}
v = eval(expr)
print(v if isinstance(v, str) else json.dumps(v, sort_keys=True))
EOF
}

# Runs the real hook with a transcript row that shows Shawn typed the prompt.
prompt_hook() {
  CLAUDE_PLUGIN_ROOT="$AUTO_ROOT" "$PY" "${AUTO_ROOT}/tests/fixtures/programme_prompts.py" "$AUTO_ROOT" "$1" "$2"
}
