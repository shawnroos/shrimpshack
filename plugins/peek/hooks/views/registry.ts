import { matches, readDefinition } from './definition'
import type { Definition, DefinitionCheck, DefinitionProblem, MatchDoc } from './definition'

export type ViewsIo = {
  list: (dir: string) => Promise<readonly { name: string; kind: string }[]>
  read: (path: string) => Promise<string>
  stat: (path: string) => Promise<{ mtimeMs: number } | null>
}
export type ViewFolders = { builtIn: string; user: string }
export type ViewsLoad = { definitions: Definition[]; problems: DefinitionProblem[] }
export type ViewRegistry = {
  load: (io: ViewsIo, folders: ViewFolders) => Promise<ViewsLoad>
  definitionFor: (io: ViewsIo, folders: ViewFolders, doc: MatchDoc) => Promise<Definition | null>
}

export const REGISTRY_CAPS = { filesPerFolder: 100, cached: 250 }

async function definitionFiles(io: ViewsIo, dir: string): Promise<{ files: string[]; problems: DefinitionProblem[] }> {
  const entries = await io.list(dir).catch(() => [])
  const names = entries.filter(one => one.kind === 'file' && one.name.endsWith('.md')).map(one => one.name).sort()
  const problems =
    names.length > REGISTRY_CAPS.filesPerFolder
      ? [{ file: dir, path: '$', message: `holds ${names.length} definitions; the first ${REGISTRY_CAPS.filesPerFolder} load` }]
      : []
  return { files: names.slice(0, REGISTRY_CAPS.filesPerFolder).map(name => `${dir}/${name}`), problems }
}

function withoutConflicts(checks: { file: string; check: DefinitionCheck }[]): ViewsLoad {
  const filesByType = new Map<string, string[]>()
  for (const { file, check } of checks) {
    if (check.ok) filesByType.set(check.definition.type, [...(filesByType.get(check.definition.type) ?? []), file])
  }
  const definitions: Definition[] = []
  const problems: DefinitionProblem[] = []
  for (const { file, check } of checks) {
    if (!check.ok) {
      problems.push(...check.problems)
      continue
    }
    const others = (filesByType.get(check.definition.type) ?? []).filter(one => one !== file)
    if (others.length) problems.push({ file, path: 'type', message: `"${check.definition.type}" is also defined by ${others.join(', ')}; neither loads` })
    else definitions.push(check.definition)
  }
  definitions.sort((a, b) => a.type.localeCompare(b.type))
  return { definitions, problems }
}

export function createViewRegistry(): ViewRegistry {
  const cache = new Map<string, { mtimeMs: number; check: DefinitionCheck }>()

  async function checkOf(io: ViewsIo, file: string): Promise<DefinitionCheck | null> {
    const stat = await io.stat(file).catch(() => null)
    if (!stat) {
      cache.delete(file)
      return null
    }
    const known = cache.get(file)
    if (known && known.mtimeMs === stat.mtimeMs) return known.check
    const text = await io.read(file).catch(() => null)
    if (text === null) return null
    const check = readDefinition(file, text)
    cache.delete(file)
    if (cache.size >= REGISTRY_CAPS.cached) {
      const oldest = cache.keys().next().value
      if (oldest !== undefined) cache.delete(oldest)
    }
    cache.set(file, { mtimeMs: stat.mtimeMs, check })
    return check
  }

  async function load(io: ViewsIo, folders: ViewFolders): Promise<ViewsLoad> {
    const listed = [await definitionFiles(io, folders.builtIn), await definitionFiles(io, folders.user)]
    const checks: { file: string; check: DefinitionCheck }[] = []
    for (const file of listed.flatMap(one => one.files)) {
      const check = await checkOf(io, file)
      if (check) checks.push({ file, check })
    }
    const loaded = withoutConflicts(checks)
    return { definitions: loaded.definitions, problems: [...listed.flatMap(one => one.problems), ...loaded.problems] }
  }

  return {
    load,
    async definitionFor(io, folders, doc) {
      const { definitions } = await load(io, folders)
      return definitions.find(one => matches(one, doc)) ?? null
    },
  }
}
