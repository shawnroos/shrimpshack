import type { Ref } from '../refs'

export type LinearContext = { workspace?: string; teamKeys: string[] }

// Two inputs, one owner: the workspace and teams the Linear API reported at boot, and those learned from captured
// reads. A captured read is parsed against what capture learned alone; every other reader sees both, boot first.
let booted: LinearContext | null = null
let learnedWorkspace: string | undefined
const learnedTeams = new Set<string>()

export function bootLinearIdentity(context: LinearContext): void {
  booted = context
}

export function learnLinear(refs: readonly Ref[]): boolean {
  let grew = false
  for (const ref of refs) {
    if (ref.kind !== 'linear-issue' || !ref.workspace || !ref.key) continue
    if (!learnedWorkspace) {
      learnedWorkspace = ref.workspace
      grew = true
    }
    if (ref.workspace !== learnedWorkspace) continue
    const team = ref.key.split('-')[0] ?? ''
    if (team && !learnedTeams.has(team)) {
      learnedTeams.add(team)
      grew = true
    }
  }
  return grew
}

export function capturedLinearContext(): LinearContext {
  return { workspace: learnedWorkspace, teamKeys: [...learnedTeams] }
}

export function linearContext(): LinearContext {
  return {
    teamKeys: [...new Set([...(booted?.teamKeys ?? []), ...learnedTeams])],
    workspace: booted?.workspace ?? learnedWorkspace,
  }
}
