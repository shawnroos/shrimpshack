import type { Loaded, RemoteRecord } from '../../types'
import type { Captured } from '../capture'
import { htmlToMarkdown } from '../markdown'
import { readable } from '../defuddle'
import type { Ref } from '../refs'
import { hasCurl, httpDetail, httpText } from '../source-io'
import { fromHttpStatus } from './classify'
import { ok } from './result'
import type { Failed, SourceIo } from '../source-io'
import { bareHost, decodeEntities, parseUrl } from '../wire'
import { sessionMemo } from '../cache'
import { PAGE_FORMAT, pageStatus } from '../parsers/curl'
import { PROTO, fetchPicture } from '../net'

const MAX_PAGE = 4_194_304

type Head = { title?: string; description?: string; siteName?: string; image?: string; icons: string[] }

const favicons = sessionMemo<string | undefined>()

function decode(text: string): string {
  return decodeEntities(text, ['nbsp', 'lt', 'gt', 'quot', '#39', 'apos', 'amp'], true)
}

function clean(text: string | undefined): string | undefined {
  const tidy = text === undefined ? '' : decode(text).replace(/\s+/g, ' ').trim()
  return tidy || undefined
}

function attributes(tag: string): Record<string, string> {
  const found: Record<string, string> = {}
  for (const match of tag.matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g)) {
    const name = (match[1] ?? '').toLowerCase()
    if (!(name in found)) found[name] = match[2] ?? match[3] ?? match[4] ?? ''
  }
  return found
}

function resolve(raw: string | undefined, base: string): string | undefined {
  if (!raw?.trim()) return undefined
  return parseUrl(decode(raw.trim()), base)?.href
}

export function parseHead(html: string, pageUrl: string): Head {
  const end = html.search(/<\/head\s*>|<body[\s>]/i)
  const head = end >= 0 ? html.slice(0, end) : html.slice(0, 200_000)
  const metas = new Map<string, string>()
  for (const tag of head.match(/<meta\b[^>]*>/gi) ?? []) {
    const attrs = attributes(tag)
    const key = (attrs.property ?? attrs.name ?? '').toLowerCase()
    if (key && attrs.content !== undefined && !metas.has(key)) metas.set(key, attrs.content)
  }
  const iconLinks: string[] = []
  const touchLinks: string[] = []
  for (const tag of head.match(/<link\b[^>]*>/gi) ?? []) {
    const attrs = attributes(tag)
    const rel = (attrs.rel ?? '').toLowerCase().split(/\s+/)
    const href = resolve(attrs.href, pageUrl)
    if (!href) continue
    if (rel.includes('icon')) iconLinks.push(href)
    else if (rel.includes('apple-touch-icon') || rel.includes('apple-touch-icon-precomposed')) touchLinks.push(href)
  }
  // sips cannot draw SVG, so an SVG icon goes behind every raster one.
  const isSvg = (href: string) => /\.svg(?:$|[?#])/i.test(href)
  const fallback = resolve('/favicon.ico', pageUrl)
  const icons = [...iconLinks.filter(href => !isSvg(href)), ...touchLinks, ...(fallback ? [fallback] : []), ...iconLinks.filter(isSvg)]
  const title = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(head)?.[1]
  return {
    title: clean(metas.get('og:title')) ?? clean(metas.get('twitter:title')) ?? clean(title),
    description: clean(metas.get('og:description')) ?? clean(metas.get('twitter:description')) ?? clean(metas.get('description')),
    siteName: clean(metas.get('og:site_name')),
    image: resolve(metas.get('og:image') ?? metas.get('og:image:url') ?? metas.get('twitter:image') ?? metas.get('twitter:image:src'), pageUrl),
    icons: [...new Set(icons)],
  }
}


const FILE_PATH = /\.(md|mdx|markdown|txt|png|jpe?g|gif|webp|bmp|svg|csv|tsv|json|jsonc|ya?ml|toml|mmd|mermaid|ts|tsx|m?js|cjs|jsx|py|rb|sh|swift|rs|go|css|log|diff|patch)$/i
const VIDEO_EXT = /\.(mp4|m4v|webm|mov)$/i

// A blob URL is GitHub's HTML page around the file; the raw host serves the file itself.
export function remoteFileOf(address: string): { kind: 'file'; fetchUrl: string; ext: string } | { kind: 'video' } | null {
  const url = parseUrl(address)
  if (!url || (url.protocol !== 'http:' && url.protocol !== 'https:')) return null
  if (VIDEO_EXT.test(url.pathname)) return { kind: 'video' }
  const ext = FILE_PATH.exec(url.pathname)?.[1]?.toLowerCase()
  if (!ext) return null
  const blob = url.hostname === 'github.com' ? /^\/([^/]+)\/([^/]+)\/blob\/(.+)$/.exec(url.pathname) : null
  const fetchUrl = blob ? `https://raw.githubusercontent.com/${blob[1]}/${blob[2]}/${blob[3]}${url.search}` : url.href
  return { kind: 'file', fetchUrl, ext }
}

const MAX_MEDIA = 8
export const PICTURE_LINE = /^!\[([^\]]*)\]\(([^)\s]+)\)\s*$/
const VIDEO_TAG = /<video\b[^>]*>/gi

function attribute(tag: string, name: string): string | undefined {
  return new RegExp(`\\b${name}\\s*=\\s*["']([^"']+)["']`, 'i').exec(tag)?.[1]
}

// An empty attribute would resolve to the page itself.
function absolute(raw: string | undefined, base: string): string | undefined {
  return raw ? parseUrl(raw, base)?.href : undefined
}

function youtubeId(url: URL): string | undefined {
  if (url.hostname === 'youtu.be') return url.pathname.slice(1) || undefined
  if (/(^|\.)youtube\.com$/.test(url.hostname)) return url.searchParams.get('v') ?? /^\/embed\/([\w-]+)/.exec(url.pathname)?.[1]
  return undefined
}

// Defuddle keeps a <video> as raw HTML and drops its poster; it becomes a picture line here, its poster read from the page.
function withVideoLines(body: string, html: string, base: string): { body: string; posters: Map<string, string> } {
  const posters = new Map<string, string>()
  for (const tag of html.match(VIDEO_TAG) ?? []) {
    const src = absolute(attribute(tag, 'src'), base)
    const poster = absolute(attribute(tag, 'poster'), base)
    if (src && poster) posters.set(src, poster)
  }
  const lines = body.split('\n').map(line => {
    const tag = /^\s*<video\b[^>]*>/i.exec(line)?.[0]
    const src = tag ? absolute(attribute(tag, 'src'), base) : undefined
    return src ? `![video](${src})` : line
  })
  return { body: lines.join('\n'), posters }
}

const PICTURE_ROW = /^(?:!\[[^\]]*\]\([^)\s]+\)\s*){2,}$/
const PICTURE = /!\[[^\]]*\]\([^)\s]+\)/g

type Fetch = (url: string) => Promise<string | undefined>

// A gallery arrives as several pictures on one line. On a reader page images past the cap leave the body rather than
// print as raw URLs; in an issue or comment they stay, drawn as links, since the text is the author's.
async function pageMedia(texts: readonly string[], posters: Map<string, string>, fetch: Fetch | null, overCap: 'drop' | 'link') {
  const wanted: { key: string; thumb?: string; play?: string }[] = []
  let images = 0
  const bodies = texts.map(body => {
    const lines: string[] = []
    for (const raw of body.split('\n')) {
      const row = PICTURE_ROW.test(raw.trim()) ? (raw.match(PICTURE) ?? []) : [raw]
      for (const line of row) {
        const found = PICTURE_LINE.exec(line.trim())
        const url = found?.[2] ? parseUrl(found[2]) : null
        if (!found || !url) {
          lines.push(line)
          continue
        }
        const id = youtubeId(url)
        const isVideo = Boolean(id) || posters.has(url.href) || /^video$/i.test(found[1] ?? '')
        const isOver = !isVideo && ++images > MAX_MEDIA
        if (isOver && overCap === 'drop') continue
        if (row.length > 1) lines.push('')
        lines.push(line.trim())
        if (wanted.some(one => one.key === url.href)) continue
        const thumb = isOver ? undefined : id ? `https://i.ytimg.com/vi/${id}/hqdefault.jpg` : isVideo ? posters.get(url.href) : url.href
        wanted.push({ key: url.href, thumb, play: isVideo ? url.href : undefined })
      }
    }
    return lines.join('\n')
  })
  let budget = MAX_MEDIA
  const files = await Promise.all(wanted.map(one => (fetch && one.thumb && budget-- > 0 ? fetch(one.thumb) : Promise.resolve(undefined))))
  const media = wanted.length ? Object.fromEntries(wanted.map((one, i) => [one.key, { file: files[i], play: one.play }])) : undefined
  return { bodies, media }
}

const IMG_ROW = /^(?:<img\b[^>]*>\s*)+$/i
const BARE_URL = /^<?(https?:\/\/[^\s<>]+)>?$/

function isVideoUrl(url: URL): boolean {
  return Boolean(youtubeId(url)) || VIDEO_EXT.test(url.pathname) || (url.hostname === 'github.com' && url.pathname.startsWith('/user-attachments/assets/'))
}

// GitHub writes an upload as an <img> tag and a video upload as a bare URL on its own line; both become picture lines.
function withPictureLines(markdown: string): string {
  let fence = ''
  return markdown
    .split('\n')
    .map(line => {
      const marker = /^\s*(```|~~~)/.exec(line)?.[1]
      if (marker && (!fence || marker === fence)) fence = fence ? '' : marker
      if (fence || marker) return line
      const text = line.trim()
      if (IMG_ROW.test(text)) {
        const pictures = (text.match(/<img\b[^>]*>/gi) ?? []).map(tag => {
          const src = parseUrl(attribute(tag, 'src') ?? '')
          const isWeb = src?.protocol === 'https:' || src?.protocol === 'http:'
          return src && isWeb ? `![${(attribute(tag, 'alt') ?? '').replace(/[[\]]/g, '')}](${src.href})` : ''
        })
        return pictures.every(Boolean) ? pictures.join(' ') : line
      }
      const bare = BARE_URL.exec(text)?.[1]
      const url = bare ? parseUrl(bare) : null
      return url && isVideoUrl(url) ? `![video](${url.href})` : line
    })
    .join('\n')
}

// An open issue reloads every minute; the pictures in it are fetched once a session.
const remoteFiles = sessionMemo<string | undefined>({ max: 200 })

function sessionFetch(io: SourceIo, session: string): Fetch {
  return url => remoteFiles.get(`${session} ${url}`, () => fetchPicture(io, url))
}

export async function withRemoteMedia(io: SourceIo, record: RemoteRecord): Promise<RemoteRecord> {
  const shown = record.comments?.shown ?? []
  const texts = [record.body ?? '', ...shown.map(one => one.body)].map(withPictureLines)
  const fetch = (await hasCurl(io)) ? sessionFetch(io, await io.sessionId()) : null
  const { bodies, media } = await pageMedia(texts, new Map(), fetch, 'link')
  if (!media) return record
  const [body = '', ...comments] = bodies
  return {
    ...record,
    ...(record.body !== undefined ? { body } : {}),
    ...(record.comments ? { comments: { ...record.comments, shown: shown.map((one, i) => ({ ...one, body: comments[i] ?? one.body })) } } : {}),
    media: { ...record.media, ...media },
  }
}

async function firstIcon(io: SourceIo, icons: readonly string[]): Promise<string | undefined> {
  for (const icon of icons.slice(0, 3)) {
    const file = await fetchPicture(io, icon)
    if (file) return file
  }
  return undefined
}

async function faviconFor(io: SourceIo, host: string, icons: readonly string[]): Promise<string | undefined> {
  return favicons.get(`${await io.sessionId()} ${host}`, () => firstIcon(io, icons))
}

async function curlPage(io: SourceIo, url: string): Promise<{ ok: true; text: string; finalUrl: string } | Failed> {
  const argv = ['curl', '-sL', ...PROTO, '--max-redirs', '10', '--max-time', '15', '-w', PAGE_FORMAT, url]
  const ran = await io.run(argv, { timeoutMs: 20_000 }).catch(() => null)
  if (!ran) return { ok: false, failure: 'offline' }
  const marked = pageStatus(ran.stderr)
  const status = marked?.status ?? NaN
  const finalUrl = marked?.finalUrl || url
  const isUsable = status >= 200 && status < 300 && (ran.exitCode === 0 || ran.stdout.length > 0)
  if (!isUsable) return marked !== null && status > 0 ? { ok: false, failure: fromHttpStatus(status, 'page'), detail: httpDetail(status, finalUrl) } : { ok: false, failure: 'offline' }
  return { ok: true, text: ran.stdout, finalUrl }
}

export async function loadWeb(io: SourceIo, ref: Ref, now: number): Promise<Loaded> {
  const address = parseUrl(ref.address)
  if (!address || (address.protocol !== 'http:' && address.protocol !== 'https:')) return { ok: false, failure: 'query-bug' }
  const isCli = await hasCurl(io)
  const page = isCli ? await curlPage(io, address.href) : await httpText(io, address.href)
  if (!page.ok) return page
  const finalUrl = page.finalUrl ?? address.href
  const html = page.text.slice(0, MAX_PAGE)
  const head = parseHead(html, finalUrl)
  const host = bareHost(finalUrl) || address.hostname
  const [image, favicon, cleaned] = await Promise.all([
    isCli ? fetchPicture(io, head.image) : undefined,
    isCli ? faviconFor(io, host, head.icons) : undefined,
    readable(io, html, finalUrl),
  ])
  const video = cleaned ? withVideoLines(cleaned, html, finalUrl) : null
  const withMedia = video ? await pageMedia([video.body], video.posters, isCli ? url => fetchPicture(io, url) : null, 'drop') : null
  const media = withMedia?.media
  const record: RemoteRecord = {
    address: ref.address,
    kind: 'web',
    title: head.title ?? host,
    trail: [head.siteName ?? host],
    meta: [{ label: 'Host', value: host }],
    body: withMedia?.bodies[0] ?? htmlToMarkdown(html),
    ...(media ? { media } : {}),
    og: { title: head.title, description: head.description, siteName: head.siteName, image },
    favicon,
    browserUrl: finalUrl,
  }
  return ok(record, isCli ? 'cli' : 'api', now)
}

export function fromCapture(captured: Captured, ref: Ref): Loaded | null {
  const address = ref.address || captured.address
  const host = bareHost(address)
  if (!host) return null
  const body = typeof captured.result === 'string' ? captured.result : ''
  const heading = /^#{1,6}[ \t]+(.+?)[ \t#]*$/m.exec(body)?.[1]?.trim()
  const record: RemoteRecord = {
    address,
    kind: 'web',
    title: heading || host,
    trail: [host],
    meta: [{ label: 'Host', value: host }],
    body: body || undefined,
    browserUrl: address,
  }
  return ok(record, 'session', captured.at)
}
