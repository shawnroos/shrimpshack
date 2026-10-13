import type { SourceIo } from './source-io'
import { hasCurl } from './source-io'
import { DOWNLOAD_FORMAT, downloadStatus } from './parsers/curl'
import { parseUrl } from './wire'

export const SCRATCH = '/tmp/claude-peek'
// --globoff: curl otherwise expands {a,b} and [1-2] in a URL into hosts fetchable() never saw.
export const PROTO = ['--globoff', '--proto', '=http,https', '--proto-redir', '=http,https']
const DSCACHEUTIL = '/usr/bin/dscacheutil'
const HOSTNAME = /^(?:[a-z0-9.-]+|\[[0-9a-f:.]+\])$/i
const MAX_IMAGE_HOPS = 5
const PICTURE_EXT = /\.(png|ico|jpe?g|gif|webp|svg|bmp)$/i
export const IMAGE_MIME_EXT: Record<string, string> = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp' }

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
  const url = raw ? parseUrl(raw) : null
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
  // Every address passed the private-host check; IPv4 first, since a machine without an IPv6 route cannot connect over it.
  const chosen = addresses.find(address => ipv4(address) !== null) ?? addresses[0] ?? ''
  const port = url.port || (url.protocol === 'https:' ? '443' : '80')
  // Pins curl to the address checked above, so a second DNS answer cannot swap in a private one.
  return ['--resolve', `${host}:${port}:${chosen.includes(':') ? `[${chosen}]` : chosen}`]
}

async function sha1(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('')
}

async function fetchToScratch(io: SourceIo, raw: string | undefined, ext: string, maxSeconds: number): Promise<{ file: string; type?: string } | undefined> {
  const first = fetchable(raw)
  if (!first) return undefined
  const file = `${SCRATCH}/web-${(await sha1(first.href)).slice(0, 12)}.${ext}`
  const made = await io.run(['mkdir', '-p', SCRATCH], { timeoutMs: 5000 }).catch(() => null)
  if (!made || made.exitCode !== 0) return undefined
  let url: URL | null = first
  // curl's own -L would follow a redirect to a private host; each hop is checked here instead.
  for (let hop = 0; url && hop <= MAX_IMAGE_HOPS; hop++) {
    const pin = await pinnedAddress(io, url)
    if (!pin) return undefined
    const argv = ['curl', '-sf', ...PROTO, ...pin, '--max-redirs', '0', '--max-time', String(maxSeconds), '--max-filesize', '10000000', '-o', file, '-w', DOWNLOAD_FORMAT, url.href]
    const ran = await io.run(argv, { timeoutMs: (maxSeconds + 5) * 1000 }).catch(() => null)
    if (!ran || ran.exitCode !== 0) return undefined
    const { status, size, redirect, type } = downloadStatus(ran.stdout, ran.stderr)
    if (status >= 200 && status < 300) return size > 0 ? { file, type } : undefined
    if (status < 300 || status >= 400) return undefined
    url = redirect ? fetchable(parseUrl(redirect, url.href)?.href) : null
  }
  return undefined
}

export async function fetchPicture(io: SourceIo, raw: string | undefined): Promise<string | undefined> {
  const ext = PICTURE_EXT.exec(parseUrl(raw ?? '')?.pathname ?? '')?.[1]?.toLowerCase() ?? 'img'
  return (await fetchToScratch(io, raw, ext, 10))?.file
}

export async function downloadFile(io: SourceIo, url: string, ext: string): Promise<{ file: string; type?: string } | undefined> {
  if (!(await hasCurl(io))) return undefined
  return fetchToScratch(io, url, /^[a-z0-9]{1,8}$/i.test(ext) ? ext.toLowerCase() : 'txt', 20)
}

export async function downloadImage(io: SourceIo, url: string, ext: string): Promise<string | undefined> {
  const got = await downloadFile(io, url, ext)
  return got && (!got.type || got.type.startsWith('image/')) ? got.file : undefined
}
