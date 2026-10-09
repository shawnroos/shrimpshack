import type { RemoteKind } from '../types'

export type RefKind = RemoteKind | 'gh-number'

export type Ref = {
  kind: RefKind
  address: string
  owner?: string
  repo?: string
  number?: number
  workspace?: string
  key?: string
  slug?: string
}

export type RefContext = { teamKeys?: readonly string[]; workspace?: string; repo?: string }

// First path segments GitHub uses for its own pages, never an owner.
const GITHUB_RESERVED = new Set([
  'about', 'apps', 'codespaces', 'collections', 'enterprise', 'explore', 'features', 'issues', 'login', 'marketplace',
  'new', 'notifications', 'orgs', 'pricing', 'pulls', 'search', 'settings', 'sponsors', 'stars', 'topics', 'trending', 'users',
])
const NAME = /^[\w.-]+$/

const OWNER_REPO_NUMBER = /^([A-Za-z0-9][\w.-]*)\/([\w.-]+)#(\d+)$/
const HASH_NUMBER = /^#(\d+)$/
const LINEAR_ID = /^([A-Z][A-Z0-9]{0,9})-(\d+)$/i

function github(owner: string, repo: string, kind: 'gh-issue' | 'gh-pr' | 'gh-number', number: number): Ref {
  const path = kind === 'gh-pr' ? 'pull' : 'issues'
  return { kind, address: `https://github.com/${owner}/${repo}/${path}/${number}`, owner, repo, number }
}

function fromUrl(url: URL): Ref | null {
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null
  const host = url.hostname.toLowerCase().replace(/^www\./, '')
  const parts = url.pathname.split('/').filter(Boolean)
  if (host === 'github.com') {
    const [owner = '', rawRepo = '', section, number] = parts
    const repo = rawRepo.replace(/\.git$/, '')
    if (owner && repo && NAME.test(owner) && NAME.test(repo) && !GITHUB_RESERVED.has(owner.toLowerCase())) {
      if (parts.length === 2) return { kind: 'gh-repo', address: `https://github.com/${owner}/${repo}`, owner, repo }
      if (number && /^\d+$/.test(number) && (section === 'pull' || section === 'issues')) {
        return github(owner, repo, section === 'pull' ? 'gh-pr' : 'gh-issue', Number(number))
      }
    }
  }
  if (host === 'linear.app') {
    const [workspace = '', section, id = ''] = parts
    if (workspace && section === 'issue' && /^[a-z][a-z0-9]{0,9}-\d+$/i.test(id)) {
      const key = id.toUpperCase()
      return { kind: 'linear-issue', address: `https://linear.app/${workspace}/issue/${key}`, workspace, key }
    }
    if (workspace && section === 'project' && NAME.test(id)) {
      return { kind: 'linear-project', address: `https://linear.app/${workspace}/project/${id}`, workspace, slug: id }
    }
  }
  url.hash = ''
  return { kind: 'web', address: url.toString() }
}

export function parseRef(input: string, context: RefContext = {}): Ref | null {
  const text = input.trim()
  if (/^https?:\/\//i.test(text)) {
    try {
      return fromUrl(new URL(text))
    } catch {
      return null
    }
  }
  const full = OWNER_REPO_NUMBER.exec(text)
  if (full?.[1] && full[2] && !GITHUB_RESERVED.has(full[1].toLowerCase())) return github(full[1], full[2], 'gh-number', Number(full[3]))
  const bare = HASH_NUMBER.exec(text)
  const [owner, repo] = context.repo?.split('/') ?? []
  if (bare && owner && repo) return github(owner, repo, 'gh-number', Number(bare[1]))
  const linear = LINEAR_ID.exec(text)
  const team = linear?.[1]?.toUpperCase()
  if (team && context.workspace && context.teamKeys?.includes(team)) {
    const key = `${team}-${linear?.[2]}`
    return { kind: 'linear-issue', address: `https://linear.app/${context.workspace}/issue/${key}`, workspace: context.workspace, key }
  }
  return null
}

export function familyOf(kind: string): 'gh' | 'linear' | 'web' {
  if (kind.startsWith('gh-')) return 'gh'
  if (kind.startsWith('linear-')) return 'linear'
  return 'web'
}

// A pull request and an issue URL for one number are the same item.
export function itemKey(address: string): string {
  return address.replace(/^(https:\/\/github\.com\/[^/]+\/[^/]+)\/(?:pull|issues)\/(\d+)$/, '$1#$2')
}

export function refHref(text: string, context: RefContext): string | null {
  const ref = /^https?:/i.test(text.trim()) ? null : parseRef(text, context)
  return ref?.address ?? null
}

// The lookbehind's & and # keep `&#123;` entities from reading as references.
const PROSE_REF = /(?<![\w/.:&#-])(?:([A-Za-z0-9][\w.-]*\/[\w.-]+#\d+)|(#\d+)|([A-Z][A-Z0-9]{0,9}-\d+))(?![\w-])/g

export function linkRefs(prose: string, context: RefContext): string {
  return prose.replace(PROSE_REF, whole => {
    const href = refHref(whole, context)
    return href ? `[${whole}](${href})` : whole
  })
}
