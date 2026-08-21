# sweep_work — leave no live process holding $WORK, then let the caller remove it.
#
# ONE SNAPSHOT IS NOT A SWEEP. A single `pgrep`, kill that list, done, is stale the
# instant it is taken: bg-agent.sh nohups the supervisor on its own clock after
# dispatch returns, and forks a `jobs.sh log` child per log line, so a process born
# after the snapshot is never signalled — and the `rm -rf` that follows then walks a
# tree that process is still writing into, which is the "Directory not empty" these
# suites failed with intermittently. So: re-sweep until a pass sees NOTHING. The
# clean pass IS the wait; these are not our children, so `wait` cannot be used.
#
# EVERY signal is scoped to the caller's own mktemp $WORK path. Never signal by
# script name: other sessions on the same box run these same scripts, and a
# name-scoped kill takes their work with it.
#
# Sourced by every unit suite that dispatches. One definition, because seventeen
# copies is how the single-pass version survived in sixteen files after the
# seventeenth was fixed.
sweep_work() {
    local pass p found
    for pass in $(seq 1 25); do
        found=0
        for p in $(pgrep -f "$WORK" 2>/dev/null); do
            [ "$p" = "$$" ] && continue
            found=1
            # `|| :` because a pid can exit between the pgrep and this kill, and
            # kill then returns 1. A bats test body runs under errexit, so an
            # unguarded kill aborts the sweep mid-pass — measured, as a real
            # failure in a full-file run.
            kill -9 "$p" 2>/dev/null || :
        done
        if [ "$found" -eq 0 ]; then return 0; fi
        sleep 0.1
    done
    printf 'sweep_work: processes still hold %s after 25 passes:\n' "$WORK" >&2
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        ps -o pid=,args= -p "$p" 2>/dev/null
    done >&2
    return 1
}
