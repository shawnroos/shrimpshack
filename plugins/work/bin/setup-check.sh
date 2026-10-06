#!/usr/bin/env bash
# Report every prerequisite of the work plugin as one JSON object, keyed by
# check name:
#
#   {"<check>": {"state": "ok|missing|old|unknown|needs_import",
#                "detail": "...", "fix": "..." | null,
#                "fix_kind": "command" | "instruction" | null}}
#
# A `command` fix is the exact shell command that repairs the check; an
# `instruction` is something the person does by hand. The script itself only
# reads: it changes no file and starts nothing, and it always exits 0, so a
# caller decides from the JSON alone.
#
# Two probes would start the board daemon (the import dry run and the key check
# through the board), so they run only when the daemon already answers.

set -u

BOARD_BIN="${HERDR_LINEAR_BOARD_BIN:-board}"
HERDR_EXE="${HERDR_BIN:-herdr}"
SECURITY_BIN="${HERDR_LINEAR_SECURITY_BIN:-/usr/bin/security}"
CLAUDE_BIN="${HERDR_LINEAR_CLAUDE_BIN:-claude}"
GIT_BIN="${HERDR_LINEAR_GIT_BIN:-git}"
CARGO_BIN="${HERDR_LINEAR_CARGO_BIN:-cargo}"
KEYCHAIN_SERVICE="${HERDR_LINEAR_KEYCHAIN_SERVICE:-work-linear}"
KEYCHAIN_ACCOUNT="${HERDR_LINEAR_KEYCHAIN_ACCOUNT:-linear-api-key}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# Builtins only up to the python3 check: with python3 absent, the fallback
# below must still print, and PATH may hold nothing else either.
case "${BASH_SOURCE[0]}" in
    */*) here="${BASH_SOURCE[0]%/*}" ;;
    *) here=. ;;
esac
PLUGIN_ROOT="$(cd "$here/.." && pwd -P)"

if ! command -v python3 >/dev/null 2>&1; then
    printf '{"python3": {"state": "missing", "detail": "python3 is not on PATH, and the plugin needs it.", "fix": "Install python3, for example with: xcode-select --install", "fix_kind": "instruction"}'
    for k in git cargo herdr path board daemon herdr_plugin board_mcp duplicate_hook import linear_key in_herdr space_binding worktree_binding; do
        printf ', "%s": {"state": "unknown", "detail": "python3 is needed to check this.", "fix": null, "fix_kind": null}' "$k"
    done
    printf '}\n'
    exit 0
fi

SC_BOARD="$BOARD_BIN" SC_HERDR="$HERDR_EXE" SC_SECURITY="$SECURITY_BIN" \
SC_CLAUDE="$CLAUDE_BIN" SC_GIT="$GIT_BIN" SC_CARGO="$CARGO_BIN" \
SC_SERVICE="$KEYCHAIN_SERVICE" SC_ACCOUNT="$KEYCHAIN_ACCOUNT" \
SC_PROJECT="$PROJECT_DIR" SC_PLUGIN="$PLUGIN_ROOT" \
python3 -c '
import json, os, re, shutil, signal, subprocess

E = os.environ
HOME = E.get("HOME", "")
PLUGIN = E["SC_PLUGIN"]

# A local read answers in well under a second; these bound a wedged process.
# `claude mcp get` and the board key check reach the network, so they get longer.
LOCAL_TIMEOUT = 10
NETWORK_TIMEOUT = 30

TAG = "v0.18.0"
MIN_BOARD = (0, 18, 0)
INSTALL = "herdr plugin install shawnroos/herdr-linear-board --ref " + TAG + " --yes"
STORE = "bash " + os.path.join(PLUGIN, "bin", "migrate-credential.sh") + " store"
CUTOVER = os.path.join(PLUGIN, "docs", "cutover.md")
OPEN_BOARD = "herdr plugin action invoke open-board --plugin herdr-board"


def entry(state, detail, fix=None, kind=None):
    return {"state": state, "detail": detail, "fix": fix,
            "fix_kind": kind if fix is not None else None}


def which(name):
    if os.sep in name:
        return name if os.path.isfile(name) and os.access(name, os.X_OK) else None
    return shutil.which(name)


# The whole process group is killed on timeout: `claude mcp get` starts the
# server it checks, and a surviving grandchild holding the pipe would keep the
# final read waiting for an end of file that never comes.
def run(argv, timeout=LOCAL_TIMEOUT):
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    except OSError:
        return "error", ""
    try:
        stdout, _ = p.communicate(timeout=timeout)
        return p.returncode, stdout
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        return "timeout", ""


def run_json(argv, timeout=LOCAL_TIMEOUT):
    rc, out = run(argv, timeout)
    if rc != 0:
        return None
    try:
        d = json.loads(out)
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def version_tuple(text):
    m = re.match(r"(\d+)\.(\d+)\.(\d+)", str(text or ""))
    return tuple(int(x) for x in m.groups()) if m else None


out = {}

git = which(E["SC_GIT"])
out["git"] = entry("ok", "git is at " + git) if git else entry(
    "missing", "git is not on PATH. The board install clones its repository with it.",
    "Install git, for example with: xcode-select --install", "instruction")

cargo = which(E["SC_CARGO"])
if not cargo:
    fallback = os.path.join(HOME, ".cargo", "bin", "cargo")
    cargo = fallback if os.path.isfile(fallback) and os.access(fallback, os.X_OK) else None
out["cargo"] = entry("ok", "cargo is at " + cargo) if cargo else entry(
    "missing", "cargo is not installed. There is no prebuilt board for macOS, so it is built from source.",
    "Install the Rust toolchain from https://rustup.rs, then run setup again.", "instruction")

out["python3"] = entry("ok", "python3 is on PATH.")

herdr = which(E["SC_HERDR"])
if not herdr:
    out["herdr"] = entry("missing", "herdr is not installed.",
                         "Install herdr 0.9.x, then run setup again.", "instruction")
else:
    rc, text = run([herdr, "--version"])
    m = re.match(r"herdr (\S+)", text.strip()) if rc == 0 else None
    if not m:
        out["herdr"] = entry("unknown", "herdr --version did not answer.")
    elif not re.match(r"^0\.9\.\d+(-preview\..*)?$", m.group(1)):
        out["herdr"] = entry("old", "herdr " + m.group(1) + " is installed; the board needs herdr 0.9.x on protocol 22.",
                             "Install herdr 0.9.x, then run setup again.", "instruction")
    else:
        schema = run_json([herdr, "api", "schema", "--json"])
        protocol = schema.get("protocol") if schema else None
        if protocol is None:
            out["herdr"] = entry("unknown", "herdr " + m.group(1) + " is installed, but herdr api schema --json did not report a protocol.")
        elif protocol != 22:
            out["herdr"] = entry("old", "herdr " + m.group(1) + " speaks protocol " + str(protocol) + "; the board needs protocol 22.",
                                 "Install a herdr 0.9.x release on protocol 22, then run setup again.", "instruction")
        else:
            out["herdr"] = entry("ok", "herdr " + m.group(1) + " on protocol 22.")
herdr_ok = out["herdr"]["state"] == "ok"

local_bin = os.path.join(HOME, ".local", "bin")
on_path = local_bin in E.get("PATH", "").split(os.pathsep)
out["path"] = entry("ok", local_bin + " is on PATH.") if on_path else entry(
    "missing", local_bin + " is not on PATH, and the board is installed there.",
    "Add this line to your shell profile, then open a new shell: export PATH=\"$HOME/.local/bin:$PATH\"",
    "instruction")

# The board CLI and who owns it. install-cli.sh refuses to replace a board it
# did not install, a symlink included, so the fix depends on the owner.
local_board = os.path.join(local_bin, "board")
board = which(E["SC_BOARD"])
if not board and os.path.lexists(local_board):
    board = local_board
managed = bool(board) and os.path.abspath(board) == os.path.abspath(local_board) \
    and not os.path.islink(board) and os.path.isfile(os.path.join(local_bin, ".herdr-board-cli-managed"))
checkout = None
if board and os.path.islink(board):
    d = os.path.dirname(os.path.realpath(board))
    while True:
        if os.path.isfile(os.path.join(d, "herdr-plugin.toml")):
            checkout = d
            break
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
install_ready = herdr_ok and bool(git) and bool(cargo)
not_ready = "Fix " + ", ".join(k for k in ("git", "cargo", "herdr") if out[k]["state"] != "ok") + " first; the install needs them."
move_aside = ("Move " + str(board) + " aside (for example: mv " + str(board) + " " + str(board) + ".old), "
              "then run setup again to install the board.")

versions = run_json([board, "version", "--json"]) if board else None
cli_version = versions.get("cli_version") if versions else None
daemon_version = versions.get("daemon_version") if versions else None
cli_tuple = version_tuple(cli_version)

if not board:
    out["board"] = entry("missing", "board is not installed." + ("" if install_ready else " " + not_ready),
                         INSTALL if install_ready else None, "command")
elif cli_tuple is not None and cli_tuple >= MIN_BOARD:
    out["board"] = entry("ok", "board " + cli_version + " at " + board + ".")
else:
    found = "board " + cli_version if cli_version else "a board whose version --json did not answer"
    detail = found + " is at " + board + "; setup needs 0.18.0 or newer."
    if managed:
        out["board"] = entry("old", detail + ("" if install_ready else " " + not_ready),
                             INSTALL if install_ready else None, "command")
    elif checkout:
        rebuild = ("git -C " + checkout + " fetch --tags && git -C " + checkout + " checkout " + TAG
                   + " && cargo build --release -p board-cli --manifest-path " + os.path.join(checkout, "Cargo.toml"))
        ok = bool(git) and bool(cargo)
        out["board"] = entry("old", detail + " It is a symlink into the checkout " + checkout
                             + "; rebuild it at " + TAG + ", or move it aside and take the plugin install instead.",
                             rebuild if ok else None, "command")
    else:
        out["board"] = entry("old", detail + " Setup never overwrites a board it did not install.",
                             move_aside, "instruction")
board_ok = out["board"]["state"] == "ok"

if not board:
    out["daemon"] = entry("missing", "There is no board, so there is no daemon. Install the board first.")
elif not board_ok:
    out["daemon"] = entry("unknown", "Upgrade the board first.")
elif not daemon_version:
    out["daemon"] = entry("missing", "The board daemon is not running.", "board daemon status", "command")
elif daemon_version != cli_version:
    out["daemon"] = entry("old", "The daemon runs " + str(daemon_version) + " and the CLI is " + cli_version + ".",
                          "board daemon stop && board daemon status", "command")
else:
    out["daemon"] = entry("ok", "The daemon runs " + daemon_version + ".")
daemon_ok = out["daemon"]["state"] == "ok"
daemon_first = "start the daemon first."

if not herdr:
    out["herdr_plugin"] = entry("unknown", "herdr is not installed.")
else:
    listing = run_json([herdr, "plugin", "list", "--json"])
    plugins = (listing.get("result") or {}).get("plugins") if listing else None
    if not isinstance(plugins, list):
        out["herdr_plugin"] = entry("unknown", "herdr plugin list --json did not answer.")
    else:
        mine = [p for p in plugins if isinstance(p, dict) and p.get("plugin_id") == "herdr-board"]
        if mine:
            out["herdr_plugin"] = entry("ok", "herdr-board is registered from " + str(mine[0].get("plugin_root")) + ".")
        elif not herdr_ok:
            out["herdr_plugin"] = entry("missing", "herdr-board is not registered in herdr. Fix herdr first.")
        elif not board_ok:
            out["herdr_plugin"] = entry("missing", "herdr-board is not registered in herdr. Fixing the board entry registers it, or makes the link possible.")
        elif managed:
            out["herdr_plugin"] = entry("missing", "herdr-board is not registered in herdr." + ("" if install_ready else " " + not_ready),
                                        INSTALL if install_ready else None, "command")
        elif checkout:
            out["herdr_plugin"] = entry("missing", "herdr-board is not registered in herdr. The board is built in " + checkout + ", so that checkout is linked as the plugin.",
                                        "herdr plugin link " + checkout, "command")
        else:
            out["herdr_plugin"] = entry("missing", "herdr-board is not registered in herdr, and the board at " + board + " was not installed by the plugin.",
                                        move_aside, "instruction")

claude = which(E["SC_CLAUDE"])
if not claude:
    out["board_mcp"] = entry("unknown", "The claude CLI is not on PATH.")
else:
    rc, _ = run([claude, "mcp", "get", "board"], NETWORK_TIMEOUT)
    if rc == 0:
        out["board_mcp"] = entry("ok", "board mcp is registered with Claude Code.")
    elif rc in ("timeout", "error"):
        out["board_mcp"] = entry("unknown", "claude mcp get board did not answer.")
    else:
        out["board_mcp"] = entry("missing", "board mcp is not registered with Claude Code. A session started after adding it sees its tools.",
                                 "claude mcp add --scope user board -- board mcp", "command")

hook_files = [os.path.join(HOME, ".claude", "settings.json"), os.path.join(HOME, ".claude", "settings.local.json"),
              os.path.join(E["SC_PROJECT"], ".claude", "settings.json"),
              os.path.join(E["SC_PROJECT"], ".claude", "settings.local.json")]
dupes = []
for f in hook_files:
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            if "board linear report" in fh.read():
                dupes.append(f)
    except OSError:
        pass
out["duplicate_hook"] = entry("ok", "No settings file runs its own board linear report hook.") if not dupes else entry(
    "missing", "A settings file runs its own board linear report hook, so every Linear write is reported twice.",
    "Remove the board linear report hook from " + ", ".join(dupes) + ". The plugin already runs one.", "instruction")

pane = E.get("HERDR_PANE_ID", "")
space = E.get("HERDR_WORKSPACE_ID", "")
in_herdr = bool(pane and space)
out["in_herdr"] = entry("ok", "This session runs in herdr pane " + pane + ".") if in_herdr else entry(
    "missing", "This session is not in a herdr pane, so the two binding steps cannot run here.",
    "Open Claude Code in a herdr pane and run setup again to finish the bindings.", "instruction")

if not daemon_ok:
    out["import"] = entry("unknown", "Cannot read the import state: " + daemon_first)
else:
    d = run_json([board, "import", "work-store", "--dry-run", "--json"], NETWORK_TIMEOUT)
    if d is None:
        out["import"] = entry("unknown", "board import work-store --dry-run --json did not answer.")
    elif not d.get("present"):
        out["import"] = entry("ok", "There is no old work store to import.")
    else:
        pending = len(d.get("imported") or [])
        landed = [s for s in (d.get("skipped") or []) if "already in the board" in str((s or {}).get("reason", ""))]
        if landed:
            out["import"] = entry("ok", "The old work store is imported. " + str(pending) + " old-store rows would still import; "
                                  "that is expected after " + CUTOVER + " steps 8 and 9, which unbind them, so do not import again.")
        elif pending:
            out["import"] = entry("needs_import", "An old work store at " + str(d.get("store_dir")) + " has " + str(pending)
                                  + " rows the board does not hold. Cut over with " + CUTOVER + " instead of setting up fresh.",
                                  "Follow " + CUTOVER + " to import the old store, then run setup again.", "instruction")
        else:
            out["import"] = entry("ok", "The old work store holds nothing to import.")

# The board decides: it also reads LINEAR_API_KEY and ~/.secrets, so a key it
# accepts is working even with no Keychain item. The Keychain is only advice.
rc, _ = run([E["SC_SECURITY"], "find-generic-password", "-a", E["SC_ACCOUNT"], "-s", E["SC_SERVICE"]])
in_keychain = rc == 0
if not daemon_ok:
    out["linear_key"] = entry("unknown", "To check that the board accepts a Linear key, " + daemon_first)
else:
    d = run_json([board, "linear", "project", "list", "--json"], NETWORK_TIMEOUT)
    if d is None:
        out["linear_key"] = entry("unknown", "board linear project list --json did not answer.")
    elif d.get("status") == "unavailable":
        out["linear_key"] = entry("missing", "The board cannot use a Linear key: " + str(d.get("message") or "no reason given"),
                                  STORE, "command")
    elif in_keychain:
        out["linear_key"] = entry("ok", "The key is in the Keychain and the board reads Linear with it.")
    else:
        out["linear_key"] = entry("ok", "The board reads Linear, but there is no Keychain item ("
                                  + E["SC_SERVICE"] + "/" + E["SC_ACCOUNT"] + "): the board is using a fallback key; `"
                                  + STORE + "` moves it to the Keychain.")

if not in_herdr:
    for k in ("space_binding", "worktree_binding"):
        out[k] = entry("unknown", "Unknown here: run in herdr to check and bind it.")
elif not daemon_ok:
    for k in ("space_binding", "worktree_binding"):
        out[k] = entry("unknown", "Unknown until the board answers: " + daemon_first)
else:
    s = run_json([board, "linear", "session", "--json"])
    if s is None:
        for k in ("space_binding", "worktree_binding"):
            out[k] = entry("unknown", "board linear session --json did not answer.")
    elif not s.get("space_bound"):
        out["space_binding"] = entry("missing", "This herdr space (" + space + ") is not bound to a Linear project.",
                                     "Open the board (" + OPEN_BOARD + "), press s, choose this space, press Enter, "
                                     "choose a project, press Enter.", "instruction")
        out["worktree_binding"] = entry("unknown", "Bind the space first.")
    else:
        out["space_binding"] = entry("ok", "This herdr space (" + space + ") is bound to a Linear project.")
        issue = ((s.get("binding") or {}).get("issue") or "")
        out["worktree_binding"] = entry("ok", "This worktree is bound to " + issue + ".") if issue else entry(
            "missing", "This worktree is not bound to an issue.")

print(json.dumps(out, indent=2))
'
exit 0
