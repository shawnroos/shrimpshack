import { baseName } from '../paths'
import { matches, matchesRule, readDefinition } from './definition'
import type { Definition, DefinitionCheck, DefinitionProblem, MatchDoc, MatchRule } from './definition'

export type ViewsIo = {
  list: (dir: string) => Promise<readonly { name: string; kind: string }[]>
  read: (path: string) => Promise<string>
  stat: (path: string) => Promise<{ mtimeMs: number } | null>
}
export type ViewFolders = { builtIn: string; user: string }
export type ProblemSource = { file: string; match?: MatchRule; problems: DefinitionProblem[] }
export type ViewsLoad = { definitions: Definition[]; problems: DefinitionProblem[]; sources: ProblemSource[] }
export type ViewRegistry = {
  load: (io: ViewsIo, folders: ViewFolders) => Promise<ViewsLoad>
  definitionFor: (io: ViewsIo, folders: ViewFolders, doc: MatchDoc) => Promise<Definition | null>
}

const REGISTRY_CAPS = { filesPerFolder: 100, cached: 250 }

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
  const sources: ProblemSource[] = []
  for (const { file, check } of checks) {
    if (!check.ok) {
      sources.push({ file, ...(check.match ? { match: check.match } : {}), problems: check.problems })
      continue
    }
    const others = (filesByType.get(check.definition.type) ?? []).filter(one => one !== file)
    if (others.length) sources.push({ file, match: check.definition.match, problems: [{ file, path: 'type', message: `"${check.definition.type}" is also defined by ${others.join(', ')}; neither loads` }] })
    else definitions.push(check.definition)
  }
  definitions.sort((a, b) => a.type.localeCompare(b.type))
  return { definitions, sources, problems: sources.flatMap(one => one.problems) }
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
    const listed = await Promise.all([definitionFiles(io, folders.builtIn), definitionFiles(io, folders.user)])
    const files = listed.flatMap(one => one.files)
    const looked = await Promise.all(files.map(file => checkOf(io, file)))
    const checks = files.flatMap((file, i) => {
      const check = looked[i]
      return check ? [{ file, check }] : []
    })
    const loaded = withoutConflicts(checks)
    const sources = [...listed.flatMap(one => one.problems.map(problem => ({ file: problem.file, problems: [problem] }))), ...loaded.sources]
    return { definitions: loaded.definitions, problems: sources.flatMap(one => one.problems), sources }
  }

  return {
    load,
    async definitionFor(io, folders, doc) {
      const { definitions } = await load(io, folders)
      return definitions.find(one => matches(one, doc)) ?? null
    },
  }
}

const typeNameOf = (file: string) => baseName(file).replace(/\.md$/, '')

// A definition too broken to name its own match is shown only on the record page its file is named after.
export function problemsFor(load: ViewsLoad, doc: MatchDoc): DefinitionProblem[] {
  return load.sources.filter(one => (one.match ? matchesRule(one.match, doc) : typeNameOf(one.file) === doc.recordKind)).flatMap(one => one.problems)
}
