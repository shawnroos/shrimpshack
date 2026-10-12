import type { Mention } from '../types'
import { record } from './capture'
import { hasMeaningfulWords, noteMentions, parseStatLines, rankRecent } from './gallery'
import type { FileEntry, Scope } from './gallery'
import { pathCandidates, urlCandidates } from './markdown'
import { nav, remoteRef, sessionRefContext, titlesByKey } from './navigation'
import type { NavIo } from './navigation'
import { remoteNaming } from './pane/look'
import { fileHref, kindOf, parseHref, resolvePath } from './paths'
import { itemKey, parseRef } from './refs'

const roots = new Map<string, { root: string; isWorktree: boolean } | null>()
const exists = new Map<string, boolean>()

export const forgetPath = (abs: string) => void exists.delete(abs)

export async function pathExists(io: NavIo, abs: string): Promise<boolean> {
  const known = exists.get(abs)
  if (known !== undefined) return known
  const found = await io.stat(abs).then(
    stat => stat.kind !== 'other',
    () => false,
  )
  exists.set(abs, found)
  return found
}

export async function gitRoot(io: NavIo, folder: string): Promise<{ root: string; isWorktree: boolean } | null> {
  if (roots.has(folder)) return roots.get(folder) ?? null
  const ran = await io
    .run(['git', '-C', folder, 'rev-parse', '--path-format=absolute', '--show-toplevel', '--git-dir', '--git-common-dir'])
    .catch(() => null)
  const [root, gitDir, commonDir] = ran && ran.exitCode === 0 ? ran.stdout.trim().split('\n') : []
  const found = root ? { root, isWorktree: Boolean(gitDir && commonDir && gitDir !== commonDir) } : null
  roots.set(folder, found)
  return found
}

export async function remember(
  io: NavIo,
  texts: readonly string[],
  created: readonly string[],
  touched: readonly string[],
) {
  const cwd = await io.cwd()
  const home = (await io.home()) ?? ''
  const toHrefs = async (raws: readonly string[]) => {
    const out: string[] = []
    for (const raw of raws) {
      const abs = resolvePath(raw, cwd, home)
      if (await pathExists(io, abs)) out.push(fileHref(abs))
    }
    return out
  }
  const urls = texts.flatMap(urlCandidates).map(url => (parseRef(url)?.kind === 'slack-thread' ? (parseRef(url)?.address ?? url) : url))
  const artifacts = [...(await toHrefs([...texts.flatMap(pathCandidates), ...created])), ...urls]
  const worked = await toHrefs(touched)
  if (!artifacts.length && !worked.length) return
  const at = await io.now()
  await io.mentions.update(list =>
    noteMentions(noteMentions(list, [...new Set(worked)], at), [...new Set(artifacts)], at, 200, true),
  )
}

export async function noteCapture(io: NavIo, input: Record<string, unknown>, answer: unknown) {
  const at = await io.now()
  nav.lastActivity = at
  const { addresses, grewLinear } = record(input, answer, at)
  if (addresses.length) await io.mentions.update(list => noteMentions(list, addresses, at, 200, true))
  if (grewLinear) io.invalidate()
}

export async function toHref(io: NavIo, raw: string): Promise<string | null> {
  const cleaned = raw.trim().replace(/^[`'"<]+|[`'">.]+$/g, '')
  if (/^https?:\/\//.test(cleaned)) return cleaned
  if (cleaned.startsWith('file:')) return cleaned
  const needsContext = /^(?:#\d+|[A-Z][A-Z0-9]{0,9}-\d+)$/i.test(cleaned)
  const ref = parseRef(cleaned, needsContext ? await sessionRefContext(io) : {})
  if (ref) return ref.address
  const match = /^(.+?)(?::(\d+))?$/.exec(cleaned)
  const abs = resolvePath(match?.[1] ?? cleaned, await io.cwd(), (await io.home()) ?? '')
  forgetPath(abs)
  if (await pathExists(io, abs)) return fileHref(abs, match?.[2] ? Number(match[2]) : undefined)
  return bareDomain(cleaned)
}

// `.md` and friends are real top-level domains, so a missing local file named like one goes to the guess, not the web.
const FILE_SUFFIX = /\.(?:md|mdx|ts|tsx|js|jsx|json|py|txt|png|jpe?g|gif|svg|pdf|csv|html?|ya?ml|toml|sh|swift|rs|go|css|lock|log)$/i

function bareDomain(text: string): string | null {
  const found = /^((?:[a-z0-9-]+\.)+[a-z]{2,})(:\d+)?([/?#]\S*)?$/i.exec(text)
  if (!found?.[1]) return null
  if (!found[3] && FILE_SUFFIX.test(found[1])) return null
  return `https://${text}`
}

export async function guess(io: NavIo, query: string): Promise<string | null> {
  const list = (await io.mentions.read()).map(one => one.href)
  const ranked = rankRecent(query, list)
  const [first, second] = ranked
  if (first && hasMeaningfulWords(query) && first.score >= 3 && first.score - (second?.score ?? 0) >= 1) {
    return first.href
  }
  const shortlist = list.slice(-25).reverse().map(href => `- ${parseHref(href)?.path ?? href}`).join('\n')
  io.toast('Peek: working out which one you mean…')
  const reply = await io.fork({
    prompt: [
      `I ran /peek ${query}`,
      'Which ONE file path or URL from this conversation do I mean? Prefer the most recent match.',
      'If I name a website or online service that is not in this conversation (e.g. "the nytimes website"), reply with its homepage URL instead.',
      shortlist ? `Paths and links seen recently, newest first:\n${shortlist}` : '',
      'Reply with only the absolute path (optionally :line) or the URL, nothing else. If nothing fits, reply NONE.',
    ].filter(Boolean).join('\n\n'),
  })
  if (reply.isAnswered) {
    const line = reply.text.trim().split('\n')[0] ?? ''
    if (line && line !== 'NONE') {
      const href = await toHref(io, line)
      if (href) return href
    }
    return null
  }
  return first && first.score >= 1 ? first.href : null
}

const SCOPE_TTL_MS = 30_000
const MAX_WORKTREES = 12
const LIST_FILES =
  "git ls-files -z --cached --others --exclude-standard | head -c 2000000 | xargs -0 stat -f '%m %z %N' 2>/dev/null | head -4000"

const scopeCache = new Map<string, { at: number; entries: FileEntry[] }>()
const scopeLoading = new Set<string>()

async function listRoot(io: NavIo, root: string, worktree?: string): Promise<FileEntry[]> {
  const ran = await io.run(['sh', '-c', LIST_FILES], { cwd: root, timeoutMs: 20_000 }).catch(() => null)
  return ran ? parseStatLines(ran.stdout, root, worktree) : []
}

export async function sessionEntries(io: NavIo, list: readonly Mention[]): Promise<FileEntry[]> {
  const out: FileEntry[] = []
  const remoteTitles = titlesByKey()
  for (const one of [...list].reverse()) {
    const file = parseHref(one.href)
    const path = file?.path ?? one.href
    const name = path.split('/').pop() || path
    const stat = file ? await io.stat(path).catch(() => null) : null
    if (file && !stat) continue
    const ref = file ? null : remoteRef(one.href)
    const label = ref ? remoteTitles.get(itemKey(ref.address)) : undefined
    if (ref) {
      const naming = remoteNaming(ref, label, { bare: path, namesThread: true, host: () => new URL(ref.address).hostname })
      out.push({
        href: one.href,
        path,
        name: naming.name,
        folder: naming.where,
        kind: naming.kind,
        status: label?.status,
        favicon: (await io.remotePicture(label?.favicon))?.file,
        mtimeMs: 0,
        size: 0,
        mentions: one.count,
        mentionedAt: one.at,
        role: one.isArtifact ? 'artifact' : 'touched',
      })
      continue
    }
    out.push({
      href: one.href,
      path,
      name,
      folder: path.slice(0, Math.max(0, path.length - name.length - 1)),
      kind: file ? (stat?.kind === 'dir' ? 'folder' : kindOf(path)) : 'web',
      mtimeMs: stat?.mtimeMs ?? 0,
      size: stat?.size ?? 0,
      mentions: one.count,
      mentionedAt: one.at,
      role: one.isArtifact ? 'artifact' : 'touched',
    })
  }
  return out
}

async function loadScope(io: NavIo, scope: Exclude<Scope, 'session'>, cwd: string): Promise<FileEntry[]> {
  const git = await gitRoot(io, cwd)
  if (!git) return []
  if (scope === 'worktree') return listRoot(io, git.root, git.root.split('/').pop())
  const ran = await io.run(['git', '-C', git.root, 'worktree', 'list', '--porcelain']).catch(() => null)
  const roots = (ran?.stdout ?? '')
    .split('\n')
    .filter(line => line.startsWith('worktree '))
    .map(line => line.slice('worktree '.length))
    .slice(0, MAX_WORKTREES)
  const all: FileEntry[] = []
  for (const root of roots.length ? roots : [git.root]) all.push(...(await listRoot(io, root, root.split('/').pop())))
  return all
}

// Returns the cached listing, or null while a background load runs; the load
// redraws the pane when it lands.
export function scopeEntries(io: NavIo, scope: Exclude<Scope, 'session'>, cwd: string, now: number): FileEntry[] | null {
  const key = `${scope}|${cwd}`
  const cached = scopeCache.get(key)
  if (cached && now - cached.at < SCOPE_TTL_MS) return cached.entries
  if (!scopeLoading.has(key)) {
    scopeLoading.add(key)
    void loadScope(io, scope, cwd)
      .then(entries => scopeCache.set(key, { at: Date.now(), entries }))
      .catch(() => scopeCache.set(key, { at: Date.now(), entries: [] }))
      .finally(() => {
        scopeLoading.delete(key)
        io.invalidate()
      })
  }
  return cached?.entries ?? null
}

export function withMentions(entries: readonly FileEntry[], list: readonly Mention[]): FileEntry[] {
  const byHref = new Map(list.map(one => [one.href, one]))
  return entries.map(one => {
    const hit = byHref.get(one.href)
    return hit
      ? { ...one, mentions: hit.count, mentionedAt: hit.at, role: hit.isArtifact ? ('artifact' as const) : ('touched' as const) }
      : one
  })
}
