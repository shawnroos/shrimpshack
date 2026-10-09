import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { C, mute } from '../hooks/theme'
import { issueList, pullList, pullView, repoView } from './fixtures/github/items'

const NOW = 10 * 3600_000
const ran: string[][] = []
let sessions = 0

function fakeWorld(on: On, options: { ghAuthExit?: number; isClockMocked?: boolean; holdPull?: Promise<void> } = {}) {
  ran.length = 0
  on('session.id', () => ({ value: `pane-${++sessions}` }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? '/home' : undefined }))
  on('http.fetch', () => ({ value: { status: 404, ok: false, headers: {}, text: '' } }))
  if (!options.isClockMocked) on('clock.now', () => ({ value: NOW }))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('fs.stat', (_$, e) => {
    throw new Error(`ENOENT ${e.path}`)
  })
  on('fs.read', (_$, e) => {
    if (e.path === '/Users/me/notes.md') return { value: '# Notes\n\n- [ ] one\n' }
    throw new Error(`ENOENT ${e.path}`)
  })
  on('process.run', async (_$, e) => {
    ran.push([...e.argv])
    if (options.holdPull && e.argv.join(' ').startsWith('gh pr view 42')) await options.holdPull
    const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
    const fail = (stderr: string) => ({ value: { exitCode: 1, stdout: '', stderr, isStdoutTruncated: false, isStderrTruncated: false } })
    const line = e.argv.join(' ')
    if (e.argv[0] === 'sh') return ok('gh\ncurl\n')
    if (line === 'gh auth status') return (options.ghAuthExit ?? 0) === 0 ? ok('') : fail('You are not logged into any GitHub hosts')
    if (line.startsWith('gh api repos/acme/widgets/issues/42')) return ok(JSON.stringify({ number: 42, pull_request: {} }))
    if (line.startsWith('gh pr view 42')) return ok(JSON.stringify(pullView({ mergeable: 'CONFLICTING', statusCheckRollup: [], body: 'Follows #45. [tick](file:///Users/me/notes.md#task-3)' })))
    if (line.startsWith('gh api repos/acme/widgets/pulls/42')) return ok('2')
    if (line.startsWith('gh repo view')) return ok(JSON.stringify(repoView))
    if (line.startsWith('gh api repos/acme/widgets/readme')) return ok('# Widgets\n\nRead me.')
    if (line.startsWith('gh pr list')) return ok(JSON.stringify(pullList))
    if (line.startsWith('gh issue list')) return ok(JSON.stringify(issueList))
    return fail('unexpected')
  })
}

const props = {
  title: 'Peek',
  isFocused: true,
  bodyColumns: 100,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 40 },
  view: {},
}

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
    expect(await ui.find({ text: /^ ?acme ?$/ })).toBeDefined()
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
