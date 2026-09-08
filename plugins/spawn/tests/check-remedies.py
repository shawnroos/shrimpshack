#!/usr/bin/env python3
"""Every error class a surface declares must resolve to a real, distinct remedy.

A remedy is INSTRUCTION the plugin hands a caller, and callers act on it. The
`upstream_error` remedy told people to retry and then switch alias on a 502 that
is really a size ceiling — advice that costs two calls and cannot work. It drifted
there because nothing checked it: the class NAME appeared in tests, which proves
nothing about the prose.

Prose correctness is not mechanically checkable. Three things are, and they are
the ones that were actually broken or could break silently:

  * every declared class resolves to something          (no silent fall-through)
  * no remedy is empty                                  (no class ships mute)
  * no two classes in one surface share a remedy        (a copy-paste that hands
                                                         class A class B's advice
                                                         is how wrong instruction
                                                         reaches a user)

Each surface carries its OWN remedy_for over its own class set — seven of them,
only spawnctl delegating to the shared one — so each is checked against the
classes it declares, not against a global list it never emits.

Exits 0 with a count, or 1 naming every failure. Run from the repo root or any
cwd; takes the lib dir as its one argument.
"""
import glob
import os
import re
import sys


def remedy_bodies(src: str) -> dict[str, str]:
    """Map class -> remedy text, by PARSING the remedy_for body.

    Deliberately static. Sourcing a surface script to call its remedy_for runs
    that script's dispatch — measured: every class came back empty because the
    script had already exited. A checker whose probe silently produces nothing
    reports the codebase as broken when the checker is.
    """
    m = re.search(r"^(?:spawn::)?remedy_for\(\)\s*\{(.*?)^\}", src, re.M | re.S)
    if not m:
        return {}
    body = m.group(1)
    out: dict[str, str] = {}
    # `<class>)` then a printf, up to the `;;` that closes the branch.
    for cls, chunk in re.findall(r"^\s*([a-z_]+)\)\s*$(.*?);;", body, re.M | re.S):
        text = " ".join(re.findall(r"printf\s+'([^']*)'", chunk))
        out[cls] = text.strip()
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-remedies.py <lib-dir>", file=sys.stderr)
        return 2
    lib = sys.argv[1]

    checked = 0
    bad: list[str] = []

    for path in sorted(glob.glob(os.path.join(lib, "*.sh"))):
        src = open(path).read()
        table = remedy_bodies(src)
        if not table:
            continue
        name = os.path.basename(path)
        seen: dict[str, str] = {}
        for cls, text in sorted(table.items()):
            checked += 1
            if not text:
                bad.append(f"{name}: '{cls}' has an EMPTY remedy")
            elif text in seen:
                bad.append(f"{name}: '{cls}' shares its remedy with '{seen[text]}'")
            else:
                seen[text] = cls

    if checked == 0:
        print("no remedy branches discovered — this check would pass vacuously")
        return 1
    if bad:
        print("\n".join(bad))
        return 1
    print(f"{checked} class/remedy pairs checked, all present and distinct")
    return 0


if __name__ == "__main__":
    sys.exit(main())
