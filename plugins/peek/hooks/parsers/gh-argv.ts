import { githubAddressRef, parseRef } from '../refs'
import type { Ref } from '../refs'
import { asPositiveInt } from '../wire'

const SHELL_META = /[;&|`\n\r<>]|\$\(/
const GH_API_WRITE = /^(?:-[^-]*[XfF]|--(?:method|field|raw-field|input)(?:=|$))/

function words(command: string): string[] | null {
  const out: string[] = []
  const pattern = /'([^']*)'|"([^"\\$]*)"|(\S+)/g
  for (const match of command.trim().matchAll(pattern)) {
    const token = match[1] ?? match[2] ?? match[3] ?? ''
    if (match[3] && /['"\\]/.test(token)) return null
    out.push(token)
  }
  return out
}

export type GhRead = { sub: 'pr' | 'issue' | 'repo' | 'api'; verb?: string; argv: string[] }

export function ghRead(command: unknown): GhRead | null {
  if (typeof command !== 'string' || SHELL_META.test(command)) return null
  if (!/^\s*(?:gh\s|'gh'|"gh")/.test(command)) return null
  const argv = words(command)
  if (!argv || argv[0] !== 'gh') return null
  const [, sub, verb] = argv
  if (sub === 'api') return argv.slice(2).some(token => GH_API_WRITE.test(token)) ? null : { sub, argv }
  const hasJson = argv.some(token => token === '--json' || token.startsWith('--json='))
  if (!hasJson) return null
  if ((sub === 'pr' || sub === 'issue') && (verb === 'view' || verb === 'list')) return { sub, verb, argv }
  if (sub === 'repo' && verb === 'view') return { sub, verb, argv }
  return null
}

function flagValue(argv: string[], long: string, short: string): string | undefined {
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i] ?? ''
    if (token === long || token === short) return argv[i + 1]
    if (token.startsWith(`${long}=`)) return token.slice(long.length + 1)
  }
  return undefined
}

export function ghSource(gh: GhRead): Ref | null {
  if (gh.sub === 'api') {
    const path = gh.argv.slice(2).find(token => !token.startsWith('-') && /^\/?repos\//.test(token))
    const match = path ? /^\/?repos\/([^/]+)\/([^/?]+)(?:\/(pulls|issues)\/(\d+))?\/?(?:\?.*)?$/.exec(path) : null
    if (!match) return null
    const [, owner, repo, section, number] = match
    if (!section) return parseRef(`https://github.com/${owner}/${repo}`)
    return githubAddressRef(owner, repo, Number(number), section === 'pulls')
  }
  if (gh.verb !== 'view') return null
  const positional = gh.argv.slice(3).find((token, i, rest) => !token.startsWith('-') && !/^-/.test(rest[i - 1] ?? ''))
  const repo = flagValue(gh.argv, '--repo', '-R')
  if (gh.sub === 'repo') {
    const target = positional ?? repo
    if (!target) return null
    return parseRef(/^https?:/.test(target) ? target : `https://github.com/${target}`)
  }
  if (!positional) return null
  if (/^https?:/.test(positional)) return parseRef(positional)
  const number = asPositiveInt(positional.replace(/^#/, ''))
  const [owner, name] = repo?.split('/') ?? []
  return number !== null ? githubAddressRef(owner, name, number, gh.sub === 'pr') : null
}
