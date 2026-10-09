// The tuirealm toy's palette (herdr's gruvbox), so peek reads as the same family.
export const C = {
  appBg: '#1e1e1e',
  frame: '#262626',
  panelBg: '#282828',
  cardBg: '#262626',
  surface0: '#3c3836',
  surface1: '#504945',
  overlay0: '#928374',
  overlay1: '#a89984',
  text: '#ebdbb2',
  subtext0: '#d5c4a1',
  accent: '#d79921',
  yellow: '#fabd2f',
  peach: '#fe8019',
  teal: '#8ec07c',
  green: '#b8bb26',
  red: '#fb4934',
  blue: '#83a598',
  mauve: '#d3869b',
} as const

export const ICON = {
  markdown: '\u{f48a}',
  text: '\u{f121}',
  mermaid: '\u{f0645}',
  image: '\u{f02e9}',
  svg: '\u{f02e9}',
  html: '\u{f059f}',
  folder: '\u{f07b}',
  json: '\u{e60b}',
  toml: '\u{e6b2}',
  csv: '\u{f04eb}',
  up: '\u{f062}',
  worktree: '\u{f418}',
  repo: '\u{f401}',
  web: '\u{f059f}',
  file: '\u{f15b}',
  peek: '\u{f06e}',
  recent: '\u{f017}',
  gallery: '\u{f0c6c}',
} as const

export const KIND_COLOR: Record<string, string> = {
  markdown: C.yellow,
  text: C.blue,
  mermaid: C.mauve,
  image: C.teal,
  svg: C.teal,
  html: C.peach,
  folder: C.overlay1,
  json: C.yellow,
  toml: C.peach,
  csv: C.green,
  web: C.peach,
}

export function iconFor(kind: string | undefined): string {
  return ICON[(kind ?? 'file') as keyof typeof ICON] ?? ICON.file
}

export function colorFor(kind: string | undefined): string {
  return KIND_COLOR[kind ?? ''] ?? C.overlay1
}

// `─ LABEL ──────── right ─`, the toy's lane rule, sized to the pane.
export function ruleParts(label: string, right: string, columns: number) {
  const head = ` ${label.toUpperCase()} `
  const tail = right ? ` ${right} ` : ''
  const fill = Math.max(1, columns - 2 - head.length - tail.length)
  return { head, fill: '─'.repeat(fill), tail }
}

function mix(color: string, toward: string, amount: number): string {
  const parse = (hex: string) => [1, 3, 5].map(i => Number.parseInt(hex.slice(i, i + 2), 16))
  if (!/^#[0-9a-f]{6}$/i.test(color)) return color
  const from = parse(color)
  const to = parse(toward)
  return `#${from.map((value, i) => Math.round(value + ((to[i] ?? value) - value) * amount).toString(16).padStart(2, '0')).join('')}`
}

// The tuirealm toy's mute_behind: every colour 60% of the way to the background.
export function mute(color: string): string {
  return mix(color, C.appBg, 0.6)
}

export const MUTED = Object.fromEntries(
  Object.entries(C).map(([name, value]) => [name, name === 'appBg' ? value : mute(value)]),
) as { [K in keyof typeof C]: string }
