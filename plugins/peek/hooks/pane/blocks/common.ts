import { LAYOUTS } from '../../views/definition'
import type { Layout } from '../../views/definition'
import { parseRule } from '../../views/select'
import type { Rule } from '../../views/select'

export const RECORD_BLOCKS = ['peek-header', 'peek-fields', 'peek-media', 'peek-comments'] as const
const LAYOUT_KEYS: ReadonlySet<string> = new Set(['layout', 'split', 'cap', 'values', 'nest'])

export type BlockSpec = { layout: Layout; rule: Rule; options: Record<string, string>; cap?: number; selects: string }

const OPTION = /^([\w.-]+)=(.*)$/

const layoutOfLanguage = (lang: string): Layout | undefined => LAYOUTS.find(layout => `peek-${layout}` === lang)

// A rule written in the block body ("a=b and c=d") joins the fence's rule options.
export function blockSpec(lang: string, info: string, body: string): BlockSpec | null {
  const layout = layoutOfLanguage(lang)
  if (!layout) return null
  const options: Record<string, string> = {}
  for (const token of info.split(/\s+/).filter(Boolean)) {
    const option = OPTION.exec(token)
    if (option?.[1] && option[2] !== undefined) options[option[1]] = option[2]
  }
  const rule: Rule = Object.fromEntries(Object.entries(options).filter(([key]) => !LAYOUT_KEYS.has(key)))
  if (body.trim()) Object.assign(rule, parseRule(body.trim()))
  const cap = Number(options.cap)
  const selects = Object.entries(rule).map(([key, value]) => `${key}=${String(value)}`).join(' and ')
  return { layout, rule, options, selects, ...(options.cap !== undefined && Number.isFinite(cap) ? { cap } : {}) }
}

export type PlaceState = { layout?: Layout; folded: readonly string[] }

const MAX_PLACES = 200
const places = new Map<string, PlaceState>()
let onChange: ((place: string, state: PlaceState) => void) | null = null

export const placeKey = (page: string, partKey: string) => `${page}#${partKey}`

export const getPlace = (place: string): PlaceState | undefined => places.get(place)

// Loading saved choices goes through here too, so it does not call the change listener back.
export function setPlace(place: string, state: PlaceState) {
  if (!places.has(place) && places.size >= MAX_PLACES) {
    const oldest = places.keys().next().value
    if (oldest !== undefined) places.delete(oldest)
  }
  places.set(place, state)
}

export function onPlaceChange(listener: ((place: string, state: PlaceState) => void) | null) {
  onChange = listener
}

function changePlace(place: string, change: (state: PlaceState) => PlaceState) {
  const next = change(places.get(place) ?? { folded: [] })
  setPlace(place, next)
  onChange?.(place, next)
}

export type DrawnRow = { place: string; id: string; layout: Layout; hasChildren: boolean }

// Row keys repeat across pages ("body-0-row-3"); the last draw wins, which is the page the keys act on.
const MAX_ROWS = 2000
const drawnRows = new Map<string, DrawnRow>()

export function noteRow(key: string, row: DrawnRow) {
  if (!drawnRows.has(key) && drawnRows.size >= MAX_ROWS) drawnRows.clear()
  drawnRows.set(key, row)
}

export function cycleLayoutOfRow(key: string): Layout | null {
  const row = drawnRows.get(key)
  if (!row) return null
  const next = LAYOUTS[(LAYOUTS.indexOf(row.layout) + 1) % LAYOUTS.length] ?? row.layout
  changePlace(row.place, state => ({ ...state, layout: next }))
  return next
}

export function toggleFoldOfRow(key: string): boolean {
  const row = drawnRows.get(key)
  if (!row?.hasChildren) return false
  changePlace(row.place, state => ({ ...state, folded: state.folded.includes(row.id) ? state.folded.filter(id => id !== row.id) : [...state.folded, row.id] }))
  return true
}
