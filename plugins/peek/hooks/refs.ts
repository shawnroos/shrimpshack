export type GithubItemRef = { kind: 'gh-pr' | 'gh-issue'; address: string; owner: string; repo: string; number: number }
// An unresolved `#123` or `owner/repo#123`: only parseRef returns it, and loading resolves it to a pull request or an issue.
export type GithubNumberRef = { kind: 'gh-number'; address: string; owner: string; repo: string; number: number }
export type LinearIssueRef = { kind: 'linear-issue'; address: string; workspace: string; key: string }
export type LinearProjectRef = { kind: 'linear-project'; address: string; workspace: string; slug: string }
export type SlackThreadRef = { kind: 'slack-thread'; address: string; workspace: string; channel: string; ts: string }

export type Ref =
  | { kind: 'gh-repo'; address: string; owner: string; repo: string }
  | GithubItemRef
  | GithubNumberRef
  | LinearIssueRef
  | LinearProjectRef
  | SlackThreadRef
  | { kind: 'web'; address: string }

export type RefKind = Ref['kind']

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

export function githubRef<K extends 'gh-issue' | 'gh-pr' | 'gh-number'>(owner: string, repo: string, kind: K, number: number): Extract<Ref, { kind: K }> {
  const path = kind === 'gh-pr' ? 'pull' : 'issues'
  return { kind, address: `https://github.com/${owner}/${repo}/${path}/${number}`, owner, repo, number } as Extract<Ref, { kind: K }>
}

const SLACK_HOST = /^([a-z0-9][a-z0-9-]*)\.slack\.com$/
const SLACK_CHANNEL = /^[CDG][A-Z0-9]{2,}$/
const SLACK_P_TS = /^p(\d{10})(\d{6})$/
const SLACK_TS = /^(\d{10})\.(\d{6})$/

// A reply's link carries its parent in thread_ts; the thread is the item, so the address is always the parent's.
function slackThread(host: string, parts: string[], threadTs: string | null): SlackThreadRef | null {
  const workspace = SLACK_HOST.exec(host)?.[1]
  const [section, channel = '', message = ''] = parts
  if (!workspace || section !== 'archives' || parts.length !== 3 || !SLACK_CHANNEL.test(channel)) return null
  const own = SLACK_P_TS.exec(message)
  if (!own) return null
  const parent = (threadTs && SLACK_TS.exec(threadTs)) || own
  const ts = `${parent[1]}.${parent[2]}`
  return { kind: 'slack-thread', address: `https://${workspace}.slack.com/archives/${channel}/p${parent[1]}${parent[2]}`, workspace, channel, ts }
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
        return githubRef(owner, repo, section === 'pull' ? 'gh-pr' : 'gh-issue', Number(number))
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
  const slack = slackThread(host, parts, url.searchParams.get('thread_ts'))
  if (slack) return slack
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
  if (full?.[1] && full[2] && !GITHUB_RESERVED.has(full[1].toLowerCase())) return githubRef(full[1], full[2], 'gh-number', Number(full[3]))
  const bare = HASH_NUMBER.exec(text)
  const [owner, repo] = context.repo?.split('/') ?? []
  if (bare && owner && repo) return githubRef(owner, repo, 'gh-number', Number(bare[1]))
  const linear = LINEAR_ID.exec(text)
  const team = linear?.[1]?.toUpperCase()
  if (team && context.workspace && context.teamKeys?.includes(team)) {
    const key = `${team}-${linear?.[2]}`
    return { kind: 'linear-issue', address: `https://linear.app/${context.workspace}/issue/${key}`, workspace: context.workspace, key }
  }
  return null
}

export function familyOf(kind: string): 'gh' | 'linear' | 'slack' | 'web' {
  if (kind.startsWith('gh-')) return 'gh'
  if (kind.startsWith('linear-')) return 'linear'
  if (kind.startsWith('slack-')) return 'slack'
  return 'web'
}

const GITHUB_ITEM_URL = /^(https:\/\/github\.com\/[^/]+\/[^/]+)\/(?:pull|issues)\/(\d+)$/

// A pull request and an issue URL for one number are the same item, as are a Slack thread and a reply link inside it.
export function keyOf(ref: Ref): string {
  if (ref.kind === 'slack-thread') return ref.address
  if ('number' in ref) return `https://github.com/${ref.owner}/${ref.repo}#${ref.number}`
  // A web page whose URL has the pull/issue shape (an owner GitHub's parser rejects) still collapses, as itemKey always did.
  return ref.address.replace(GITHUB_ITEM_URL, '$1#$2')
}

// Not keyOf(parseRef(address)): stored group items and tombstones are keyed by their raw spelling (a /files link, `o/r#12`).
export function itemKey(address: string): string {
  if (/^https:\/\/[^/]+\.slack\.com\/archives\//i.test(address)) {
    const ref = parseRef(address)
    if (ref?.kind === 'slack-thread') return keyOf(ref)
  }
  return address.replace(GITHUB_ITEM_URL, '$1#$2')
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
