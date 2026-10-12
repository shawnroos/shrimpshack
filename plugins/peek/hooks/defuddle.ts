import type { SourceIo } from './sources'

// Pinned: npm runs with install scripts off, and a new version is a reviewed bump, never a silent upgrade.
const VERSION = '0.19.4'
const INSTALL_TIMEOUT_MS = 90_000
const PARSE_TIMEOUT_MS = 15_000

let installing: Promise<boolean> | null = null
const failedSessions = new Set<string>()

async function ensureInstalled(io: SourceIo, dir: string, cli: string): Promise<boolean> {
  const found = await io.run(['test', '-f', cli]).catch(() => null)
  if (found?.exitCode === 0) return true
  const session = await io.sessionId().catch(() => '')
  if (failedSessions.has(session)) return false
  installing ??= io
    .run(['npm', 'install', '--prefix', dir, '--no-audit', '--no-fund', '--ignore-scripts', `defuddle@${VERSION}`], { timeoutMs: INSTALL_TIMEOUT_MS })
    .then(
      ran => ran.exitCode === 0,
      () => false,
    )
    .finally(() => {
      installing = null
    })
  const isInstalled = await installing
  if (!isInstalled) failedSessions.add(session)
  return isInstalled
}

function absoluteLinks(markdown: string, base: string): string {
  return markdown.replace(/(!?\[[^\]]*\]\()([^)\s]+)/g, (whole, open: string, target: string) => {
    if (target.startsWith('#') || /^[a-z][a-z0-9+.-]*:/i.test(target)) return whole
    try {
      return open + new URL(target, base).href
    } catch {
      return whole
    }
  })
}

// The readable body of a page, or null so the caller falls back to its own extractor.
export async function readable(io: SourceIo, html: string, url: string): Promise<string | null> {
  const home = await io.home().catch(() => undefined)
  if (!home) return null
  const dir = `${home}/.cache/claude-peek/defuddle-${VERSION}`
  const cli = `${dir}/node_modules/defuddle/dist/cli.js`
  if (!(await ensureInstalled(io, dir, cli))) return null
  const ran = await io.run(['node', cli, 'parse', '-', '--markdown', '--json'], { stdin: html, timeoutMs: PARSE_TIMEOUT_MS }).catch(() => null)
  if (ran?.exitCode !== 0) return null
  try {
    const content = (JSON.parse(ran.stdout) as { content?: unknown }).content
    return typeof content === 'string' && content.trim() ? absoluteLinks(content.trim(), url) : null
  } catch {
    return null
  }
}
