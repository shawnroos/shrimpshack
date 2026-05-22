#!/usr/bin/env python3
# claude-modes V2 (U8): realpath-based path-traversal validator (R7).
#
# Purpose:
#   The user-catalog symlink rebuild reads relative `entry` strings from a
#   mode YAML's `mechanism.user_catalog.{commands,agents}` manifest and
#   creates symlinks pointing at files under
#   `~/.claude/modes/.user-catalog/<category>/<entry>`.
#
#   If `entry` is hostile (e.g., "../../.ssh/id_rsa" or "/etc/passwd"),
#   a naive `os.path.join(target_dir, entry)` would resolve OUTSIDE the
#   staging dir. This script is the single mechanical chokepoint that
#   refuses any such entry.
#
# Contract:
#   argv[1] = target_dir (the staging dir, e.g., the commands/ subdir)
#   argv[2] = entry      (the manifest string, treated as untrusted)
#
#   Exit 0 + print resolved path on stdout if and only if
#   `os.path.realpath(os.path.join(target_dir, entry))` resolves to a path
#   STRICTLY under `os.path.realpath(target_dir) + os.sep`.
#
#   Exit 1 + "R7: path traversal detected" on stderr otherwise.
#   Exit 2 + usage line on stderr for malformed argv.
#
# Why realpath (not string-prefix on the raw join):
#   `os.path.realpath` resolves `..` components AND follows any symlinks
#   in the chain — so an attacker who plants a symlink inside the staging
#   dir pointing at /etc/passwd cannot bypass the check by passing the
#   symlink's name as `entry`. The resolution chases the symlink to
#   /etc/passwd, then the startswith() check rejects it.
#
# Why `os.path.realpath(target_dir) + os.sep` (the trailing separator):
#   Without the trailing separator, a directory named `.user-catalog2`
#   would match a check against `.user-catalog` — the classic prefix
#   confusion. Appending os.sep forces the match to be at a directory
#   boundary.
#
# Why `os.path.join` behavior with absolute second arg is fine:
#   `os.path.join("/dir", "/etc/passwd")` returns "/etc/passwd" — the
#   absolute argument wins. That's exactly what we want: the entry
#   `/etc/passwd` then realpaths to /etc/passwd, which doesn't startswith
#   the staging dir prefix → rejected.

import os
import os.path
import sys

# Python-side terminal-escape defense (twin of lib/sanitize.sh). `entry` is
# untrusted manifest content from a mode YAML; a hostile entry can carry
# ESC/OSC/CSI/bidi bytes that would inject into the terminal if printed raw in
# the R7 rejection message. Route it (and its realpath) through this first.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sanitize import sanitize_for_display  # noqa: E402


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(
            "Usage: symlink-validate.py <target_dir> <entry>\n"
            "  target_dir: absolute path to the staging dir\n"
            "  entry:      manifest string (untrusted)\n"
        )
        return 2

    target_dir = sys.argv[1]
    entry = sys.argv[2]

    # Reject the empty-entry case explicitly — silent acceptance would
    # resolve to the target_dir itself.
    if entry == "":
        sys.stderr.write("R7: path traversal detected — entry is empty\n")
        return 1

    # Compute the candidate path. os.path.join handles absolute `entry`
    # by dropping target_dir, which we WANT — it ensures the realpath of
    # an absolute attack like "/etc/passwd" doesn't accidentally end up
    # under target_dir.
    candidate = os.path.join(target_dir, entry)

    # Resolve both sides via realpath. We intentionally do NOT require
    # the candidate to exist — realpath on a non-existent path is
    # lexical (resolves .. and . components) plus follows any existing
    # symlinks in the chain. This is what we want for both:
    #   (a) the attack vector `commands/../../etc/passwd` (file may not
    #       exist; the .. components still resolve)
    #   (b) the planted-symlink-inside-staging vector (the symlink IS
    #       resolved, even if the original entry path itself is not)
    resolved = os.path.realpath(candidate)
    resolved_target = os.path.realpath(target_dir)

    # Enforce the trailing-separator boundary so /staging vs /staging2
    # cannot collide.
    boundary = resolved_target + os.sep

    if not resolved.startswith(boundary):
        sys.stderr.write(
            f"R7: path traversal detected — entry "
            f"'{sanitize_for_display(entry)}' resolves to "
            f"'{sanitize_for_display(resolved)}' which is not under "
            f"'{sanitize_for_display(resolved_target)}/'\n"
        )
        return 1

    # Print the safe resolved path so callers can use it (avoids them
    # re-doing the realpath).
    print(resolved)
    return 0


if __name__ == "__main__":
    sys.exit(main())
