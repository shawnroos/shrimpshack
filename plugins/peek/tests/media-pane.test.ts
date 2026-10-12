import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { hoverLayers } from './fixtures/overlay'
import { exited } from './fixtures/results'
import { CURL_MARKER, PANE_PROPS, PNG_HEAD, baseWorld, fakeHttp, fakeProcess, noDisk } from './fixtures/world'

const PAGE = 'https://site.test/post'
const VIDEO = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
const CONTENT = ['Intro text for the post.', '', `![](${VIDEO})`, '', 'Closing text.', '', '![A diagram](https://site.test/missing.png)'].join('\n')

function mediaWorld(on: On, options: { content?: string; pngBytes?: number } = {}) {
  const ran: string[][] = []
  mock.clock(on, { now: 10 * 3600_000 })
  on('session.id', () => ({ value: 'media-pane' }))
  baseWorld(on)
  noDisk(on)
  on('fs.read', (_$, e) => {
    if (options.pngBytes && e.as === 'bytes' && e.path.endsWith('.png')) return { value: { base64: `${PNG_HEAD}${'A'.repeat(options.pngBytes - PNG_HEAD.length)}` } }
    throw new Error(`ENOENT ${e.path}`)
  })
  fakeHttp(on)
  fakeProcess(
    on,
    argv => {
      const [bin = ''] = argv
      if (bin === 'sh') return exited(0, 'curl\n')
      if (bin === 'test') return exited(0)
      if (bin === 'node') return exited(0, JSON.stringify({ content: options.content ?? CONTENT }))
      if (bin === 'sips') return exited(0, 'pixelWidth: 800\npixelHeight: 600\n')
      if (bin === '/usr/bin/dscacheutil') return exited(0, 'ip_address: 93.184.216.34\n')
      if (bin === 'curl' && argv.includes('-o')) return options.pngBytes ? exited(0, '200 512 ') : exited(22, '404 0 ')
      if (bin === 'curl') return exited(0, '<html><head><title>Post</title><meta property="og:description" content="About the post"></head><body><p>Intro</p></body></html>', `${CURL_MARKER}200 ${PAGE}`)
      return exited(0)
    },
    ran,
  )
  return { ran }
}

const props = PANE_PROPS

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

test('a page with more image data than one pane can carry links the overflow instead of failing to draw', async ($, on) => {
  const content = Array.from({ length: 6 }, (_, i) => `Para ${i}.\n\n![shot ${i}](https://site.test/s${i}.png)`).join('\n\n')
  mediaWorld(on, { content, pngBytes: 600_000 })
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const tree = JSON.stringify(await ui.drawn())
  const inline = tree.split(PNG_HEAD).length - 1
  expect(inline * 600_000 <= 2_097_152).toBe(true)
  expect(inline > 0).toBe(true)
  expect(tree.includes('https://site.test/s5.png')).toBe(true)
  await ui.unmount()
})

test('Recent and Gallery keep the hover star layer of a media page last in the parent', async ($, on) => {
  mediaWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^VIDEO$/ })).toBeDefined()
  await ui.press({ key: 'mode-recent' })
  const recent = hoverLayers(await ui.drawn())
  expect(recent.onTop).toContain('hover-touched-0')
  expect(recent.buried).toEqual([])
  await ui.press({ key: 'mode-gallery' })
  const gallery = hoverLayers(await ui.drawn())
  expect(gallery.onTop).toContain('hover-touched-0')
  expect(gallery.buried).toEqual([])
  await ui.unmount()
})
