import type { PropScalar, PropValue } from '../../types'
import { readFrontmatter } from '../frontmatter'

export const PROP_KINDS = ['text', 'choice', 'date', 'ref', 'links'] as const
export type PropKind = (typeof PROP_KINDS)[number]
export const BLOCK_LANGUAGES = ['peek-cards', 'peek-list', 'peek-tree', 'peek-sections', 'peek-board', 'peek-focus', 'peek-header', 'peek-fields', 'peek-media', 'peek-comments'] as const
export type BlockLanguage = (typeof BLOCK_LANGUAGES)[number]
export const LAYOUTS = ['cards', 'list', 'tree', 'sections', 'board', 'focus'] as const
export type Layout = (typeof LAYOUTS)[number]
export const LAYOUT_PLACES = ['page', 'group', 'recent', 'gallery'] as const
export type LayoutPlace = (typeof LAYOUT_PLACES)[number]
export const COLOR_NAMES = ['red', 'yellow', 'green', 'teal', 'blue', 'mauve', 'peach', 'accent', 'text', 'subtext', 'gray', 'muted'] as const
export type ColorName = (typeof COLOR_NAMES)[number]

export type PropDecl = { kind: PropKind; isRequired: boolean; values?: string[] }
export type MatchRule = { folder?: string; prop?: { name: string; equals: PropScalar }; record?: string; recipe?: string }
export type RequiresWhen = { when: Record<string, PropScalar>; props: 'all' | string[] }
export type Block = { language: BlockLanguage; line: number; options: Record<string, string>; text: string }
export type Definition = {
  type: string
  file: string
  match: MatchRule
  needsRecipe: boolean
  props: Record<string, PropDecl>
  requiresWhen?: RequiresWhen
  layoutDefault: { [P in LayoutPlace]?: Layout }
  colors: Record<string, Record<string, ColorName>>
  icons: Record<string, string>
  template: string
  templateStartLine: number
  blocks: Block[]
}
export type DefinitionProblem = { file: string; path: string; message: string }
// A failed check keeps its match rule when that part read cleanly, so its problems can show on the pages it would take.
export type DefinitionCheck = { ok: true; definition: Definition } | { ok: false; problems: DefinitionProblem[]; match?: MatchRule }
export type MatchDoc = { path?: string; props?: Record<string, PropValue>; recordKind?: string }

export const DEFINITION_CAPS = { problems: 50, props: 40, values: 40, blocks: 40 }

const TOP_KEYS = ['type', 'match', 'props', 'requires_when', 'layout_default', 'colors', 'icons'] as const
const MATCH_KEYS = ['folder', 'prop', 'equals', 'record', 'recipe'] as const
const PROP_KEYS = ['kind', 'required', 'values'] as const
const TYPE_NAME = /^[a-z0-9][a-z0-9-]{0,39}$/
const KEY_NAME = /^[A-Za-z_][A-Za-z0-9_]{0,31}$/
const FOLDER_SEGMENT = /^[\w.-]+$/
const LABEL_KEY = /^[a-z][a-z0-9_-]{0,39}$/
const ICON = /^[^\s\u0000-\u001F\u007F-\u009F]{1,4}$/u
const PLACEHOLDER = /^\{\{[A-Za-z_][\w-]{0,31}\}\}$/
// An allowlist of token shapes: anything that is not one of these, a loop, an expression or code alike, is refused.
const OPTION = /^([A-Za-z_][\w-]{0,31})=([\w.:/,@#-]{1,200}|\{\{[A-Za-z_][\w-]{0,31}\}\})$/
const NO_CODE = 'definitions hold no loops, expressions or code'
const UNSAFE = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/g
const LINE_BREAKS = /[\t\n\r\u2028\u2029]/g
const SHOWN_CAP = 80

type Sink = DefinitionProblem[]
type Report = (path: string, message: string) => void

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value)
const isScalar = (value: unknown): value is PropScalar => value === null || ['string', 'number', 'boolean'].includes(typeof value)
const join = (path: string, key: string) => (path ? `${path}.${key}` : key)

function kindOf(value: unknown): string {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'a list'
  return typeof value === 'string' ? 'text' : typeof value
}

// JSON.stringify escapes C0 but leaves C1 and bidi controls raw, so the cleaning runs after it.
function shown(value: unknown): string {
  const quoted = (JSON.stringify(value) ?? 'nothing').replace(LINE_BREAKS, ' ').replace(UNSAFE, '')
  return quoted.length > SHOWN_CAP ? `${quoted.slice(0, SHOWN_CAP - 1)}…` : quoted
}

function optional<K extends string, V>(key: K, value: V | undefined): { [P in K]?: V } {
  return (value === undefined ? {} : { [key]: value }) as { [P in K]?: V }
}

// Unlike page.ts's record(), the extra keys are named but the known ones are still checked, so one stray key does
// not hide every other problem in the file.
function record(report: Report, raw: unknown, path: string, what: string, keys: readonly string[]): Record<string, unknown> | undefined {
  if (!isRecord(raw)) {
    report(path, `${what} must be a map, got ${kindOf(raw)}`)
    return undefined
  }
  for (const key of Object.keys(raw).filter(one => !keys.includes(one))) {
    report(join(path, KEY_NAME.test(key) ? key : '<key>'), `${shown(key)} is not part of ${what}; it takes ${keys.join(', ')}`)
  }
  return raw
}

function word(report: Report, raw: unknown, path: string, pattern: RegExp, what: string): string | undefined {
  if (typeof raw !== 'string') {
    report(path, raw === undefined || raw === null ? 'is required' : `must be text, got ${kindOf(raw)}`)
    return undefined
  }
  if (!pattern.test(raw)) {
    report(path, `${shown(raw)} is not ${what}`)
    return undefined
  }
  return raw
}

function oneOf<T extends string>(report: Report, raw: unknown, path: string, allowed: readonly T[], what: string): T | undefined {
  if (typeof raw === 'string' && (allowed as readonly string[]).includes(raw)) return raw as T
  report(path, raw === undefined ? 'is required' : `${shown(raw)} is not ${what}; use ${allowed.join(', ')}`)
  return undefined
}

function folderRule(report: Report, raw: unknown, path: string): string | undefined {
  const folder = word(report, raw, path, /^[^/]/, 'a folder inside the repo')
  if (folder === undefined) return undefined
  const segments = folder.replace(/\/+$/, '').split('/')
  if (segments.some(one => !FOLDER_SEGMENT.test(one) || one === '.' || one === '..')) {
    report(path, `${shown(folder)} is not a plain folder path; use names joined by /`)
    return undefined
  }
  return segments.join('/')
}

function matchRule(report: Report, raw: unknown): MatchRule | undefined {
  if (raw === undefined || raw === null) {
    report('match', 'is required')
    return undefined
  }
  const one = record(report, raw, 'match', 'match', MATCH_KEYS)
  if (!one) return undefined
  const has = (key: string) => one[key] !== undefined
  if ((has('record') || has('recipe')) && MATCH_KEYS.filter(has).length > 1) {
    report('match', 'a record or recipe rule stands alone')
    return undefined
  }
  if (has('equals') !== has('prop')) {
    report('match', 'prop and equals go together')
    return undefined
  }
  if (!has('folder') && !has('prop') && !has('record') && !has('recipe')) {
    report('match', 'needs a rule: folder, prop with equals, record or recipe')
    return undefined
  }
  const folder = has('folder') ? folderRule(report, one.folder, 'match.folder') : undefined
  const name = has('prop') ? word(report, one.prop, 'match.prop', KEY_NAME, 'a prop name') : undefined
  if (has('equals') && !isScalar(one.equals)) report('match.equals', `must be one value, got ${kindOf(one.equals)}`)
  const recordKind = has('record') ? word(report, one.record, 'match.record', TYPE_NAME, 'a record kind') : undefined
  const recipe = has('recipe') ? word(report, one.recipe, 'match.recipe', TYPE_NAME, 'a recipe id') : undefined
  const prop = name !== undefined && isScalar(one.equals) ? { name, equals: one.equals } : undefined
  return { ...optional('folder', folder), ...optional('prop', prop), ...optional('record', recordKind), ...optional('recipe', recipe) }
}

function propDecl(report: Report, raw: unknown, path: string): PropDecl | undefined {
  if (!isRecord(raw)) {
    report(path, `a prop must be a map like { kind: text }, got ${kindOf(raw)}`)
    return undefined
  }
  const one = record(report, raw, path, 'a prop', PROP_KEYS)
  if (!one) return undefined
  const kind = oneOf(report, one.kind, join(path, 'kind'), PROP_KINDS, 'a prop kind')
  if (one.required !== undefined && typeof one.required !== 'boolean') report(join(path, 'required'), `must be true or false, got ${kindOf(one.required)}`)
  let values: string[] | undefined
  if (kind === 'choice' && one.values === undefined) report(join(path, 'values'), 'is required for a choice prop')
  else if (kind !== undefined && kind !== 'choice' && one.values !== undefined) report(join(path, 'values'), 'is only for a choice prop')
  else if (one.values !== undefined) {
    const list = one.values
    if (!Array.isArray(list) || list.length === 0 || list.length > DEFINITION_CAPS.values) {
      report(join(path, 'values'), `must be a list of 1 to ${DEFINITION_CAPS.values} values`)
    } else {
      values = list.map(String)
    }
  }
  if (kind === undefined) return undefined
  return { kind, isRequired: one.required === true, ...optional('values', values) }
}

function propsOf(report: Report, raw: unknown): Record<string, PropDecl> {
  const props: Record<string, PropDecl> = {}
  if (raw === undefined || raw === null) return props
  if (!isRecord(raw)) {
    report('props', `must be a map of prop names, got ${kindOf(raw)}`)
    return props
  }
  const names = Object.keys(raw)
  if (names.length > DEFINITION_CAPS.props) report('props', `declares ${names.length} props; the most is ${DEFINITION_CAPS.props}`)
  for (const name of names.slice(0, DEFINITION_CAPS.props)) {
    if (!KEY_NAME.test(name)) {
      report('props.<key>', `${shown(name)} is not a prop name`)
      continue
    }
    const decl = propDecl(report, raw[name], `props.${name}`)
    if (decl) props[name] = decl
  }
  return props
}

function requiresWhenOf(report: Report, raw: unknown, props: Record<string, PropDecl>): RequiresWhen | undefined {
  if (raw === undefined || raw === null) return undefined
  if (!isRecord(raw)) {
    report('requires_when', `must be a map like { isTask: true, all: true }, got ${kindOf(raw)}`)
    return undefined
  }
  const when: Record<string, PropScalar> = {}
  for (const [key, value] of Object.entries(raw)) {
    if (key === 'all' || key === 'props') continue
    if (!KEY_NAME.test(key) || !isScalar(value)) report(join('requires_when', KEY_NAME.test(key) ? key : '<key>'), 'a condition is a prop name and one value')
    else when[key] = value
  }
  if (Object.keys(when).length === 0) report('requires_when', 'needs at least one condition, such as isTask: true')
  if ((raw.all === undefined) === (raw.props === undefined)) {
    report('requires_when', 'takes either all: true or props: [names]')
    return undefined
  }
  if (raw.all !== undefined) {
    if (raw.all !== true) report('requires_when.all', 'must be true; list the props instead')
    return raw.all === true ? { when, props: 'all' } : undefined
  }
  if (!Array.isArray(raw.props) || raw.props.length === 0) {
    report('requires_when.props', 'must be a list of declared props')
    return undefined
  }
  const listed = raw.props.map(String)
  const unknown = listed.filter(name => !Object.hasOwn(props, name))
  for (const name of unknown) report('requires_when.props', `${shown(name)} is not a declared prop`)
  return unknown.length ? undefined : { when, props: listed }
}

function layoutsOf(report: Report, raw: unknown): { [P in LayoutPlace]?: Layout } {
  if (raw === undefined || raw === null) return {}
  const one = record(report, raw, 'layout_default', 'layout_default', LAYOUT_PLACES)
  if (!one) return {}
  const layouts: { [P in LayoutPlace]?: Layout } = {}
  for (const place of LAYOUT_PLACES) {
    if (one[place] === undefined) continue
    const layout = oneOf(report, one[place], join('layout_default', place), LAYOUTS, 'a layout')
    if (layout) layouts[place] = layout
  }
  return layouts
}

function colorsOf(report: Report, raw: unknown, props: Record<string, PropDecl>): Record<string, Record<string, ColorName>> {
  const colors: Record<string, Record<string, ColorName>> = {}
  if (raw === undefined || raw === null) return colors
  if (!isRecord(raw)) {
    report('colors', `must map a prop to { value: color }, got ${kindOf(raw)}`)
    return colors
  }
  for (const [prop, map] of Object.entries(raw)) {
    const path = join('colors', KEY_NAME.test(prop) ? prop : '<key>')
    if (!Object.hasOwn(props, prop)) {
      report(path, `${shown(prop)} is not a declared prop`)
      continue
    }
    if (!isRecord(map)) {
      report(path, `must map a value to a color, got ${kindOf(map)}`)
      continue
    }
    const each: Record<string, ColorName> = {}
    for (const [value, color] of Object.entries(map)) {
      const name = oneOf(report, color, join(path, value), COLOR_NAMES, 'a color peek draws')
      if (name) each[value] = name
    }
    colors[prop] = each
  }
  return colors
}

function iconsOf(report: Report, raw: unknown): Record<string, string> {
  const icons: Record<string, string> = {}
  if (raw === undefined || raw === null) return icons
  if (!isRecord(raw)) {
    report('icons', `must map a field label to an icon, got ${kindOf(raw)}`)
    return icons
  }
  for (const [label, icon] of Object.entries(raw)) {
    const path = join('icons', LABEL_KEY.test(label) ? label : '<key>')
    if (!LABEL_KEY.test(label)) {
      report(path, `${shown(label)} is not a field label; write it lowercase with - for spaces`)
      continue
    }
    const glyph = word(report, icon, path, ICON, 'an icon; use one to four characters')
    if (glyph) icons[label] = glyph
  }
  return icons
}

function placeholderProblems(report: Report, line: string, at: number): void {
  for (const found of line.matchAll(/\{\{|\{%/g)) {
    const start = found.index ?? 0
    const closer = found[0] === '{{' ? '}}' : '%}'
    const end = line.indexOf(closer, start + 2)
    const token = end < 0 ? line.slice(start) : line.slice(start, end + 2)
    if (!PLACEHOLDER.test(token)) report(`line ${at}`, `${shown(token)} is not a {{name}} placeholder; ${NO_CODE}`)
  }
}

function blockOptions(report: Report, info: string, path: string): Record<string, string> | undefined {
  const options: Record<string, string> = {}
  for (const token of info.split(/\s+/).filter(Boolean)) {
    const option = OPTION.exec(token)
    if (!option?.[1] || option[2] === undefined) {
      report(path, `${shown(token)} is not a key=value option or a {{name}} placeholder; blocks hold no loops, expressions or code`)
      return undefined
    }
    if (Object.hasOwn(options, option[1])) {
      report(path, `names the option ${shown(option[1])} twice`)
      return undefined
    }
    options[option[1]] = option[2]
  }
  return options
}

// Opens and closes fences by the same rule as markdown.ts segmentsOf, so the check sees the blocks the renderer draws.
const FENCE_LINE = /^\s*(```|~~~)\s*([\w+#.-]*)\s*(.*)$/

function templateBlocks(report: Report, body: string, startLine: number): Block[] {
  const blocks: Block[] = []
  let open: { language: string; info: string; line: number; lines: string[]; isPeek: boolean } | null = null
  let ordinal = 0
  for (const [index, line] of body.split('\n').entries()) {
    const at = startLine + index
    const fence = FENCE_LINE.exec(line)
    if (open) {
      if (!fence || fence[2]) {
        open.lines.push(line)
        if (open.isPeek) placeholderProblems(report, line, at)
        continue
      }
      const done = open
      open = null
      if (!done.isPeek) continue
      const path = `block ${++ordinal} (${done.language}, line ${done.line})`
      if (!(BLOCK_LANGUAGES as readonly string[]).includes(done.language)) {
        report(path, `is not a peek block; use one of ${BLOCK_LANGUAGES.join(', ')}`)
        continue
      }
      const options = blockOptions(report, done.info, path)
      if (options && blocks.length < DEFINITION_CAPS.blocks) blocks.push({ language: done.language as BlockLanguage, line: done.line, options, text: done.lines.join('\n') })
      continue
    }
    if (fence) {
      const language = fence[2] ?? ''
      open = { language, info: fence[3] ?? '', line: at, lines: [], isPeek: language.startsWith('peek-') }
      continue
    }
    placeholderProblems(report, line, at)
  }
  if (open?.isPeek) report(`block ${ordinal + 1} (${open.language}, line ${open.line})`, 'is never closed')
  if (ordinal > DEFINITION_CAPS.blocks) report('$', `holds ${ordinal} blocks; the most is ${DEFINITION_CAPS.blocks}`)
  return blocks
}

export function readDefinition(file: string, text: string): DefinitionCheck {
  const sink: Sink = []
  const report: Report = (path, message) => {
    if (sink.length < DEFINITION_CAPS.problems) sink.push({ file, path: path || '$', message })
  }
  const front = readFrontmatter(text)
  if (!front.props) {
    for (const problem of front.problems) report('frontmatter', problem.message)
    if (!front.problems.length) report('$', 'has no frontmatter; a definition starts with ---')
    return { ok: false, problems: sink }
  }
  for (const problem of front.problems) report('frontmatter', problem.message)
  const top = record(report, front.props, '', 'a definition', TOP_KEYS) ?? {}
  const type = word(report, top.type, 'type', TYPE_NAME, 'a type name; use 1 to 40 of a-z, 0-9 and -')
  const match = matchRule(report, top.match)
  const props = propsOf(report, top.props)
  const requiresWhen = requiresWhenOf(report, top.requires_when, props)
  const layoutDefault = layoutsOf(report, top.layout_default)
  const colors = colorsOf(report, top.colors, props)
  const icons = iconsOf(report, top.icons)
  const blocks = templateBlocks(report, front.body, front.bodyStartLine)
  if (sink.length || type === undefined || match === undefined) return { ok: false, problems: sink, ...optional('match', match) }
  return {
    ok: true,
    definition: {
      type,
      file,
      match,
      needsRecipe: match.recipe !== undefined,
      props,
      ...optional('requiresWhen', requiresWhen),
      layoutDefault,
      colors,
      icons,
      template: front.body,
      templateStartLine: front.bodyStartLine,
      blocks,
    },
  }
}

function isInFolder(path: string, folder: string): boolean {
  const segments = path.split('/')
  const wanted = folder.split('/')
  // The last segment is the file itself, so the folder must end before it.
  for (let i = 0; i + wanted.length < segments.length; i++) {
    if (wanted.every((one, offset) => segments[i + offset] === one)) return true
  }
  return false
}

export const matches = (definition: Definition, doc: MatchDoc): boolean => matchesRule(definition.match, doc)

export function matchesRule(match: MatchRule, doc: MatchDoc): boolean {
  if (match.recipe !== undefined) return false
  if (match.record !== undefined) return doc.recordKind === match.record
  if (doc.path === undefined) return false
  const prop = match.prop
  const isPropMatch = prop !== undefined && doc.props?.[prop.name] === prop.equals
  return isPropMatch || (match.folder !== undefined && isInFolder(doc.path, match.folder))
}

const isEmpty = (value: PropValue | undefined) =>
  value === undefined || value === null || (typeof value === 'string' && !value.trim()) || (Array.isArray(value) && value.length === 0)

export function requiredPropsFor(definition: Definition, props: Record<string, PropValue> | undefined): string[] {
  const values = props ?? {}
  const rule = definition.requiresWhen
  const isConditionMet = rule !== undefined && Object.entries(rule.when).every(([name, equals]) => values[name] === equals)
  const extra = isConditionMet ? rule.props : []
  return Object.entries(definition.props)
    .filter(([name, decl]) => decl.isRequired || extra === 'all' || extra.includes(name))
    .map(([name]) => name)
    .filter(name => isEmpty(values[name]))
}

export const problemLine = (problem: DefinitionProblem): string => `${problem.file}: ${problem.path} ${problem.message}`
