import { expect, mock, test } from 'claude-code/testing'
import type { On, ProcessSpawnChunk } from 'claude-code'
import type { Engine, Mounted } from 'claude-code/testing'
import { exited } from './fixtures/results'
import { PANE_PROPS, baseWorld, create, editGroup, fakeFs, fakeProcess, noDisk } from './fixtures/world'

// For each screen: the footer keys and the ⌃k rows (id, label, hint, in order), and what pressing each footer key does.
// A press is told apart by what it changes: state writes, engine calls, live-helper posts and what the next draw shows.

type Ui = Mounted<'terminal', 'Pane'>
type Node = { type?: string; props?: Record<string, unknown>; children?: unknown[] }
type Watch = { log: string[]; ids: string[] }
type Setup = { ui: Ui; watch: Watch; settle: () => Promise<void> }

const LIVE_PAGE = 'https://news.test/'
const HTML = '<html><head><title>News Test</title></head><body><p>Readable story text.</p></body></html>'

const settleMicrotasks = async () => {
  for (let i = 0; i < 1000; i += 1) await Promise.resolve()
}

function normalized(text: string, ids: readonly string[]) {
  return ids.reduce((all, id, index) => all.split(id).join(`GROUP${index}`), text).replace(/\.[a-z0-9]+\.staged$/, '.STAGED')
}

function short(key: string, value: unknown) {
  if (key === 'view') {
    const view = value as { href?: string; title?: string } | null
    return view ? `${view.href} ${view.title}` : 'null'
  }
  if (key === 'mentions') return (value as { href: string }[]).map(one => one.href).join(',')
  return JSON.stringify(value) ?? 'undefined'
}

function watching(on: On): Watch {
  const watch: Watch = { log: [], ids: [] }
  const log = watch.log
  on('state.set', (_$, e, next) => {
    const write = e as { key: string; value: unknown }
    log.push(`set ${write.key} ${short(write.key, write.value)}`)
    return next(e)
  })
  on('store.set', (_$, e, next) => {
    log.push(`store ${e.key} ${JSON.stringify(e.value)}`)
    return next(e)
  })
  on('ui.close', () => {
    log.push('close')
    return { value: undefined } as never
  })
  on('ui.copy', (_$, e) => {
    log.push(`copy ${JSON.stringify(e)}`)
    return { value: undefined } as never
  })
  return watch
}

function walk(node: unknown, visit: (one: Node) => void) {
  if (!node || typeof node !== 'object') return
  visit(node as Node)
  for (const child of (node as Node).children ?? []) walk(child, visit)
}

function textOf(node: unknown): string {
  if (typeof node === 'string') return node
  if (!node || typeof node !== 'object') return ''
  return ((node as Node).children ?? []).map(textOf).join('')
}

async function footerOf(ui: Ui, ids: readonly string[]) {
  const keys: string[] = []
  walk(await ui.drawn(), one => {
    if (one.props?.key !== 'footer-keys') return
    for (const button of (one.children ?? []) as Node[]) keys.push(`${button.props?.key}|${button.props?.label}|${button.props?.hotkey}`)
  })
  return keys.map(one => normalized(one, ids))
}

async function menuOf($: Engine, ui: Ui, ids: readonly string[]) {
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  const rows: string[] = []
  walk(await ui.drawn(), one => {
    const key = String(one.props?.key ?? '')
    if (key.startsWith('menu-row-')) {
      const [left, hint] = (one.children ?? []) as Node[]
      const button = (left?.children ?? []).find(child => (child as Node).type === 'Button') as Node | undefined
      rows.push(`${key.slice('menu-row-'.length)}|${button?.props?.label}|${textOf(hint)}`)
    } else if (one.type === 'Text' && / move$/.test(textOf(one))) rows.push(`moves|${textOf(one)}`)
  })
  await $.command.run({ command: 'peek-menu' } as never)
  return rows.map(one => normalized(one, ids))
}

// What the next draw shows: the footer (screen, labels, typing), whether the live frame is up, and the first card's MORE/LESS.
async function afterPress(ui: Ui, watch: Watch) {
  await ui.redraw()
  watch.log.push(`footer ${(await footerOf(ui, watch.ids)).map(one => one.split('|').slice(0, 2).join('|')).join(',')}`)
  if (await ui.find({ key: 'live-frame' })) watch.log.push('live frame')
  const more = await ui.find({ key: 'groups-more-0' })
  if (more) watch.log.push(`more ${String(more.props.label)}`)
}

function filesWorld(on: On) {
  const w = fakeFs(on)
  const watch = watching(on)
  return { w, watch }
}

async function filesSetup($: Engine, on: On, after: (ui: Ui) => Promise<void>): Promise<Setup> {
  const { w, watch } = filesWorld(on)
  const launch = await create($ as never, [{ target: 'docs/plan.md' }, { target: 'notes/todo.md' }], 'Launch')
  w.now += 60_000
  const spare = await create($ as never, [{ target: 'docs/plan.md' }], 'Spare')
  watch.ids.push(launch.id, spare.id)
  editGroup(w, launch.id, group => (group.starred = true))
  await $.command.run({ command: 'peek', args: '/repo/notes/todo.md' } as never)
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await after(ui)
  await settleMicrotasks()
  await ui.redraw()
  const toasts = w.toasts
  const runs = w.log
  const settle = async () => {
    await settleMicrotasks()
    for (const text of toasts.splice(0)) watch.log.push(`toast ${text}`)
    for (const one of runs.splice(0)) if ((one[0] === 'run' && one[1] === 'open') || one[0] === 'write') watch.log.push(one.join(' '))
    await afterPress(ui, watch)
  }
  toasts.splice(0)
  runs.splice(0)
  return { ui, watch, settle }
}

function liveWorld(on: On) {
  const posted: { path: string; body?: unknown }[] = []
  const ran: string[][] = []
  const helpers: { say: (event: unknown) => void }[] = []
  mock.clock(on, { now: 10 * 3600_000 })
  on('session.id', () => ({ value: 'actions-live' }))
  on('session.root', () => ({ value: '/repo' }))
  baseWorld(on)
  const watch = watching(on)
  on('ui.blit', () => ({ value: {} }))
  on('ui.invalidate', (_$, e, next) => {
    watch.log.push('invalidate')
    return next(e)
  })
  noDisk(on)
  on('fs.exists', (_$, e) => ({ value: e.path.startsWith('/home/.cache/claude-peek/bin/') }))
  on('fs.read', (_$, e) => {
    if (e.path.endsWith('/helper/peek-web.swift')) return { value: 'print("helper")' }
    throw new Error(`ENOENT ${e.path}`)
  })
  fakeProcess(on, () => exited(0), ran)
  on('http.fetch', (_$, e) => {
    if (e.init?.socketPath) {
      const body = e.init.body ? JSON.parse(e.init.body) : undefined
      posted.push(body === undefined ? { path: e.url.replace('http://peek-web/', '') } : { path: e.url.replace('http://peek-web/', ''), body })
      return { value: { status: 200, ok: true, headers: {} as Record<string, string>, text: '{"ok":true}' } }
    }
    if (e.url === LIVE_PAGE) return { value: { status: 200, ok: true, headers: { 'content-type': 'text/html' } as Record<string, string>, text: HTML } }
    return { value: { status: 404, ok: false, headers: {} as Record<string, string>, text: '' } }
  })
  on('process.spawn', async function* () {
    const queue: ProcessSpawnChunk[] = []
    let wake: (() => void) | null = null
    helpers.push({
      say: event => {
        queue.push({ stream: 'stdout', text: `${JSON.stringify(event)}\n` })
        wake?.()
      },
    })
    while (true) {
      const chunk = queue.shift()
      if (chunk) {
        yield chunk
        continue
      }
      await new Promise<void>(resolve => (wake = resolve))
    }
  })
  const helper = () => helpers.at(-1)
  return { posted, ran, watch, helper }
}

async function liveSetup($: Engine, on: On, mode: 'reader' | 'live' | 'typing'): Promise<Setup> {
  const world = liveWorld(on)
  await $.command.run({ command: 'peek', args: LIVE_PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  if (mode !== 'reader') {
    await ui.press({ key: 'live' })
    await settleMicrotasks()
    world.helper()?.say({ t: 'ready', socket: '/run/ctl.sock', dir: '/tmp/peek-web.abc123', throttled: false })
    await settleMicrotasks()
    world.helper()?.say({ t: 'frame', id: 1, path: '/tmp/peek-web.abc123/frame-1.png', width: 600, height: 400, bytes: 1000 })
    await settleMicrotasks()
    world.helper()?.say({ t: 'nav', url: 'https://news.test/story', title: 'Story', canBack: true, canForward: false })
    await settleMicrotasks()
  }
  if (mode === 'typing') {
    await ui.pointer({ type: 'down', button: 'left', x: 3, y: 3, in: 'live-input' })
    world.helper()?.say({ t: 'focus', editable: true })
    await settleMicrotasks()
  }
  await ui.redraw()
  const settle = async () => {
    await settleMicrotasks()
    for (const one of world.posted.splice(0)) world.watch.log.push(`post ${one.path}${one.body === undefined ? '' : ` ${JSON.stringify(one.body)}`}`)
    for (const one of world.ran.splice(0)) if (one[0] === 'open') world.watch.log.push(`run ${one.join(' ')}`)
    await afterPress(ui, world.watch)
  }
  world.posted.splice(0)
  world.ran.splice(0)
  return { ui, watch: world.watch, settle }
}

const SCREENS: Record<string, ($: Engine, on: On) => Promise<Setup>> = {
  'view reader, local file': ($, on) => filesSetup($, on, async () => undefined),
  recent: ($, on) => filesSetup($, on, async ui => void (await ui.press({ key: 'mode-recent' }))),
  gallery: ($, on) => filesSetup($, on, async ui => void (await ui.press({ key: 'mode-gallery' }))),
  'groups tab': ($, on) => filesSetup($, on, async ui => void (await ui.press({ key: 'mode-groups' }))),
  'group page': ($, on) =>
    filesSetup($, on, async ui => {
      await ui.press({ key: 'mode-groups' })
      await settleMicrotasks()
      await ui.press({ key: 'open-selected' })
    }),
  'view reader, opened from a group': ($, on) =>
    filesSetup($, on, async ui => {
      await ui.press({ key: 'mode-groups' })
      await settleMicrotasks()
      await ui.press({ key: 'open-selected' })
      await settleMicrotasks()
      await ui.press({ key: 'open-selected' })
    }),
  'view reader, web page': ($, on) => liveSetup($, on, 'reader'),
  'view live': ($, on) => liveSetup($, on, 'live'),
  'view live, typing': ($, on) => liveSetup($, on, 'typing'),
}

type Expected = { footer: string[]; menu: string[]; presses: Record<string, string[]> }
const EXPECTED: Record<string, Expected> = {
  "view reader, local file": {
    "footer": [
      "mode-view|Peek|p",
      "mode-recent|Recent|r",
      "mode-gallery|Gallery|g",
      "mode-groups|Groups|e",
      "next|Down|j",
      "prev|Up|k",
      "star|Star|f",
      "open|Open|o",
      "copy|Copy path|c",
      "close|Close|x"
    ],
    "menu": [
      "peek|Peek: show the open file|p",
      "recent|Recent: files by last use|r",
      "gallery|Gallery: files as cards by type|g",
      "groups|Groups: files and links the agent bundled|e",
      "role-all|Show: all|",
      "role-artifacts|Show: artifacts|",
      "role-touched|Show: touched|",
      "scope-session|Scope: session|",
      "scope-worktree|Scope: worktree|",
      "scope-repo|Scope: repo|",
      "top|Scroll to top|home",
      "bottom|Scroll to bottom|end",
      "open|Open in its own app|o",
      "copy|Copy path|c",
      "star|Star or unstar this file|f",
      "group-remove-GROUP1|Remove from group: Spare|",
      "group-remove-GROUP0|Remove from group: Launch|",
      "close|Close the pane|x",
      "file-0|Go to plan.md|just now",
      "file-1|Go to todo.md|just now",
      "moves|j k move"
    ],
    "presses": {
      "mode-view": [
        "set mode \"view\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "mode-recent": [
        "set mode \"recent\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "mode-gallery": [
        "set mode \"gallery\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-groups": [
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "next": [
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "prev": [
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "star": [
        "set stars [\"file:///repo/docs/plan.md\"]",
        "store stars [\"file:///repo/docs/plan.md\"]",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Unstar,open|Open,copy|Copy path,close|Close"
      ],
      "open": [
        "write /tmp/claude-peek/plan.md.html",
        "run open /tmp/claude-peek/plan.md.html",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "copy": [
        "copy {\"text\":\"/repo/docs/plan.md\"}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "close": [
        "close",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "menu-peek": [
        "set menuFilter \"\"",
        "set mode \"view\"",
        "set menuOpen false",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "menu-recent": [
        "set menuFilter \"\"",
        "set mode \"recent\"",
        "set menuOpen false",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "menu-gallery": [
        "set menuFilter \"\"",
        "set mode \"gallery\"",
        "set menuOpen false",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "menu-groups": [
        "set menuFilter \"\"",
        "set mode \"groups\"",
        "set menuOpen false",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ]
    }
  },
  "recent": {
    "footer": [
      "mode-view|Peek|p",
      "mode-recent|Recent|r",
      "mode-gallery|Gallery|g",
      "mode-groups|Groups|e",
      "scope|Scope: session|s",
      "role|Show: all|a",
      "next|Down|j",
      "prev|Up|k",
      "left|Left|h",
      "right|Right|l",
      "open-selected|⏎ Open|o",
      "star-selected|Star|f",
      "expand-selected|More|m",
      "close|Close|x"
    ],
    "menu": [
      "peek|Peek: show the open file|p",
      "recent|Recent: files by last use|r",
      "gallery|Gallery: files as cards by type|g",
      "groups|Groups: files and links the agent bundled|e",
      "role-all|Show: all|a",
      "role-artifacts|Show: artifacts|a",
      "role-touched|Show: touched|a",
      "scope-session|Scope: session|s",
      "scope-worktree|Scope: worktree|s",
      "scope-repo|Scope: repo|s",
      "top|Scroll to top|home",
      "bottom|Scroll to bottom|end",
      "open|Open in its own app|",
      "copy|Copy path|",
      "star|Star or unstar this file|",
      "key-open-selected|Open the selected group|o",
      "key-star-selected|Unstar the selected group|f",
      "key-expand-selected|Expand/Collapse group|m",
      "group-star|Unstar this group|f",
      "close|Close the pane|x",
      "file-0|Go to plan.md|just now",
      "moves|j k h l move"
    ],
    "presses": {
      "mode-view": [
        "set mode \"view\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "mode-recent": [
        "set mode \"recent\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "mode-gallery": [
        "set mode \"gallery\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-groups": [
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "scope": [
        "set scope \"worktree\"",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: worktree,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "role": [
        "set roleFilter \"artifacts\"",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: artifacts,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "next": [
        "set cursor 1",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "prev": [
        "set cursor 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "left": [
        "set cursor 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "right": [
        "set cursor 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "open-selected": [
        "set openGroup {\"id\":\"GROUP0\",\"item\":null}",
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "star-selected": [
        "write /home/.local/share/claude-peek/groups/ea199529256b9f85/GROUP0.json.lock/owner",
        "write /home/.local/share/claude-peek/groups/ea199529256b9f85/GROUP0.json.STAGED",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "expand-selected": [
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "close": [
        "close",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ]
    }
  },
  "gallery": {
    "footer": [
      "mode-view|Peek|p",
      "mode-recent|Recent|r",
      "mode-gallery|Gallery|g",
      "mode-groups|Groups|e",
      "scope|Scope: session|s",
      "role|Show: all|a",
      "type|Type|t",
      "sort|Sort|n",
      "next|Down|j",
      "prev|Up|k",
      "left|Left|h",
      "right|Right|l",
      "open-selected|⏎ Open|o",
      "star-selected|Star|f",
      "close|Close|x"
    ],
    "menu": [
      "peek|Peek: show the open file|p",
      "recent|Recent: files by last use|r",
      "gallery|Gallery: files as cards by type|g",
      "groups|Groups: files and links the agent bundled|e",
      "role-all|Show: all|a",
      "role-artifacts|Show: artifacts|a",
      "role-touched|Show: touched|a",
      "scope-session|Scope: session|s",
      "scope-worktree|Scope: worktree|s",
      "scope-repo|Scope: repo|s",
      "top|Scroll to top|home",
      "bottom|Scroll to bottom|end",
      "open|Open in its own app|",
      "copy|Copy path|",
      "star|Star or unstar this file|",
      "key-type|Next file type (now all)|t",
      "key-sort|Next sort order (now recent)|n",
      "key-open-selected|Open the selected file|o",
      "key-star-selected|Star or unstar the selected file|f",
      "group-remove-GROUP1|Remove from group: Spare|",
      "group-remove-GROUP0|Remove from group: Launch|",
      "close|Close the pane|x",
      "moves|j k h l move"
    ],
    "presses": {
      "mode-view": [
        "set mode \"view\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "mode-recent": [
        "set mode \"recent\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "mode-gallery": [
        "set mode \"gallery\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-groups": [
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "scope": [
        "set scope \"worktree\"",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: worktree,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "role": [
        "set roleFilter \"artifacts\"",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: artifacts,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "type": [
        "set galleryType \"markdown\"",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "sort": [
        "set gallerySort \"name\"",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "next": [
        "set cursor 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "prev": [
        "set cursor 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "left": [
        "set cursor 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "right": [
        "set cursor 1",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "open-selected": [
        "set view file:///repo/docs/plan.md Loading…",
        "set mentions file:///repo/notes/todo.md,file:///repo/docs/plan.md",
        "set page 0",
        "set mode \"view\"",
        "set view file:///repo/docs/plan.md plan.md",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "star-selected": [
        "set stars [\"file:///repo/docs/plan.md\"]",
        "store stars [\"file:///repo/docs/plan.md\"]",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "close": [
        "close",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ]
    }
  },
  "groups tab": {
    "footer": [
      "mode-view|Peek|p",
      "mode-recent|Recent|r",
      "mode-gallery|Gallery|g",
      "mode-groups|Groups|e",
      "next|Down|j",
      "prev|Up|k",
      "left|Left|h",
      "right|Right|l",
      "open-selected|⏎ Open|o",
      "star-selected|Star|f",
      "expand-selected|More|m",
      "close|Close|x"
    ],
    "menu": [
      "peek|Peek: show the open file|p",
      "recent|Recent: files by last use|r",
      "gallery|Gallery: files as cards by type|g",
      "groups|Groups: files and links the agent bundled|e",
      "role-all|Show: all|",
      "role-artifacts|Show: artifacts|",
      "role-touched|Show: touched|",
      "scope-session|Scope: session|",
      "scope-worktree|Scope: worktree|",
      "scope-repo|Scope: repo|",
      "top|Scroll to top|home",
      "bottom|Scroll to bottom|end",
      "open|Open in its own app|",
      "copy|Copy path|",
      "star|Star or unstar this file|",
      "key-open-selected|Open the selected group|o",
      "key-star-selected|Star or unstar the selected group|f",
      "key-expand-selected|Expand/Collapse group|m",
      "group-star|Unstar this group|f",
      "close|Close the pane|x",
      "file-0|Go to plan.md|just now",
      "moves|j k h l move"
    ],
    "presses": {
      "mode-view": [
        "set mode \"view\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "mode-recent": [
        "set mode \"recent\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "mode-gallery": [
        "set mode \"gallery\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-groups": [
        "set openGroup null",
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "next": [
        "set cursor 1",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "prev": [
        "set cursor 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "left": [
        "set cursor 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "right": [
        "set cursor 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "open-selected": [
        "set openGroup {\"id\":\"GROUP0\",\"item\":null}",
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "star-selected": [
        "set cursor 1",
        "write /home/.local/share/claude-peek/groups/ea199529256b9f85/GROUP0.json.lock/owner",
        "write /home/.local/share/claude-peek/groups/ea199529256b9f85/GROUP0.json.STAGED",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "expand-selected": [
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "close": [
        "close",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ]
    }
  },
  "group page": {
    "footer": [
      "mode-view|Peek|p",
      "mode-recent|Recent|r",
      "mode-gallery|Gallery|g",
      "mode-groups|Groups|e",
      "next|Down|j",
      "prev|Up|k",
      "open-selected|⏎ Open|o",
      "star-selected|Star|f",
      "close|Close|x"
    ],
    "menu": [
      "peek|Peek: show the open file|p",
      "recent|Recent: files by last use|r",
      "gallery|Gallery: files as cards by type|g",
      "groups|Groups: files and links the agent bundled|e",
      "role-all|Show: all|",
      "role-artifacts|Show: artifacts|",
      "role-touched|Show: touched|",
      "scope-session|Scope: session|",
      "scope-worktree|Scope: worktree|",
      "scope-repo|Scope: repo|",
      "top|Scroll to top|home",
      "bottom|Scroll to bottom|end",
      "open|Open in its own app|",
      "copy|Copy path|",
      "star|Star or unstar this file|",
      "key-open-selected|Open the selected item|o",
      "key-star-selected|Star or unstar the selected item|f",
      "group-star|Unstar this group|",
      "group-remove-here|Remove from this group|",
      "group-remove-GROUP1|Remove from group: Spare|",
      "close|Close the pane|x",
      "file-0|Go to plan.md|just now",
      "file-1|Go to todo.md|just now",
      "moves|j k move"
    ],
    "presses": {
      "mode-view": [
        "set mode \"view\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "mode-recent": [
        "set mode \"recent\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "mode-gallery": [
        "set mode \"gallery\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-groups": [
        "set openGroup null",
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "next": [
        "set openGroup {\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"}",
        "set cursor 1",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "prev": [
        "set openGroup {\"id\":\"GROUP0\",\"item\":\"docs/plan.md\"}",
        "set cursor 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "open-selected": [
        "set openGroup {\"id\":\"GROUP0\",\"item\":\"docs/plan.md\"}",
        "set cursor 0",
        "set openGroup {\"id\":\"GROUP0\",\"item\":\"docs/plan.md\"}",
        "set view file:///repo/docs/plan.md Loading…",
        "set mentions file:///repo/notes/todo.md,file:///repo/docs/plan.md",
        "set page 0",
        "set mode \"view\"",
        "set view file:///repo/docs/plan.md plan.md",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,back|Back,copy|Copy path,close|Close"
      ],
      "star-selected": [
        "set stars [\"file:///repo/docs/plan.md\"]",
        "store stars [\"file:///repo/docs/plan.md\"]",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "close": [
        "close",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "menu-peek": [
        "set menuFilter \"\"",
        "set mode \"view\"",
        "set menuOpen false",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,copy|Copy path,close|Close"
      ],
      "menu-recent": [
        "set menuFilter \"\"",
        "set mode \"recent\"",
        "set menuOpen false",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "menu-gallery": [
        "set menuFilter \"\"",
        "set mode \"gallery\"",
        "set menuOpen false",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "menu-groups": [
        "set menuFilter \"\"",
        "set openGroup null",
        "set menuOpen false",
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ]
    }
  },
  "view reader, opened from a group": {
    "footer": [
      "mode-view|Peek|p",
      "mode-recent|Recent|r",
      "mode-gallery|Gallery|g",
      "mode-groups|Groups|e",
      "next|Down|j",
      "prev|Up|k",
      "star|Star|f",
      "open|Open|o",
      "back|Back|b",
      "copy|Copy path|c",
      "close|Close|x"
    ],
    "menu": [
      "peek|Peek: show the open file|p",
      "recent|Recent: files by last use|r",
      "gallery|Gallery: files as cards by type|g",
      "groups|Groups: files and links the agent bundled|e",
      "role-all|Show: all|",
      "role-artifacts|Show: artifacts|",
      "role-touched|Show: touched|",
      "scope-session|Scope: session|",
      "scope-worktree|Scope: worktree|",
      "scope-repo|Scope: repo|",
      "top|Scroll to top|home",
      "bottom|Scroll to bottom|end",
      "open|Open in its own app|o",
      "copy|Copy path|c",
      "star|Star or unstar this file|f",
      "key-back|Back to Launch|b",
      "group-remove-GROUP1|Remove from group: Spare|",
      "group-remove-GROUP0|Remove from group: Launch|",
      "close|Close the pane|x",
      "file-0|Go to plan.md|just now",
      "file-1|Go to todo.md|just now",
      "moves|j k move"
    ],
    "presses": {
      "mode-view": [
        "set mode \"view\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,back|Back,copy|Copy path,close|Close"
      ],
      "mode-recent": [
        "set mode \"recent\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "mode-gallery": [
        "set mode \"gallery\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-groups": [
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "next": [
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,back|Back,copy|Copy path,close|Close"
      ],
      "prev": [
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,back|Back,copy|Copy path,close|Close"
      ],
      "star": [
        "set stars [\"file:///repo/docs/plan.md\"]",
        "store stars [\"file:///repo/docs/plan.md\"]",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Unstar,open|Open,back|Back,copy|Copy path,close|Close"
      ],
      "open": [
        "write /tmp/claude-peek/plan.md.html",
        "run open /tmp/claude-peek/plan.md.html",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,back|Back,copy|Copy path,close|Close"
      ],
      "back": [
        "set openGroup {\"id\":\"GROUP0\",\"item\":\"docs/plan.md\"}",
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "copy": [
        "copy {\"text\":\"/repo/docs/plan.md\"}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,back|Back,copy|Copy path,close|Close"
      ],
      "close": [
        "close",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,star|Star,open|Open,back|Back,copy|Copy path,close|Close"
      ]
    }
  },
  "view reader, web page": {
    "footer": [
      "mode-view|Peek|p",
      "mode-recent|Recent|r",
      "mode-gallery|Gallery|g",
      "mode-groups|Groups|e",
      "live|Live|v",
      "next|Down|j",
      "prev|Up|k",
      "star|Star|f",
      "open|Open in browser|o",
      "refresh|Refresh|u",
      "copy|Copy link|c",
      "close|Close|x"
    ],
    "menu": [
      "peek|Peek: show the open file|p",
      "recent|Recent: files by last use|r",
      "gallery|Gallery: files as cards by type|g",
      "groups|Groups: files and links the agent bundled|e",
      "role-all|Show: all|",
      "role-artifacts|Show: artifacts|",
      "role-touched|Show: touched|",
      "scope-session|Scope: session|",
      "scope-worktree|Scope: worktree|",
      "scope-repo|Scope: repo|",
      "top|Scroll to top|home",
      "bottom|Scroll to bottom|end",
      "open|Open in its own app|o",
      "refresh|Refresh this page|u",
      "live|Live view: the real page, clickable|v",
      "copy|Copy link|c",
      "star|Star or unstar this file|f",
      "close|Close the pane|x",
      "file-0|Go to https://news.test/|just now",
      "moves|j k move"
    ],
    "presses": {
      "mode-view": [
        "set mode \"view\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "mode-recent": [
        "set mode \"recent\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-gallery": [
        "set mode \"gallery\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-groups": [
        "set mode \"groups\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "live": [
        "invalidate",
        "invalidate",
        "invalidate",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "next": [
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "prev": [
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "star": [
        "set stars [\"https://news.test/\"]",
        "store stars [\"https://news.test/\"]",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Unstar,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "open": [
        "run open https://news.test/",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "refresh": [
        "set view https://news.test/ News Test",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "copy": [
        "copy {\"text\":\"https://news.test/\"}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "close": [
        "close",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ]
    }
  },
  "view live": {
    "footer": [
      "mode-view|Peek|p",
      "mode-recent|Recent|r",
      "mode-gallery|Gallery|g",
      "mode-groups|Groups|e",
      "live|Reader|v",
      "next|Down|j",
      "prev|Up|k",
      "star|Star|f",
      "open|Open in browser|o",
      "refresh|Reload|u",
      "back|Back|b",
      "copy|Copy link|c",
      "close|Close|x"
    ],
    "menu": [
      "peek|Peek: show the open file|p",
      "recent|Recent: files by last use|r",
      "gallery|Gallery: files as cards by type|g",
      "groups|Groups: files and links the agent bundled|e",
      "role-all|Show: all|",
      "role-artifacts|Show: artifacts|",
      "role-touched|Show: touched|",
      "scope-session|Scope: session|",
      "scope-worktree|Scope: worktree|",
      "scope-repo|Scope: repo|",
      "top|Scroll to top|home",
      "bottom|Scroll to bottom|end",
      "open|Open in its own app|o",
      "refresh|Refresh this page|u",
      "live|Reader view: leave the live page|v",
      "live-back|Back in the live page|b",
      "copy|Copy link|c",
      "star|Star or unstar this file|f",
      "close|Close the pane|x",
      "file-0|Go to https://news.test/|just now",
      "moves|j k move"
    ],
    "presses": {
      "mode-view": [
        "set mode \"view\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "mode-recent": [
        "set mode \"recent\"",
        "set page 0",
        "invalidate",
        "post pause",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-gallery": [
        "set mode \"gallery\"",
        "set page 0",
        "invalidate",
        "post pause",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-groups": [
        "set mode \"groups\"",
        "set page 0",
        "invalidate",
        "post pause",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "live": [
        "invalidate",
        "post pause",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "next": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":80}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "prev": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":-80}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "star": [
        "set stars [\"https://news.test/story\"]",
        "store stars [\"https://news.test/story\"]",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Unstar,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "open": [
        "run open https://news.test/story",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "refresh": [
        "post reload",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "back": [
        "post back",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "copy": [
        "copy {\"text\":\"https://news.test/story\"}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "close": [
        "close",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input j": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":80}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input down": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":80}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input k": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":-80}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input up": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":-80}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input  ": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":430}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input pagedown": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":430}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input pageup": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":-430}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input b": [
        "post back",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input u": [
        "post reload",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input v": [
        "invalidate",
        "invalidate",
        "post pause",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "input o": [
        "run open https://news.test/story",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input c": [
        "copy {\"text\":\"https://news.test/story\"}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input f": [
        "set stars [\"https://news.test/story\"]",
        "store stars [\"https://news.test/story\"]",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Unstar,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input d": [
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "input x": [
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ]
    }
  },
  "view live, typing": {
    "footer": [
      "mode-view|Peek|p",
      "mode-recent|Recent|r",
      "mode-gallery|Gallery|g",
      "mode-groups|Groups|e",
      "live|Reader|v",
      "done-typing|Done typing|d",
      "next|Down|j",
      "prev|Up|k",
      "star|Star|f",
      "open|Open in browser|o",
      "refresh|Reload|u",
      "back|Back|b",
      "copy|Copy link|c",
      "close|Close|x"
    ],
    "menu": [
      "peek|Peek: show the open file|p",
      "recent|Recent: files by last use|r",
      "gallery|Gallery: files as cards by type|g",
      "groups|Groups: files and links the agent bundled|e",
      "role-all|Show: all|",
      "role-artifacts|Show: artifacts|",
      "role-touched|Show: touched|",
      "scope-session|Scope: session|",
      "scope-worktree|Scope: worktree|",
      "scope-repo|Scope: repo|",
      "top|Scroll to top|home",
      "bottom|Scroll to bottom|end",
      "open|Open in its own app|o",
      "refresh|Refresh this page|u",
      "live|Reader view: leave the live page|v",
      "live-back|Back in the live page|b",
      "copy|Copy link|c",
      "star|Star or unstar this file|f",
      "key-done-typing|Done typing: give the keys back to peek|d",
      "close|Close the pane|x",
      "moves|j k move"
    ],
    "presses": {
      "mode-view": [
        "set mode \"view\"",
        "set page 0",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "mode-recent": [
        "set mode \"recent\"",
        "set page 0",
        "invalidate",
        "post pause",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-gallery": [
        "set mode \"gallery\"",
        "set page 0",
        "invalidate",
        "post pause",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,scope|Scope: session,role|Show: all,type|Type,sort|Sort,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,close|Close"
      ],
      "mode-groups": [
        "set mode \"groups\"",
        "set page 0",
        "invalidate",
        "post pause",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,next|Down,prev|Up,left|Left,right|Right,open-selected|⏎ Open,star-selected|Star,expand-selected|More,close|Close"
      ],
      "live": [
        "invalidate",
        "post pause",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Live,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Refresh,copy|Copy link,close|Close"
      ],
      "done-typing": [
        "invalidate",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "next": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":80}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "prev": [
        "post input {\"events\":[{\"type\":\"scroll\",\"x\":372,\"y\":269,\"dy\":-80}]}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "star": [
        "set stars [\"https://news.test/story\"]",
        "store stars [\"https://news.test/story\"]",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Unstar,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "open": [
        "run open https://news.test/story",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "refresh": [
        "post reload",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "back": [
        "post back",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "copy": [
        "copy {\"text\":\"https://news.test/story\"}",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ],
      "close": [
        "close",
        "footer mode-view|Peek,mode-recent|Recent,mode-gallery|Gallery,mode-groups|Groups,live|Reader,next|Down,prev|Up,star|Star,open|Open in browser,refresh|Reload,back|Back,copy|Copy link,close|Close",
        "live frame"
      ]
    }
  }
}

for (const [name, setup] of Object.entries(SCREENS)) {
  test(`${name}: the footer keys and the ctrl+k rows`, async ($, on) => {
    const { ui, watch } = await setup($, on)
    const footer = await footerOf(ui, watch.ids)
    const menu = await menuOf($, ui, watch.ids)
    await ui.unmount()
    expect(footer).toEqual(EXPECTED[name]?.footer)
    expect(menu).toEqual(EXPECTED[name]?.menu)
  })
  for (const footerKey of EXPECTED[name]?.footer ?? []) {
    const key = footerKey.split('|')[0] ?? ''
    test(`${name}: pressing ${key}`, async ($, on) => {
      const { ui, watch, settle } = await setup($, on)
      watch.log.splice(0)
      await ui.press({ key })
      await settle()
      const effect = watch.log.map(one => normalized(one, watch.ids))
      await ui.unmount()
      expect(effect).toEqual(EXPECTED[name]?.presses[key])
    })
  }
}

// ⌃k Peek, Recent and Gallery set the mode alone, while ⌃k Groups (like every footer mode key) goes through switchMode.
const MENU_MODE_ROWS = ['peek', 'recent', 'gallery', 'groups']
for (const name of ['view reader, local file', 'group page']) {
  for (const row of MENU_MODE_ROWS) {
    test(`${name}: ctrl+k ${row}`, async ($, on) => {
      const { ui, watch, settle } = await SCREENS[name]!($, on)
      await $.command.run({ command: 'peek-menu' } as never)
      await ui.redraw()
      watch.log.splice(0)
      await ui.press({ key: `menu-${row}` })
      await settle()
      const effect = watch.log.map(one => normalized(one, watch.ids))
      await ui.unmount()
      expect(effect).toEqual(EXPECTED[name]?.presses[`menu-${row}`])
    })
  }
}

// Keys typed on the live page itself, outside a text field, reach peek through the live input layer.
const LIVE_INPUT_KEYS = ['j', 'down', 'k', 'up', ' ', 'pagedown', 'pageup', 'b', 'u', 'v', 'o', 'c', 'f', 'd', 'x']
for (const key of LIVE_INPUT_KEYS) {
  test(`view live: the live page's own key ${JSON.stringify(key)}`, async ($, on) => {
    const { ui, watch, settle } = await SCREENS['view live']!($, on)
    watch.log.splice(0)
    await ui.key({ key, in: 'live-input' })
    await settle()
    const effect = watch.log.map(one => normalized(one, watch.ids))
    await ui.unmount()
    expect(effect).toEqual(EXPECTED['view live']?.presses[`input ${key}`])
  })
}
