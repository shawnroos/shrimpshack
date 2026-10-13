import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { C, META_ICON, mute } from '../hooks/theme'
import { issueList, pullList, pullView, repoView } from './fixtures/github/items'
import { hoverLayers } from './fixtures/overlay'
import { exited } from './fixtures/results'
import { PANE_PROPS, baseWorld, fakeHttp, fakeProcess, noDisk } from './fixtures/world'

const NOW = 10 * 3600_000
const ran: string[][] = []
let sessions = 0

function fakeWorld(on: On, options: { ghAuthExit?: number; isClockMocked?: boolean; holdPull?: Promise<void>; pull?: Record<string, unknown>; mermaid?: string } = {}) {
  ran.length = 0
  on('session.id', () => ({ value: `pane-${++sessions}` }))
  baseWorld(on)
  fakeHttp(on)
  if (!options.isClockMocked) on('clock.now', () => ({ value: NOW }))
  noDisk(on)
  on('fs.read', (_$, e) => {
    if (e.path === '/Users/me/notes.md') return { value: '# Notes\n\n- [ ] one\n' }
    throw new Error(`ENOENT ${e.path}`)
  })
  fakeProcess(
    on,
    async argv => {
      if (options.holdPull && argv.join(' ').startsWith('gh pr view 42')) await options.holdPull
      const ok = (stdout: string) => exited(0, stdout)
      const fail = (stderr: string) => exited(1, '', stderr)
      const line = argv.join(' ')
      if (argv[0] === 'sh') return ok('gh\ncurl\n')
      if (argv[0] === '/home/.cache/claude-peek/bin/mermaid-ascii') return options.mermaid ? ok(options.mermaid) : fail('no')
      if (line === 'gh auth status') return (options.ghAuthExit ?? 0) === 0 ? ok('') : fail('You are not logged into any GitHub hosts')
      if (line.startsWith('gh api repos/acme/widgets/issues/42')) return ok(JSON.stringify({ number: 42, pull_request: {} }))
      if (line.startsWith('gh pr view 42')) return ok(JSON.stringify(pullView({ mergeable: 'CONFLICTING', statusCheckRollup: [], body: 'Follows #45. [tick](file:///Users/me/notes.md#task-3)', ...options.pull })))
      if (line.startsWith('gh api repos/acme/widgets/pulls/42')) return ok('2')
      if (line.startsWith('gh repo view')) return ok(JSON.stringify(repoView))
      if (line.startsWith('gh api repos/acme/widgets/readme')) return ok('# Widgets\n\nRead me.')
      if (line.startsWith('gh pr list')) return ok(JSON.stringify(pullList))
      if (line.startsWith('gh issue list')) return ok(JSON.stringify(issueList))
      return fail('unexpected')
    },
    ran,
  )
}


// Crumbs that link somewhere are drawn by a Client module, so their words live in its props.
async function trailHas(ui: { find: (q: { key: string }) => Promise<{ props: unknown } | undefined> }, pattern: RegExp) {
  const crumbs = await ui.find({ key: 'crumbs' })
  const segments = (crumbs?.props as { props?: { segments?: { text: string }[] } } | undefined)?.props?.segments ?? []
  return segments.some(one => pattern.test(one.text))
}

const props = PANE_PROPS

test('a pull request draws title, details, the CI line and comments, on terminal and desktop', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42/files#r1' } as never)
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'peek', surface, component: 'Pane', props, requestId: 'peek' })
    expect(await ui.find({ text: /#42 Teach the parser trailing commas/ })).toBeDefined()
    expect(await ui.find({ text: /^DETAILS$/ })).toBeDefined()
    expect(await ui.find({ text: 'checks not running: merge conflict' })).toBeDefined()
    expect(await ui.find({ text: /^\+120$/ })).toBeDefined()
    expect(await ui.find({ text: /^COMMENTS $/ })).toBeDefined()
    expect(await ui.find({ text: /3 · 2 inline/ })).toBeDefined()
    expect(await ui.find({ text: /via gh · 0s ago/ })).toBeDefined()
    expect(await ui.find({ key: 'refresh' })).toBeDefined()
    expect(await trailHas(ui, /^ ?\u{f09b} acme ?$/u)).toBe(true)
    await ui.unmount()
  }
})

test('covers AE6: gh signed out says to run gh auth login and offers Open in browser, no raw error', async ($, on) => {
  fakeWorld(on, { ghAuthExit: 1 })
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: 'GitHub CLI is not signed in' })).toBeDefined()
  expect(await ui.find({ text: /gh auth login/ })).toBeDefined()
  expect(await ui.find({ text: /not logged into/ })).toBeUndefined()
  expect((await ui.find({ key: 'open' }))?.text).toMatch(/Open in browser/)
  await ui.unmount()
})

test('a repo page lists pull requests before the README; a row opens its pull request', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^PULL REQUESTS $/ })).toBeDefined()
  expect(await ui.find({ text: / 2 of 41$/ })).toBeDefined()
  expect(await ui.find({ text: /showing 2 of 41/ })).toBeDefined()
  expect(await ui.find({ text: /^README $/ })).toBeDefined()
  const tree = JSON.stringify(await ui.drawn())
  expect(tree.indexOf('PULL REQUESTS')).toBeLessThan(tree.indexOf('README'))
  await ui.press({ key: 'list-item-0-0' })
  expect(ran.some(argv => argv.join(' ').startsWith('gh pr view 41'))).toBe(true)
  await ui.unmount()
})

test('Recent rows for remote pages keep their hover star layer last in the parent', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  const layers = hoverLayers(await ui.drawn())
  expect(layers.onTop).toContain('hover-touched-0')
  expect(layers.buried).toEqual([])
  await ui.press({ key: 'mode-gallery' })
  const gallery = hoverLayers(await ui.drawn())
  expect(gallery.onTop).toContain('hover-touched-0')
  expect(gallery.buried).toEqual([])
  await ui.unmount()
})

test('pressing u reloads a remote page; a doc page has no u key', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const before = ran.filter(argv => argv.join(' ').startsWith('gh pr view 42')).length
  await ui.press({ key: 'refresh' })
  expect(ran.filter(argv => argv.join(' ').startsWith('gh pr view 42')).length).toBe(before + 1)
  await ui.unmount()
})

test('with the menu open, a remote page dims like a doc page', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  await $.command.run({ command: 'peek-menu' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /Refresh this page/ })).toBeDefined()
  expect((await ui.find({ text: /^DETAILS$/ }))?.props.color).toBe(mute(C.green))
  await ui.unmount()
})

test('covers AE5: an open pull request on screen reloads after 60 seconds, not before', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  fakeWorld(on, { isClockMocked: true })
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  await $.session.append({ message: { type: 'user', content: [{ type: 'text', text: 'still here' }] } } as never).catch(() => undefined)
  const loads = () => ran.filter(argv => argv.join(' ').startsWith('gh pr view 42')).length
  const first = loads()
  await clock.advance(45_000)
  expect(loads()).toBe(first)
  await clock.advance(30_000)
  expect(loads()).toBe(first + 1)
})

const reply = (text: string) => ({ result: [{ type: 'text', text }], text })

test('/peek resolves references without asking the model: owner/repo#N and a captured Linear ID', async ($, on) => {
  fakeWorld(on)
  let forks = 0
  on('model.fork', () => {
    forks += 1
    throw new Error('no model in this test')
  })
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', async () => reply(JSON.stringify({ identifier: 'WEB-2757', title: 'Remove Logo', url: 'https://linear.app/acme/issue/WEB-2757/remove-logo' })) as never)
  await $.tool.call({ tool: 'mcp__claude_ai_Linear__get_issue', tool_use_id: 't1', id: 'WEB-2757' } as never)
  await $.command.run({ command: 'peek', args: 'WEB-2757' } as never)
  let ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /WEB-2757 Remove Logo/ })).toBeDefined()
  expect(await ui.find({ text: /from this session/ })).toBeDefined()
  await ui.unmount()
  await $.command.run({ command: 'peek', args: 'acme/widgets#42' } as never)
  ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /#42 Teach the parser/ })).toBeDefined()
  expect(forks).toBe(0)
  await ui.unmount()
})

test('starring a pull request URL and then owner/repo#N leaves one star', async ($, on) => {
  fakeWorld(on)
  const saved: unknown[] = []
  on('store.set', (_$, e) => {
    if (e.key === 'stars') saved.push(e.value)
    return { value: undefined }
  })
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__peek__star', tool_use_id: 's1', target: 'https://github.com/acme/widgets/pull/42/files' } as never)
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__peek__star', tool_use_id: 's2', target: 'acme/widgets#42' } as never)
  expect(saved.at(-1)).toEqual(['https://github.com/acme/widgets/pull/42'])
})

test('Recent labels a pull request with its title, owner/repo and state, not a size', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  expect(await ui.find({ text: /#42 Teach the parser/ })).toBeDefined()
  expect(await ui.find({ text: /acme\/widgets/ })).toBeDefined()
  expect(await ui.find({ text: /^open · / })).toBeDefined()
  expect(await ui.find({ text: / B$/ })).toBeUndefined()
  await ui.unmount()
})

test('a #N link inside a pull request opens against that repo; b returns to the page it came from', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  let ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(JSON.stringify(await ui.drawn())).toContain('[#45](https://github.com/acme/widgets/issues/45)')
  expect(await ui.find({ key: 'back' })).toBeUndefined()
  await ui.unmount()
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets' } as never)
  ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'list-item-0-0' })
  await ui.unmount()
  ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^PULL REQUESTS $/ })).toBeUndefined()
  await ui.press({ key: 'back' })
  await ui.unmount()
  ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^PULL REQUESTS $/ })).toBeDefined()
  await ui.unmount()
})

test('a slow page that finishes after a newer one was opened never replaces it', async ($, on) => {
  let release = () => {}
  const holdPull = new Promise<void>(resolve => {
    release = resolve
  })
  fakeWorld(on, { holdPull })
  const slow = $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets' } as never)
  release()
  await slow
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^PULL REQUESTS $/ })).toBeDefined()
  expect(await ui.find({ text: /#42 Teach the parser/ })).toBeUndefined()
  await ui.unmount()
})

test('a task link inside a remote page never ticks a local file', async ($, on) => {
  fakeWorld(on)
  const writes: string[] = []
  on('fs.write', (_$, e) => {
    writes.push(e.path)
    return { value: undefined }
  })
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'body-md-0', link: { href: 'file:///Users/me/notes.md#task-3' } } as never)
  expect(writes).toEqual([])
  await ui.unmount()
})

test('a narrow header shortens the trail without cutting into its names', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...props, bodyColumns: 70 }, requestId: 'peek' })
  const tree = JSON.stringify(await ui.drawn())
  expect(tree).not.toMatch(/"ac…/)
  expect(tree).toContain('\u{f09b}')
  await ui.unmount()
})

test('the details block labels each row with a Nerd Font icon instead of a word', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: META_ICON.Author })).toBeDefined()
  expect(await ui.find({ text: META_ICON.Branch })).toBeDefined()
  expect(await ui.find({ text: /^Author\s*$/ })).toBeUndefined()
  await ui.unmount()
})

test('/peek with a lowercase Linear ID opens that issue, never a recent one', async ($, on) => {
  fakeWorld(on)
  let forks = 0
  on('model.fork', () => {
    forks += 1
    throw new Error('no model in this test')
  })
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', async () => reply(JSON.stringify({ identifier: 'WEB-2760', title: 'Lowercase', url: 'https://linear.app/acme/issue/WEB-2760/lowercase' })) as never)
  await $.tool.call({ tool: 'mcp__claude_ai_Linear__get_issue', tool_use_id: 'l1', id: 'WEB-2760' } as never)
  const out = (await $.command.run({ command: 'peek', args: 'web-2799' } as never)) as { text?: string }
  expect(out.text).toContain('https://linear.app/acme/issue/WEB-2799')
  expect(forks).toBe(0)
})

test('/peek naming a website the session never saw asks the model and opens the homepage it names', async ($, on) => {
  fakeWorld(on)
  const prompts: string[] = []
  on('model.fork', (_$, e) => {
    prompts.push(String((e as { prompt?: unknown }).prompt))
    return { value: { isAnswered: true, text: 'https://www.nytimes.com' } } as never
  })
  const out = (await $.command.run({ command: 'peek', args: 'add Nytimes website' } as never)) as { text?: string }
  expect(prompts[0]).toMatch(/homepage/i)
  expect(out.text).toContain('https://www.nytimes.com')
})

test('pictures in a pull request body and its comments draw as embeds; one that cannot download is a link', async ($, on) => {
  fakeWorld(on, {
    pull: {
      body: 'Before.\n\n![shot](https://cdn.test/body.png)\n\nAfter.',
      comments: [{ author: { login: 'a' }, body: 'Here:\n\n![later](https://cdn.test/comment.png)', createdAt: '2026-09-01T11:00:00Z' }],
    },
  })
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^ shot$/ })).toBeDefined()
  expect(await ui.find({ text: /^ later$/ })).toBeDefined()
  const tree = JSON.stringify(await ui.drawn())
  expect(tree).toContain('[open image](https://cdn.test/comment.png)')
  expect(tree.indexOf('COMMENTS')).toBeLessThan(tree.indexOf('[open image](https://cdn.test/comment.png)'))
  expect(tree).not.toContain('![later]')
  await ui.unmount()
})

test('a mermaid fence in a pull request body draws as a diagram', async ($, on) => {
  fakeWorld(on, { pull: { body: 'Flow:\n\n```mermaid\ngraph TD\n  A --> B\n```\n' }, mermaid: '+---+     +---+\n| A | --> | B |\n+---+     +---+\n' })
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^DIAGRAM$/ })).toBeDefined()
  expect(await ui.find({ text: /\| A \| --> \| B \|/ })).toBeDefined()
  expect(ran.some(argv => argv[0] === '/home/.cache/claude-peek/bin/mermaid-ascii')).toBe(true)
  await ui.unmount()
})

test('a table in a pull request body draws as aligned columns, and a table in a fence stays code', async ($, on) => {
  fakeWorld(on, { pull: { body: 'Plan:\n\n| Step | Days |\n|---|---:|\n| Build | 3 |\n\n```\n| raw | pipe |\n|---|---|\n```\n' } })
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const page = JSON.stringify(await ui.drawn())
  expect(page).toMatch(/\["Step +Days"\]/)
  expect(page).toMatch(/\["Build +   3"\]/)
  expect(page).not.toContain('| Step |')
  expect(page).toContain('| raw | pipe |')
  await ui.unmount()
})

test('task lists in a pull request body draw as a checklist: no bullet, continuation lines joined, done struck, fenced kept', async ($, on) => {
  fakeWorld(on, { pull: { body: 'Follow-ups:\n\n- [ ] P2 \u2014 split `remoteBody`\n  into module functions.\n  - [X] nested done\n* [x] shipped\n\nAfter.\n\n```\n- [ ] in a fence\n```\n' } })
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const page = JSON.stringify(await ui.drawn())
  expect(page).toContain('"text":"P2 \u2014 split `remoteBody` into module functions."')
  expect(page).toContain('"text":"~~nested done~~"')
  expect(page).toContain('"text":"~~shipped~~"')
  expect(page).toContain('"marginLeft":2')
  expect(page).toContain('\u{f0131} ')
  expect(page).toContain('\u{f0135} ')
  expect(page).not.toMatch(/[-*] (\[[ xX]\]|\u{f0131}|\u{f0135}) (P2|nested|shipped)/u)
  expect(page).toContain('- [ ] in a fence')
  expect(page).toContain('After.')
  await ui.unmount()
})

test('bullet lists in a pull request body draw with an accent arrow, nested ones indented; numbered lists stay as written', async ($, on) => {
  fakeWorld(on, { pull: { body: 'Notes:\n\n- first point\n  wraps here\n  - nested point\n* star point\n\n1. numbered\n\n---\n' } })
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const page = JSON.stringify(await ui.drawn())
  expect(page).toContain(`"color":"${C.accent}"},"children":["\u23f5 "]`)
  expect(page).toContain('"text":"first point wraps here"')
  expect(page).toContain('"text":"nested point"')
  expect(page).toContain('"text":"star point"')
  expect(page).toContain('"marginLeft":2')
  expect(page).not.toMatch(/"text":"[^"]*- first point/)
  expect(page).toMatch(/1\. numbered/)
  await ui.unmount()
})

test('a task line already linked to a local file inside a pull request body draws read-only, never as a tickable task', async ($, on) => {
  fakeWorld(on, { pull: { body: '- [\u{f0131}](file:///Users/me/notes.md#task-3) linked task\n' } })
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const page = JSON.stringify(await ui.drawn())
  expect(page).toContain('"text":"linked task"')
  expect(page).not.toContain('tasks.tsx')
  expect(page).not.toContain('"key":"task-3"')
  await ui.unmount()
})

test('a pull request trail links its owner and repo crumbs; the page crumb has no link', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const crumbs = await ui.find({ key: 'crumbs' })
  expect((crumbs?.props as { props: { presses: unknown[] } }).props.presses).toEqual([{ go: 'https://github.com/acme' }, { go: 'https://github.com/acme/widgets' }, null])
  await ui.unmount()
})

test('Recent and Gallery match a star by its stored href, so a star saved as /issues/42 does not star the /pull/42 entry', async ($, on) => {
  fakeWorld(on)
  const issue = 'https://github.com/acme/widgets/issues/42'
  const pull = 'https://github.com/acme/widgets/pull/42'
  await $.command.run({ command: 'peek', args: pull } as never)
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__peek__star', tool_use_id: 's1', target: issue } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const layerItems = async (key: string) => ((await ui.find({ key }))?.props.props as { items: unknown[] } | undefined)?.items

  await ui.press({ key: 'mode-recent' })
  expect(await ui.find({ text: /1 favourites · 1 files · session/ })).toBeDefined()
  expect((await ui.find({ key: 'item-0' }))?.props.label).toBe('\u{f51a}')
  expect((await ui.find({ key: 'item-1' }))?.props.label).not.toBe('\u{f51a}')
  expect(await layerItems('hover-favs-0')).toEqual([{ href: issue, isStarred: true }])
  expect(await layerItems('hover-touched-0')).toEqual([{ href: pull, isStarred: false }])

  await ui.press({ key: 'mode-gallery' })
  expect(await ui.find({ text: /2 files · session/ })).toBeDefined()
  expect((await ui.find({ key: 'item-0' }))?.props.label).toBe('\u{f51a}')
  expect((await ui.find({ key: 'item-1' }))?.props.label).not.toBe('\u{f51a}')
  expect(await layerItems('hover-favs-0')).toEqual([{ href: issue, isStarred: true }])
  expect(await layerItems('hover-touched-0')).toEqual([{ href: pull, isStarred: false }])

  await ui.press({ key: 'mode-view' })
  expect(await ui.find({ text: /\u{f51a} starred/u })).toBeDefined()
  await ui.unmount()
})
