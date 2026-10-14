import type { PluginState } from 'claude-code'

import type { Cell, NavIo } from '../../../hooks/navigation'
import { loadRecipe } from '../../../hooks/recipes/recipes'
import type { View } from '../../../types'
import { ROOT } from './world'
import type { World } from './world'

type PaneState = PluginState['peek']

const webView = (href: string): View => ({ href, title: 'Web page', location: href, kind: 'web' })

export async function approve(w: World, id: string) {
  const loaded = await loadRecipe(w.io, ROOT, id)
  if (!loaded.ok) throw new Error(`fixture recipe ${id} does not load: ${JSON.stringify(loaded.problems)}`)
  const approvals = (w.store.recipeApprovals ?? {}) as Record<string, unknown>
  w.store.recipeApprovals = { ...approvals, [id]: { digest: loaded.digest, files: loaded.files } }
}

type Active = {
  w: World
  cells: { [K in keyof PaneState]?: PaneState[K] }
  started: string[]
  loadedUrls: string[]
  ran: string[][]
  toasts: string[]
  hold?: (url: string) => Promise<void> | undefined
  holdList?: () => Promise<void> | undefined
  refuseView?: (view: View | null) => boolean
}

let active: Active | undefined
const ticks: (() => void)[] = []

const now = () => {
  if (!active) throw new Error('recipeNav used before use()')
  return active
}

function cell<K extends keyof PaneState>(key: K, initial: PaneState[K]): Cell<PaneState[K]> {
  return {
    read: async () => (key in now().cells ? (now().cells[key] as PaneState[K]) : initial),
    update: async change => {
      const next = change(key in now().cells ? (now().cells[key] as PaneState[K]) : initial)
      if (key === 'view' && now().refuseView?.(next as View | null)) throw new Error('state write refused')
      now().cells[key] = next
      return next
    },
  }
}

const unused = (name: string) => () => {
  throw new Error(`recipe session called ${name}`)
}

// One NavIo for the whole file: navigation starts its 15 s ticker once per module, so the ticker's closure must keep
// reaching whichever world the current test installed.
export const recipeNav = {
  io: (<Partial<NavIo>>{
    view: cell('view', null),
    mode: cell('mode', 'view'),
    page: cell('page', 0),
    mentions: cell('mentions', []),
    openGroup: cell('openGroup', null),
    stars: cell('stars', []),
    cursor: cell('cursor', 0),
    menuOpen: cell('menuOpen', false),
    menuFilter: cell('menuFilter', ''),
    now: () => now().w.io.now(),
    every: (_ms: number, fn: () => void) => void ticks.push(fn),
    home: () => now().w.io.home(),
    storeGet: key => now().w.io.storeGet(key),
    storeSet: async (key, value) => {
      now().w.store[key] = value
    },
    run: async argv => {
      now().ran.push([...argv])
      return { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    },
    recipesIo: () => recipeNav.runIo(),
    runIo: () => recipeNav.runIo(),
    scroll: async () => undefined as never,
    open: async () => ({ isPlaced: true }),
    invalidate: () => undefined,
    toast: text => void now().toasts.push(text),
    pluginRoot: '/plugins/peek',
    openGroupRemotes: () => [],
    loadUrl: async href => {
      now().loadedUrls.push(href)
      return webView(href)
    },
    loadFile: async (href, path) => ({ href, title: path, location: path }),
    remoteIo: () => {
      throw new Error('remote load refused in the recipe session world')
    },
    forgetPath: unused('forgetPath'),
  }) as NavIo,
  runIo() {
    const { w } = now()
    return {
      ...w.io,
      list: async (dir: string) => {
        await now().holdList?.()
        return w.io.list(dir)
      },
      run: async (argv: readonly string[], init?: Parameters<World['io']['run']>[1]) => {
        if (argv[0] === '/usr/bin/env') {
          const url = argv.at(-1) ?? ''
          now().started.push(url)
          await now().hold?.(url)
        }
        return w.io.run(argv, init)
      },
    }
  },
  use(w: World, options: Pick<Active, 'hold' | 'holdList' | 'refuseView'> = {}) {
    active = { w, cells: {}, started: [], loadedUrls: [], ran: [], toasts: [], ...options }
    return active
  },
  tick() {
    for (const fn of ticks) fn()
    return ticks.length
  },
}

// Script runs a test holds open until it says so.
export function gate() {
  let release = () => {}
  const held = new Promise<void>(resolve => {
    release = resolve
  })
  return { held, release }
}

// The test runtime has setTimeout; the plugin's type declarations do not.
const timers = globalThis as unknown as { setTimeout: (fn: () => void, ms: number) => unknown }

// A recipe run hashes its folder with crypto.subtle, which settles outside the microtask queue, so a test waits on a
// condition across timer turns rather than flushing promises.
export async function until(isDone: () => boolean | Promise<boolean>, tries = 200) {
  for (let i = 0; i < tries; i++) {
    if (await isDone()) return
    await new Promise<void>(resolve => timers.setTimeout(resolve, 0))
  }
}
