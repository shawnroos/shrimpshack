export type Kind = 'markdown' | 'image' | 'svg' | 'html' | 'mermaid' | 'json' | 'toml' | 'csv' | 'text'

const IMAGE_EXTS = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'tif', 'tiff', 'bmp']
const MARKDOWN_EXTS = ['md', 'markdown', 'mdx']
export const PATH_EXTS =
  'md|markdown|mdx|txt|png|jpe?g|gif|webp|heic|tiff?|bmp|svg|html?|mmd|mermaid|json|ya?ml|toml|ts|tsx|js|jsx|mjs|py|rs|go|sh|css|sql|csv|tsv|log'

export function extOf(path: string): string {
  const name = path.split('/').pop() ?? ''
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : ''
}

export function kindOf(path: string): Kind {
  const ext = extOf(path)
  if (MARKDOWN_EXTS.includes(ext)) return 'markdown'
  if (IMAGE_EXTS.includes(ext)) return 'image'
  if (ext === 'svg') return 'svg'
  if (ext === 'html' || ext === 'htm') return 'html'
  if (ext === 'mmd' || ext === 'mermaid') return 'mermaid'
  if (ext === 'json' || ext === 'jsonc' || ext === 'json5') return 'json'
  if (ext === 'toml') return 'toml'
  if (ext === 'csv' || ext === 'tsv') return 'csv'
  return 'text'
}

export function resolvePath(raw: string, cwd: string, home: string): string {
  if (raw.startsWith('~/')) return `${home}${raw.slice(1)}`
  const joined = raw.startsWith('/') ? raw : `${cwd}/${raw}`
  const out: string[] = []
  for (const part of joined.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') out.pop()
    else out.push(part)
  }
  return `/${out.join('/')}`
}

export function fileHref(abs: string, line?: number): string {
  return `file://${encodeURI(abs).replace(/[#?]/g, encodeURIComponent)}${line ? `#L${line}` : ''}`
}

export function parseHref(href: string): { path: string; line?: number } | null {
  if (!href.startsWith('file:')) return null
  const url = new URL(href)
  const match = /^#L(\d+)$/.exec(url.hash)
  return { path: decodeURIComponent(url.pathname), line: match ? Number(match[1]) : undefined }
}

export function shortPath(path: string, cwd: string, home: string): string {
  if (cwd && path.startsWith(`${cwd}/`)) return path.slice(cwd.length + 1)
  if (home && path.startsWith(`${home}/`)) return `~${path.slice(home.length)}`
  return path
}
