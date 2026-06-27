#!/usr/bin/env python3
"""Pin Claude Code's native auto-memory directory to a fixed canonical path.

Claude Code's auto-memory feature derives its write directory from the git
repository root, so a session started inside a project repo scatters new memories
to a per-project store instead of the canonical reflect store. The
`autoMemoryDirectory` settings key pins it to a fixed path regardless of cwd.

This helper merges that key into a settings.json idempotently and conservatively:

  - missing / empty (or whitespace-only) file -> create {} and add the key
  - parse error, or valid-but-non-object JSON  -> skip with a warning (never
    overwrite — preserve whatever the user has)
  - key absent                                 -> add it (backing up first)
  - key present, resolves to the same dir      -> no-op (idempotent)
  - key present, resolves to a different dir   -> leave it, warn (no-clobber; a
    deliberate user choice wins)

Portability: the stored value uses the `~/`-prefixed form when the target is
under $HOME (so a copied settings.json does not carry a hardcoded username), else
the absolute path. The no-clobber check compares NORMALIZED paths (expand `~`,
strip trailing slash) so the `~/`-form and the absolute form of the same dir are
treated as equal rather than provoking a spurious warning on every run.

Version caveat: whenever the pin is written or confirmed, an UNCONDITIONAL caveat
line is printed to stdout (the key only takes effect on Claude Code >= 2.1.74 —
the key shipped after the auto-memory feature). No runtime version detection is
attempted: shell-side detection is unreliable and a false negative would suppress
the caveat on exactly the affected client, so the caveat is always shown.

Adding the key rewrites the file with 2-space indentation: formatting is
normalized, but keys and values are preserved (and the `.pre-auto-memory-pin.bak`
backup restores the prior formatting). Claude Code settings.json is strict JSON
with no comments, so nothing meaningful is lost.

Usage: pin-auto-memory-dir.py <settings_path> <target_dir>
Always exits 0 (fail-open). Warnings -> stderr; caveat -> stdout.
"""
import json
import os
import shutil
import sys

KEY = "autoMemoryDirectory"
MIN_VERSION = "2.1.74"


def warn(msg):
    sys.stderr.write("reflect setup: %s\n" % msg)


def caveat(stored):
    # Unconditional — printed on every write/confirm, never branched on a
    # detected client version (see module docstring).
    sys.stdout.write(
        "reflect setup: pinned auto-memory dir %s; effective on Claude Code >= %s\n"
        % (stored, MIN_VERSION)
    )


def normalize(path):
    if not path:
        return ""
    return os.path.expanduser(path).rstrip("/")


def stored_form(target, home):
    """`~/`-prefixed form when target is under $HOME, else the absolute path."""
    home = (home or "").rstrip("/")
    t = target.rstrip("/")
    if home and (t == home or t.startswith(home + "/")):
        return "~" + t[len(home):]
    return t


def main():
    if len(sys.argv) != 3:
        warn("pin-auto-memory-dir: usage: <settings_path> <target_dir>")
        return 0
    settings_path, target = sys.argv[1], sys.argv[2]
    stored = stored_form(target, os.environ.get("HOME", ""))

    data = {}
    if os.path.exists(settings_path):
        try:
            with open(settings_path, "r", encoding="utf-8") as f:
                raw = f.read()
        except (OSError, UnicodeDecodeError) as e:
            # UnicodeDecodeError is a ValueError, not an OSError — guard it
            # explicitly so an undecodable file fails open instead of crashing.
            warn("could not read %s (%s) — auto-memory pin not written" % (settings_path, e))
            return 0
        if raw.strip() == "":
            data = {}  # empty / whitespace-only -> treat as missing
        else:
            try:
                parsed = json.loads(raw)
            except ValueError:
                warn("%s is not valid JSON — left unchanged, auto-memory pin not written" % settings_path)
                return 0
            if not isinstance(parsed, dict):
                warn("%s is valid JSON but not an object — left unchanged, auto-memory pin not written" % settings_path)
                return 0
            data = parsed

    existing = data.get(KEY)
    if isinstance(existing, str) and existing.strip():
        if normalize(existing) == normalize(target):
            caveat(stored)  # already pinned (in any equivalent form) — confirm
            return 0
        warn("%s already sets %s to %r (not the canonical store) — leaving it; "
             "remove that line and re-run to adopt the canonical pin"
             % (settings_path, KEY, existing))
        return 0

    # Key absent (or empty/non-string) -> write it. Back up first (best-effort).
    if os.path.exists(settings_path):
        try:
            shutil.copy2(settings_path, settings_path + ".pre-auto-memory-pin.bak")
        except OSError:
            pass
    data[KEY] = stored
    tmp = settings_path + ".tmp"
    try:
        parent = os.path.dirname(settings_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, settings_path)
    except OSError as e:
        warn("could not write %s (%s) — auto-memory pin not applied" % (settings_path, e))
        return 0
    finally:
        # os.replace removes tmp on success; clean up a stray tmp on failure.
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass
    caveat(stored)
    return 0


if __name__ == "__main__":
    sys.exit(main())
