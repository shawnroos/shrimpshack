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
  groups: '\u{f247}',
  'gh-pr': '\u{f407}',
  'gh-issue': '\u{f41b}',
  'gh-repo': '\u{f401}',
  'linear-issue': '\u{f0ae}',
  'linear-project': '\u{f0e8}',
  'slack-thread': '\u{f198}',
} as const

export const META_ICON: Record<string, string> = {
  State: '\u{f0765}',
  Status: '\u{f0765}',
  Author: '\u{f0004}',
  Assignee: '\u{f0004}',
  Assignees: '\u{f0849}',
  Lead: '\u{f1a7d}',
  Labels: '\u{f04f9}',
  Priority: '\u{f023b}',
  Project: '\u{f0e8}',
  Milestone: '\u{f04fe}',
  Parent: '\u{f0645}',
  Branch: '\u{f062c}',
  'Default branch': '\u{f062c}',
  Review: '\u{f0208}',
  'Merge state': '\u{f419}',
  Merged: '\u{f419}',
  Created: '\u{f00f3}',
  Updated: '\u{f0954}',
  Start: '\u{f00f3}',
  Target: '\u{f04fe}',
  Completed: '\u{f00f2}',
  Closed: '\u{f00f2}',
  Canceled: '\u{f00f4}',
  Progress: '\u{f0995}',
  Description: '\u{f09a8}',
  Language: '\u{f121}',
  Stars: '\u{f005}',
  Host: '\u{f0ac}',
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

// Red reads as a failure and accent is the section-rule colour, so neither names a person.
const SPEAKER_COLORS = [C.yellow, C.peach, C.teal, C.green, C.blue, C.mauve]

export function speakerColor(id: string): string {
  let hash = 0x811c9dc5
  for (const char of id) hash = Math.imul(hash ^ (char.codePointAt(0) ?? 0), 0x01000193) >>> 0
  return SPEAKER_COLORS[hash % SPEAKER_COLORS.length] ?? C.text
}
