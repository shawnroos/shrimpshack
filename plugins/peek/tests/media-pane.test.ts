import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const PAGE = 'https://site.test/post'
const MARKER = '__peek_curl__ '
const VIDEO = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
const CONTENT = ['Intro text for the post.', '', `![](${VIDEO})`, '', 'Closing text.', '', '![A diagram](https://site.test/missing.png)'].join('\n')

function mediaWorld(on: On) {
  const ran: string[][] = []
  mock.clock(on, { now: 10 * 3600_000 })
  on('session.id', () => ({ value: 'media-pane' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? '/home' : undefined }))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('fs.stat', (_$, e) => {
    throw new Error(`ENOENT ${e.path}`)
  })
  on('fs.read', (_$, e) => {
    throw new Error(`ENOENT ${e.path}`)
  })
  on('http.fetch', () => ({ value: { status: 404, ok: false, headers: {} as Record<string, string>, text: '' } }))
  on('process.run', (_$, e) => {
    ran.push([...e.argv])
    const done = (exitCode: number, stdout = '', stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })
    const [bin = ''] = e.argv
    if (bin === 'sh') return done(0, 'curl\n')
    if (bin === 'test') return done(0)
    if (bin === 'node') return done(0, JSON.stringify({ content: CONTENT }))
    if (bin === '/usr/bin/dscacheutil') return done(0, 'ip_address: 93.184.216.34\n')
    if (bin === 'curl' && e.argv.includes('-o')) return done(22, '404 0 ')
    if (bin === 'curl') return done(0, '<html><head><title>Post</title><meta property="og:description" content="About the post"></head><body><p>Intro</p></body></html>', `${MARKER}200 ${PAGE}`)
    return done(0)
  })
  return { ran }
}

const props = { title: 'Peek', isFocused: true, bodyColumns: 100, placement: 'dock' as const, scroll: { offset: 0, bodyRows: 40 }, view: {} }

test('a video in a reader page shows a play button that opens it in the browser', async ($, on) => {
  const w = mediaWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /Intro text for the post/ })).toBeDefined()
  expect(await ui.find({ text: /^VIDEO$/ })).toBeDefined()
  expect(await ui.find({ text: /Closing text/ })).toBeDefined()
  await ui.press({ key: 'media-play-0' })
  expect(w.ran.at(-1)).toEqual(['open', VIDEO])
  await ui.unmount()
})

test('an image that could not be downloaded stays a link to it', async ($, on) => {
  mediaWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^IMAGE$/ })).toBeDefined()
  expect(JSON.stringify(await ui.drawn()).includes('https://site.test/missing.png')).toBe(true)
  await ui.unmount()
})

test('the page description sits inside the DETAILS block; there is no separate PREVIEW block', async ($, on) => {
  mediaWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^PREVIEW$/ })).toBeUndefined()
  const details = await ui.find({ key: 'remote-meta' })
  expect(JSON.stringify(details).includes('About the post')).toBe(true)
  await ui.unmount()
})
