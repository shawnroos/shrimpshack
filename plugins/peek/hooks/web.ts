import type { Loaded, RemoteRecord } from '../types'
import type { Captured } from './capture'
import { htmlToMarkdown } from './lib'
import type { Ref } from './refs'
import { hasCurl, httpFailure, httpText } from './sources'
import type { Failed, SourceIo } from './sources'

const SCRATCH = '/tmp/claude-peek'
// The engine cuts stdout at 4 MiB, so the status line rides on stderr where the cut cannot drop it.
const MARKER = '__peek_curl__ '
const MAX_PAGE = 4_194_304
// --globoff: curl otherwise expands {a,b} and [1-2] in a URL into hosts fetchable() never saw.
const PROTO = ['--globoff', '--proto', '=http,https', '--proto-redir', '=http,https']
const DSCACHEUTIL = '/usr/bin/dscacheutil'
const HOSTNAME = /^(?:[a-z0-9.-]+|\[[0-9a-f:.]+\])$/i
const MAX_IMAGE_HOPS = 5
const IMAGE_EXT = /\.(png|ico|jpe?g|gif|webp|svg|bmp)$/i

type Head = { title?: string; description?: string; siteName?: string; image?: string; icons: string[] }

const favicons = new Map<string, Promise<string | undefined>>()

function decode(text: string): string {
  return text
    .replace(/&#x([0-9a-f]+);/gi, (whole, hex: string) => safeChar(Number.parseInt(hex, 16)) ?? whole)
    .replace(/&#(\d+);/g, (whole, dec: string) => safeChar(Number.parseInt(dec, 10)) ?? whole)
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&amp;/g, '&')
}

function safeChar(code: number): string | undefined {
  return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : undefined
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

function safeParse(raw: string, base?: string): URL | null {
  try {
    return new URL(raw, base)
  } catch {
    return null
  }
}

function resolve(raw: string | undefined, base: string): string | undefined {
  if (!raw?.trim()) return undefined
  return safeParse(decode(raw.trim()), base)?.href
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

function ipv4(host: string): number[] | null {
  const parts = host.split('.')
  if (parts.length !== 4 || !parts.every(part => /^\d{1,3}$/.test(part))) return null
  const octets = parts.map(Number)
  return octets.every(octet => octet <= 255) ? octets : null
}

function isPrivateV4([a = 0, b = 0]: number[]): boolean {
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127)
}

function ipv6(host: string): number[] | null {
  if (!host.includes(':') || !/^[0-9a-f:.]+$/i.test(host)) return null
  let text = host
  const dotted = /:(\d+\.\d+\.\d+\.\d+)$/.exec(text)
  if (dotted?.[1]) {
    const v4 = ipv4(dotted[1])
    if (!v4) return null
    const [a = 0, b = 0, c = 0, d = 0] = v4
    text = `${text.slice(0, -dotted[1].length)}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`
  }
  const halves = text.split('::')
  if (halves.length > 2) return null
  const parse = (part: string | undefined) => (part ? part.split(':').map(group => Number.parseInt(group, 16)) : [])
  const left = parse(halves[0])
  const right = parse(halves[1])
  const fill = halves.length === 2 ? 8 - left.length - right.length : 0
  const groups = [...left, ...Array<number>(Math.max(fill, 0)).fill(0), ...right]
  return groups.length === 8 && groups.every(group => Number.isInteger(group) && group >= 0 && group <= 0xffff) ? groups : null
}

export function isPrivateHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '')
  if (!host || host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) return true
  const v4 = ipv4(host)
  if (v4) return isPrivateV4(v4)
  const v6 = ipv6(host)
  if (!v6) return false
  const [first = 0] = v6
  if (v6.slice(0, 5).every(group => group === 0) && (v6[5] === 0xffff || v6[5] === 0)) {
    const high = v6[6] ?? 0
    const low = v6[7] ?? 0
    if (v6[5] === 0xffff || high !== 0) return isPrivateV4([high >> 8, high & 0xff, low >> 8, low & 0xff])
    return low <= 1
  }
  return (first & 0xfe00) === 0xfc00 || (first & 0xffc0) === 0xfe80
}

function fetchable(raw: string | undefined): URL | null {
  const url = raw ? safeParse(raw) : null
  if (!url) return null
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null
  if (!HOSTNAME.test(url.hostname)) return null
  return isPrivateHost(url.hostname) ? null : url
}

function isIpLiteral(hostname: string): boolean {
  return ipv4(hostname) !== null || (hostname.startsWith('[') && ipv6(hostname.slice(1, -1)) !== null)
}

async function pinnedAddress(io: SourceIo, url: URL): Promise<string[] | null> {
  const host = url.hostname
  if (isIpLiteral(host)) return []
  const ran = await io.run([DSCACHEUTIL, '-q', 'host', '-a', 'name', host], { timeoutMs: 3000 }).catch(() => null)
  if (!ran || ran.exitCode !== 0) return null
  const addresses = [...ran.stdout.matchAll(/^\s*(?:ip_address|ipv6_address):\s*(\S+)\s*$/gm)].map(match => match[1] ?? '')
  if (addresses.length === 0) return null
  if (addresses.some(address => (ipv4(address) === null && ipv6(address) === null) || isPrivateHost(address))) return null
  const [chosen = ''] = addresses
  const port = url.port || (url.protocol === 'https:' ? '443' : '80')
  // Pins curl to the address checked above, so a second DNS answer cannot swap in a private one.
  return ['--resolve', `${host}:${port}:${chosen.includes(':') ? `[${chosen}]` : chosen}`]
}

async function sha1(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('')
}

async function download(io: SourceIo, raw: string | undefined): Promise<string | undefined> {
  const first = fetchable(raw)
  if (!first) return undefined
  const ext = IMAGE_EXT.exec(first.pathname)?.[1]?.toLowerCase() ?? 'img'
  const file = `${SCRATCH}/web-${(await sha1(first.href)).slice(0, 12)}.${ext}`
  const made = await io.run(['mkdir', '-p', SCRATCH], { timeoutMs: 5000 }).catch(() => null)
  if (!made || made.exitCode !== 0) return undefined
  let url: URL | null = first
  // curl's own -L would follow a redirect to a private host; each hop is checked here instead.
  for (let hop = 0; url && hop <= MAX_IMAGE_HOPS; hop++) {
    const pin = await pinnedAddress(io, url)
    if (!pin) return undefined
    const argv = ['curl', '-sf', ...PROTO, ...pin, '--max-redirs', '0', '--max-time', '10', '--max-filesize', '10000000', '-o', file, '-w', '%{http_code} %{size_download} %{redirect_url}', url.href]
    const ran = await io.run(argv, { timeoutMs: 15_000 }).catch(() => null)
    if (!ran || ran.exitCode !== 0) return undefined
    const [code = '', size = '', ...rest] = ran.stdout.trim().split(' ')
    const status = Number.parseInt(code, 10)
    if (status >= 200 && status < 300) return Number.parseInt(size, 10) > 0 ? file : undefined
    if (status < 300 || status >= 400) return undefined
    const next: string = rest.join(' ')
    url = next ? fetchable(safeParse(next, url.href)?.href) : null
  }
  return undefined
}

async function firstIcon(io: SourceIo, icons: readonly string[]): Promise<string | undefined> {
  for (const icon of icons.slice(0, 3)) {
    const file = await download(io, icon)
    if (file) return file
  }
  return undefined
}

async function faviconFor(io: SourceIo, host: string, icons: readonly string[]): Promise<string | undefined> {
  const key = `${await io.sessionId()} ${host}`
  const known = favicons.get(key)
  if (known) return known
  const pending = firstIcon(io, icons)
  favicons.set(key, pending)
  return pending
}

async function curlPage(io: SourceIo, url: string): Promise<{ ok: true; text: string; finalUrl: string } | Failed> {
  const argv = ['curl', '-sL', ...PROTO, '--max-redirs', '10', '--max-time', '15', '-w', `%{stderr}${MARKER}%{http_code} %{url_effective}`, url]
  const ran = await io.run(argv, { timeoutMs: 20_000 }).catch(() => null)
  if (!ran) return { ok: false, failure: 'offline' }
  const cut = ran.stderr.lastIndexOf(MARKER)
  const [code = '', ...rest] = cut >= 0 ? ran.stderr.slice(cut + MARKER.length).trim().split(' ') : []
  const status = Number.parseInt(code, 10)
  const isUsable = status >= 200 && status < 300 && (ran.exitCode === 0 || ran.stdout.length > 0)
  if (!isUsable) return { ok: false, failure: cut >= 0 && status > 0 ? httpFailure(status) : 'offline' }
  return { ok: true, text: ran.stdout, finalUrl: rest.join(' ') || url }
}

function hostOf(url: string): string | undefined {
  return safeParse(url)?.hostname.replace(/^www\./, '') || undefined
}

export async function loadWeb(io: SourceIo, ref: Ref, now: number): Promise<Loaded> {
  const address = safeParse(ref.address)
  if (!address || (address.protocol !== 'http:' && address.protocol !== 'https:')) return { ok: false, failure: 'query-bug' }
  const isCli = await hasCurl(io)
  const page = isCli ? await curlPage(io, address.href) : await httpText(io, address.href)
  if (!page.ok) return page
  const finalUrl = page.finalUrl ?? address.href
  const html = page.text.slice(0, MAX_PAGE)
  const head = parseHead(html, finalUrl)
  const host = hostOf(finalUrl) ?? address.hostname
  const [image, favicon] = isCli ? await Promise.all([download(io, head.image), faviconFor(io, host, head.icons)]) : [undefined, undefined]
  const record: RemoteRecord = {
    address: ref.address,
    kind: 'web',
    title: head.title ?? host,
    trail: [head.siteName ?? host],
    meta: [{ label: 'Host', value: host }],
    body: htmlToMarkdown(html),
    og: { title: head.title, description: head.description, siteName: head.siteName, image },
    favicon,
    browserUrl: finalUrl,
  }
  return { ok: true, record, tier: isCli ? 'cli' : 'api', fetchedAt: now }
}

export function fromCapture(captured: Captured, ref: Ref): Loaded | null {
  const address = ref.address || captured.address
  const host = hostOf(address)
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
  return { ok: true, record, tier: 'session', fetchedAt: captured.at }
}
