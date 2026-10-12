import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// A PNG signature and an 800x600 IHDR chunk: the engine checks both before it draws.
const PNG_HEAD = 'iVBORw0KGgoAAAANSUhEUgAAAyAAAAJYCAIAAAAVFBUn'
const TYPE_MARKER = '__peek_type__ '
const MARKER = '__peek_curl__ '

type Served = { status?: number; type?: string; text?: string }

function fileWorld(on: On, served: Record<string, Served>) {
  const ran: string[][] = []
  const copied: string[] = []
  on('ui.copy', (_$, e) => {
    copied.push(e.text)
    return { value: { isCopied: true as const } }
  })
  const files = new Map<string, string>()
  mock.clock(on, { now: 10 * 3600_000 })
  on('session.id', () => ({ value: 'remote-file-pane' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? '/home' : undefined }))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('fs.stat', (_$, e) => {
    if (files.has(e.path)) return { value: { kind: 'file' as const, size: 40, mtimeMs: 9 * 3600_000, isLink: false } }
    throw new Error(`ENOENT ${e.path}`)
  })
  on('fs.read', (_$, e) => {
    if (e.as === 'bytes' && e.path.endsWith('.png')) return { value: { base64: `${PNG_HEAD}AAAA` } }
    const text = files.get(e.path)
    if (text !== undefined) return { value: text }
    throw new Error(`ENOENT ${e.path}`)
  })
  on('http.fetch', () => ({ value: { status: 404, ok: false, headers: {} as Record<string, string>, text: '' } }))
  on('process.run', (_$, e) => {
    ran.push([...e.argv])
    const done = (exitCode: number, stdout = '', stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })
    const [bin = ''] = e.argv
    if (bin === 'sh') return done(0, 'curl\n')
    if (bin === 'test') return done(1)
    if (bin === 'npm') return done(1)
    if (bin === 'sips') return done(0, 'pixelWidth: 800\npixelHeight: 600\n')
    if (bin === '/usr/bin/dscacheutil') return done(0, 'ip_address: 93.184.216.34\n')
    const url = e.argv[e.argv.length - 1] ?? ''
    const answer = served[url]
    if (bin === 'curl' && e.argv.includes('-o')) {
      if (!answer || (answer.status ?? 200) !== 200) return done(22, '404 0 ')
      files.set(e.argv[e.argv.indexOf('-o') + 1] ?? '', answer.text ?? '')
      return done(0, `200 ${(answer.text ?? '').length || 40} `, answer.type ? `${TYPE_MARKER}${answer.type}` : '')
    }
    if (bin === 'curl') return done(0, '<html><head><title>Reader page</title></head><body><p>Reader body</p></body></html>', `${MARKER}200 ${url}`)
    return done(0)
  })
  const downloads = () => ran.filter(argv => argv[0] === 'curl' && argv.includes('-o')).map(argv => argv[argv.length - 1])
  return { ran, downloads, copied }
}

const props = { title: 'Peek', isFocused: true, bodyColumns: 100, placement: 'dock' as const, scroll: { offset: 0, bodyRows: 40 }, view: {} }

test('a markdown file URL downloads and draws like a local markdown file, and keeps the URL as its location', async ($, on) => {
  const url = 'https://files.test/docs/notes.md'
  const w = fileWorld(on, { [url]: { type: 'text/markdown', text: '# Remote notes\n\nHello from afar.\n' } })
  await $.command.run({ command: 'peek', args: url } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /Hello from afar/ })).toBeDefined()
  expect(w.downloads()).toEqual([url])
  expect(JSON.stringify(await ui.drawn())).not.toContain('Reader body')
  await ui.unmount()
  await $.command.run({ command: 'peek-menu' } as never)
  const menu = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await menu.press({ key: 'menu-copy' })
  expect(w.copied).toEqual([url])
  await menu.unmount()
  await $.command.run({ command: 'peek-menu' } as never)
  const again = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await again.press({ key: 'menu-open' })
  expect(w.ran.at(-1)).toEqual(['open', url])
  await again.unmount()
})

test('an image URL downloads and draws as a picture instead of sending you to the browser', async ($, on) => {
  const url = 'https://files.test/shot.png'
  fileWorld(on, { [url]: { type: 'image/png', text: 'png' } })
  await $.command.run({ command: 'peek', args: url } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const tree = JSON.stringify(await ui.drawn())
  expect(tree).toContain(PNG_HEAD)
  expect(tree).not.toContain('Remote images open in the browser')
  await ui.unmount()
})

test('a video URL shows a play button that opens it in the browser, and downloads nothing', async ($, on) => {
  const url = 'https://files.test/clip.mp4'
  const w = fileWorld(on, {})
  await $.command.run({ command: 'peek', args: url } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^VIDEO$/ })).toBeDefined()
  await ui.press({ key: 'media-play-0' })
  expect(w.ran.at(-1)).toEqual(['open', url])
  expect(w.downloads()).toEqual([])
  await ui.unmount()
})

test('a file URL on a private address is never downloaded', async ($, on) => {
  const url = 'http://127.0.0.1/notes.md'
  const w = fileWorld(on, { [url]: { type: 'text/markdown', text: '# Local' } })
  await $.command.run({ command: 'peek', args: url } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(w.downloads()).toEqual([])
  await ui.unmount()
})

test('a GitHub blob URL downloads the raw file', async ($, on) => {
  const blob = 'https://github.com/acme/widgets/blob/main/docs/guide.md'
  const raw = 'https://raw.githubusercontent.com/acme/widgets/main/docs/guide.md'
  const w = fileWorld(on, { [raw]: { type: 'text/plain', text: '# Guide\n\nRaw guide text.\n' } })
  await $.command.run({ command: 'peek', args: blob } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(w.downloads()).toEqual([raw])
  expect(await ui.find({ text: /Raw guide text/ })).toBeDefined()
  await ui.unmount()
})

test('a .md URL that answers with an HTML page falls back to the reader page', async ($, on) => {
  const url = 'https://files.test/page.md'
  fileWorld(on, { [url]: { type: 'text/html; charset=utf-8', text: '<html><body>page</body></html>' } })
  await $.command.run({ command: 'peek', args: url } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^DETAILS$/ })).toBeDefined()
  await ui.unmount()
})
