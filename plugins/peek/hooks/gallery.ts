import { typeOf } from './kinds'
import { PATH_EXTS, extOf, fileHref, kindOf, parseHref } from './paths'

const STOP_WORDS = new Set(
  'a an the that this those these me my show open view see peek at of for to in on file doc docs document one it please last new'.split(' '),
)

const KIND_WORDS: Record<string, readonly string[]> = {
  diagram: ['mmd', 'mermaid', 'svg', 'excalidraw', 'drawio', 'png'],
  image: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'heic'],
  picture: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'heic'],
  screenshot: ['png', 'jpg', 'jpeg'],
  plan: ['md'],
  page: ['html', 'htm'],
  html: ['html', 'htm'],
}

function hrefWords(href: string): string {
  const path = parseHref(href)?.path ?? href
  return path.toLowerCase().replace(/[^a-z0-9]+/g, ' ')
}

// Scores each recent href against the loose words of a request. Newer hrefs
// break ties, so "that doc" with nothing else to go on picks the latest.
export function rankRecent(query: string, recent: readonly string[]): { href: string; score: number }[] {
  const words = query.toLowerCase().split(/[^a-z0-9]+/).filter(word => word && !STOP_WORDS.has(word))
  return recent
    .map((href, index) => {
      const haystack = hrefWords(href)
      const name = haystack.split(' ').filter(Boolean).slice(-2).join(' ')
      const ext = extOf(parseHref(href)?.path ?? href)
      let score = 0
      for (const word of words) {
        const kinds = KIND_WORDS[word]
        if (kinds?.includes(ext)) score += 2
        else if (name.includes(word)) score += 3
        else if (haystack.includes(word)) score += 1
      }
      return { href, score: score + index / 1000 }
    })
    .sort((a, b) => b.score - a.score)
}

export function hasMeaningfulWords(query: string): boolean {
  return query.toLowerCase().split(/[^a-z0-9]+/).some(word => word && !STOP_WORDS.has(word))
}

export type MentionEntry = { href: string; at: number; count: number; isArtifact?: boolean }

// An artifact stays an artifact: a later read of the same file never demotes it.
export function noteMentions(
  list: readonly MentionEntry[],
  hrefs: readonly string[],
  at: number,
  cap = 200,
  isArtifact = false,
): MentionEntry[] {
  const byHref = new Map(list.map(one => [one.href, one]))
  for (const href of hrefs) {
    const before = byHref.get(href)
    byHref.delete(href)
    byHref.set(href, { href, at, count: (before?.count ?? 0) + 1, isArtifact: isArtifact || before?.isArtifact === true })
  }
  return [...byHref.values()].slice(-cap)
}

export type Scope = 'session' | 'worktree' | 'repo'
export type GalleryType = 'all' | 'markdown' | 'code' | 'data' | 'image' | 'diagram' | 'html'
export type GallerySort = 'recent' | 'name' | 'size' | 'mentions'

export type FileEntry = {
  href: string
  path: string
  name: string
  folder: string
  kind: string
  mtimeMs: number
  size: number
  mentions: number
  mentionedAt: number
  worktree?: string
  role?: 'artifact' | 'touched'
  status?: string
  favicon?: string
}

export type RoleFilter = 'all' | 'artifacts' | 'touched'

export function filterRole(entries: readonly FileEntry[], filter: RoleFilter): FileEntry[] {
  if (filter === 'all') return [...entries]
  const wanted = filter === 'artifacts' ? 'artifact' : 'touched'
  return entries.filter(one => one.role === wanted)
}

const VIEWABLE = new RegExp(`\\.(?:${PATH_EXTS})$`, 'i')

export function isViewable(path: string): boolean {
  return VIEWABLE.test(path)
}

// `stat -f '%m %z %N'` lines (mtime seconds, size bytes, path relative to root).
export function parseStatLines(out: string, root: string, worktree?: string): FileEntry[] {
  const entries: FileEntry[] = []
  for (const line of out.split('\n')) {
    const match = /^(\d+) (\d+) (.+)$/.exec(line.trim())
    if (!match?.[3] || !isViewable(match[3])) continue
    const rel = match[3].replace(/^\.\//, '')
    const name = rel.split('/').pop() ?? rel
    const path = `${root}/${rel}`
    entries.push({
      href: fileHref(path),
      path,
      name,
      folder: rel.slice(0, Math.max(0, rel.length - name.length - 1)),
      kind: kindOf(path),
      mtimeMs: Number(match[1]) * 1000,
      size: Number(match[2]),
      mentions: 0,
      mentionedAt: 0,
      worktree,
    })
  }
  return entries
}

export function selectEntries(
  entries: readonly FileEntry[],
  type: GalleryType,
  query: string,
  sort: GallerySort,
): FileEntry[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  const kept = entries.filter(one => {
    if (type !== 'all' && typeOf(one.kind) !== type) return false
    const haystack = `${one.folder}/${one.name} ${one.worktree ?? ''}`.toLowerCase()
    return words.every(word => haystack.includes(word))
  })
  const when = (one: FileEntry) => Math.max(one.mentionedAt, one.mtimeMs)
  const order: Record<GallerySort, (a: FileEntry, b: FileEntry) => number> = {
    recent: (a, b) => when(b) - when(a),
    name: (a, b) => a.name.localeCompare(b.name) || a.folder.localeCompare(b.folder),
    size: (a, b) => b.size - a.size,
    mentions: (a, b) => b.mentions - a.mentions || when(b) - when(a),
  }
  return [...kept].sort(order[sort])
}

export function nextOf<T>(list: readonly T[], current: T): T {
  const at = list.indexOf(current)
  return list[(at + 1) % list.length] ?? current
}

export function gridColumns(width: number, minCard = 26, gap = 1): number {
  return Math.max(1, Math.floor((width + gap) / (minCard + gap)))
}

const FILE_FIELDS = ['file_path', 'path', 'notebook_path']

// Sorts one assistant row into what it showed or made (reply text, Write) and
// what it only worked on (every other tool's file inputs).
export function classifyBlocks(content: readonly { type: string; [field: string]: unknown }[]) {
  const texts: string[] = []
  const created: string[] = []
  const touched: string[] = []
  for (const block of content) {
    if (block.type === 'text' && typeof block.text === 'string') texts.push(block.text)
    if (block.type === 'tool_use' && block.input && typeof block.input === 'object') {
      const input = block.input as Record<string, unknown>
      const bucket = block.name === 'Write' ? created : touched
      for (const field of FILE_FIELDS) {
        const value = input[field]
        if (typeof value === 'string') bucket.push(value)
      }
    }
  }
  return { texts, created, touched }
}

export function toggleStar(stars: readonly string[], href: string, wanted?: boolean): string[] {
  const isOn = stars.includes(href)
  const next = wanted ?? !isOn
  if (next === isOn) return [...stars]
  return next ? [...stars, href] : stars.filter(one => one !== href)
}
