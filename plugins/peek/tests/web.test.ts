import { describe, expect, test } from 'claude-code/testing'
import type { HttpResponse, ProcessRunResult } from 'claude-code'

import type { Captured } from '../hooks/capture'
import type { Ref } from '../hooks/refs'
import type { SourceIo } from '../hooks/sources'
import { fromCapture, isPrivateHost, loadWeb, parseHead } from '../hooks/web'
import { FULL_OG, HOSTILE, ICO_ICON, NO_ICON, TITLE_ONLY, privateImage } from './fixtures/web/pages'

const NOW = 1_700_000_000_000
const MARKER = '__peek_curl__ '

type Page = { html: string; status?: number; finalUrl?: string; isTruncated?: boolean; exitCode?: number }

let sessions = 0

function exited(exitCode: number, stdout = '', stderr = '', isStdoutTruncated = false): ProcessRunResult {
  return { exitCode, stdout, stderr, isStdoutTruncated, isStderrTruncated: false }
}

function world(options: { pages?: Record<string, Page>; images?: Record<string, number | string>; hasCurl?: boolean; fetch?: (url: string) => HttpResponse }) {
  const session = `web-${++sessions}`
  const argvs: string[][] = []
  const fetched: string[] = []
  const run = async (argv: readonly string[]): Promise<ProcessRunResult> => {
    argvs.push([...argv])
    const [bin = ''] = argv
    if (bin === 'sh') return exited(0, options.hasCurl === false ? '' : 'curl\n')
    if (bin === '/usr/bin/security') return exited(44, '', 'item not found')
    if (bin === 'mkdir') return exited(0)
    if (bin !== 'curl') throw new Error(`spawn ${bin} ENOENT`)
    const url = argv[argv.length - 1] ?? ''
    if (argv.includes('-o')) {
      expect(argv.includes('-L')).toBe(false)
      expect(argv[argv.indexOf('--max-redirs') + 1]).toBe('0')
      const answer = options.images?.[url] ?? 404
      if (typeof answer === 'string') return exited(0, `301 0 ${answer}`)
      return answer === 200 ? exited(0, '200 512 ') : exited(22, `${answer} 0 `)
    }
    const page = options.pages?.[url]
    if (!page) return exited(6)
    const status = page.status ?? 200
    return exited(page.exitCode ?? 0, page.html, `${MARKER}${status} ${page.finalUrl ?? url}`, page.isTruncated ?? false)
  }
  const io: SourceIo = {
    sessionId: async () => session,
    run,
    fetch: async (url: string) => {
      fetched.push(url)
      const answer = options.fetch?.(url)
      if (!answer) throw new Error('fetch failed')
      return answer
    },
    linearKeyEnv: async () => undefined,
    home: async () => undefined,
    read: async (path: string) => {
      throw new Error(`ENOENT ${path}`)
    },
    sleep: async () => {},
  }
  const curls = () => argvs.filter(argv => argv[0] === 'curl')
  const downloads = () => curls().filter(argv => argv.includes('-o')).map(argv => argv[argv.length - 1])
  return { io, argvs, curls, downloads, fetched }
}

function web(address: string): Ref {
  return { kind: 'web', address }
}

function assertProtocolPinned(curls: string[][]) {
  expect(curls.length > 0).toBe(true)
  for (const argv of curls) {
    const proto = argv.indexOf('--proto')
    const redir = argv.indexOf('--proto-redir')
    expect(proto >= 0 && argv[proto + 1] === '=http,https').toBe(true)
    expect(redir >= 0 && argv[redir + 1] === '=http,https').toBe(true)
  }
}

describe('parseHead', () => {
  test('reads Open Graph tags in any attribute order and resolves relative URLs', () => {
    const head = parseHead(FULL_OG, 'https://pets.test/a/b')
    expect(head.title).toBe('Cats & dogs')
    expect(head.description).toBe('All about pets')
    expect(head.siteName).toBe('Pet Site')
    expect(head.image).toBe('https://pets.test/img/card.png')
    expect(head.icons).toEqual(['https://pets.test/static/icon.png', 'https://pets.test/favicon.ico'])
  })

  test('falls back to <title> and the description meta', () => {
    const head = parseHead(TITLE_ONLY, 'https://plain.test/')
    expect(head.title).toBe('Plain page')
    expect(head.description).toBe('A short summary')
    expect(head.siteName).toBe(undefined)
    expect(head.icons).toEqual(['https://plain.test/favicon.ico'])
  })
})

describe('isPrivateHost', () => {
  test('blocks local names and private, loopback, link-local and CGNAT addresses', () => {
    for (const raw of [
      'http://localhost:8080/', 'http://app.localhost/', 'http://printer.local/', 'http://127.0.0.1/', 'http://127.1/', 'http://0x7f000001/',
      'http://10.1.2.3/', 'http://172.16.0.1/', 'http://172.31.255.255/', 'http://192.168.1.1/', 'http://169.254.169.254/',
      'http://0.0.0.0/', 'http://100.64.0.1/', 'http://100.127.255.255/', 'http://[::1]/', 'http://[fe80::1]/', 'http://[fd00::1]/',
      'http://[::ffff:127.0.0.1]/', 'http://[::ffff:10.0.0.1]/', 'http://[::]/', 'http://localhost./',
    ]) {
      expect([raw, isPrivateHost(new URL(raw).hostname)]).toEqual([raw, true])
    }
  })

  test('lets public hosts through', () => {
    for (const raw of ['https://github.com/', 'http://8.8.8.8/', 'http://172.32.0.1/', 'http://100.128.0.1/', 'http://[2606:4700::1111]/', 'https://local.example.com/']) {
      expect([raw, isPrivateHost(new URL(raw).hostname)]).toEqual([raw, false])
    }
  })
})

describe('loadWeb with curl', () => {
  test('full Open Graph tags fill title, site name, description and a downloaded preview image', async () => {
    const page = 'https://pets.test/start'
    const final = 'https://pets.test/a/b'
    const { io, curls, downloads } = world({
      pages: { [page]: { html: FULL_OG, finalUrl: final } },
      images: { 'https://pets.test/img/card.png': 200, 'https://pets.test/static/icon.png': 200 },
    })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    const { record } = loaded
    expect(loaded.tier).toBe('cli')
    expect(loaded.fetchedAt).toBe(NOW)
    expect(record.kind).toBe('web')
    expect(record.address).toBe(page)
    expect(record.browserUrl).toBe(final)
    expect(record.title).toBe('Cats & dogs')
    expect(record.trail).toEqual(['Pet Site'])
    expect(record.og?.title).toBe('Cats & dogs')
    expect(record.og?.description).toBe('All about pets')
    expect(record.og?.siteName).toBe('Pet Site')
    expect(record.og?.image?.startsWith('/tmp/claude-peek/web-')).toBe(true)
    expect(record.og?.image?.endsWith('.png')).toBe(true)
    expect(record.favicon?.startsWith('/tmp/claude-peek/web-')).toBe(true)
    expect(record.body?.includes('Readable text here.')).toBe(true)
    expect(record.body?.includes('var x')).toBe(false)
    expect(downloads()).toEqual(['https://pets.test/img/card.png', 'https://pets.test/static/icon.png'])
    const imageArgv = curls().find(argv => argv.includes('https://pets.test/img/card.png')) ?? []
    expect(imageArgv[imageArgv.indexOf('-o') + 1]).toBe(record.og?.image)
    assertProtocolPinned(curls())
  })

  test('a page with only <title> and a description meta still fills the block', async () => {
    const page = 'https://plain.test/'
    const { io, curls } = world({ pages: { [page]: { html: TITLE_ONLY } } })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(loaded.record.title).toBe('Plain page')
    expect(loaded.record.trail).toEqual(['plain.test'])
    expect(loaded.record.og?.description).toBe('A short summary')
    expect(loaded.record.og?.image).toBe(undefined)
    assertProtocolPinned(curls())
  })

  test('no icon link falls back to /favicon.ico; a 404 there leaves no favicon', async () => {
    const page = 'https://noicon.test/x'
    const { io, downloads } = world({ pages: { [page]: { html: NO_ICON } } })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(downloads()).toEqual(['https://noicon.test/favicon.ico'])
    expect(loaded.record.favicon).toBe(undefined)
  })

  test('an .ico favicon is downloaded with an .ico extension', async () => {
    const page = 'https://ico.test/'
    const { io } = world({ pages: { [page]: { html: ICO_ICON } }, images: { 'https://cdn.ico.test/favicon.ico': 200 } })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(/^\/tmp\/claude-peek\/web-[0-9a-f]{12}\.ico$/.test(loaded.record.favicon ?? '')).toBe(true)
  })

  test('the favicon is fetched once per host', async () => {
    const page = 'https://cached.test/one'
    const other = 'https://cached.test/two'
    const { io, downloads } = world({
      pages: { [page]: { html: NO_ICON }, [other]: { html: NO_ICON } },
      images: { 'https://cached.test/favicon.ico': 200 },
    })
    const first = await loadWeb(io, web(page), NOW)
    const second = await loadWeb(io, web(other), NOW)
    if (!first.ok || !second.ok) throw new Error('failed')
    expect(second.record.favicon).toBe(first.record.favicon)
    expect(downloads()).toEqual(['https://cached.test/favicon.ico'])
  })

  test('a page larger than 4 MB is cut, not failed', async () => {
    const page = 'https://huge.test/'
    const html = `<html><head><title>Huge</title></head><body>${'a'.repeat(4_194_304)}`
    const { io } = world({ pages: { [page]: { html, isTruncated: true } } })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(loaded.record.title).toBe('Huge')
    expect((loaded.record.body?.length ?? 0) <= 4_194_304).toBe(true)
  })

  test('file: and gopher: image and icon URLs are never fetched', async () => {
    const page = 'https://hostile.test/'
    const { io, argvs, curls } = world({ pages: { [page]: { html: HOSTILE } } })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(argvs.some(argv => argv.some(arg => arg.includes('file:') || arg.includes('gopher:')))).toBe(false)
    expect(loaded.record.og?.image).toBe(undefined)
    expect(loaded.record.favicon).toBe(undefined)
    assertProtocolPinned(curls())
  })

  for (const image of ['http://192.168.1.1/x.png', 'http://localhost:8080/a.png']) {
    test(`a public page never fetches the private image ${image}`, async () => {
      const page = `https://public-${sessions}.test/`
      const { io, argvs } = world({ pages: { [page]: { html: privateImage(image) } }, images: { [image]: 200 } })
      const loaded = await loadWeb(io, web(page), NOW)
      if (!loaded.ok) throw new Error(loaded.failure)
      expect(argvs.some(argv => argv.includes(image))).toBe(false)
      expect(loaded.record.og?.image).toBe(undefined)
      expect(loaded.record.favicon).toBe(undefined)
    })
  }

  test('an image redirect is followed by hand, and a hop to a private host fetches nothing further', async () => {
    const page = 'https://hops.test/'
    const { io, downloads } = world({
      pages: { [page]: { html: privateImage('https://cdn.hops.test/a.png') } },
      images: { 'https://cdn.hops.test/a.png': 'http://127.0.0.1/x.png', 'http://127.0.0.1/x.png': 200 },
    })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(downloads().includes('http://127.0.0.1/x.png')).toBe(false)
    expect(loaded.record.og?.image).toBe(undefined)
  })

  test('a public redirect hop is followed to the image', async () => {
    const page = 'https://hop-ok.test/'
    const { io, downloads } = world({
      pages: { [page]: { html: privateImage('/start.png') } },
      images: { 'https://hop-ok.test/start.png': '/final.png', 'https://hop-ok.test/final.png': 200 },
    })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(downloads().slice(0, 2)).toEqual(['https://hop-ok.test/start.png', 'https://hop-ok.test/final.png'])
    expect(loaded.record.og?.image?.endsWith('.png')).toBe(true)
  })

  test('redirects stop after five hops with no file', async () => {
    const page = 'https://loop.test/'
    const { io, downloads } = world({
      pages: { [page]: { html: privateImage('/a.png') } },
      images: { 'https://loop.test/a.png': '/b.png', 'https://loop.test/b.png': '/a.png' },
    })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(loaded.record.og?.image).toBe(undefined)
    expect(downloads().filter(url => url === 'https://loop.test/a.png' || url === 'https://loop.test/b.png').length <= 12).toBe(true)
  })

  test('an HTTP error maps to a fixed failure kind', async () => {
    const page = 'https://gone.test/'
    const { io } = world({ pages: { [page]: { html: 'secret body text', status: 404 } } })
    expect(await loadWeb(io, web(page), NOW)).toEqual({ ok: false, failure: 'not-found-or-no-access' })
  })

  test('an unreachable host is offline', async () => {
    const { io } = world({})
    expect(await loadWeb(io, web('https://nowhere.test/'), NOW)).toEqual({ ok: false, failure: 'offline' })
  })

  test('a non-http address is refused without running anything', async () => {
    const { io, curls } = world({})
    expect(await loadWeb(io, web('file:///etc/passwd'), NOW)).toEqual({ ok: false, failure: 'query-bug' })
    expect(curls()).toEqual([])
  })
})

describe('loadWeb without curl', () => {
  test('draws from httpText with no favicon and no preview image', async () => {
    const page = 'https://nocurl.test/'
    const { io, curls, fetched } = world({
      hasCurl: false,
      fetch: () => ({ status: 200, ok: true, headers: {}, text: FULL_OG }),
    })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(loaded.tier).toBe('api')
    expect(fetched).toEqual([page])
    expect(curls()).toEqual([])
    expect(loaded.record.title).toBe('Cats & dogs')
    expect(loaded.record.og?.siteName).toBe('Pet Site')
    expect(loaded.record.og?.image).toBe(undefined)
    expect(loaded.record.favicon).toBe(undefined)
  })
})

describe('fromCapture', () => {
  function captured(result: string, address = 'https://docs.test/page'): Captured {
    return { address, kind: 'web', source: 'webfetch', tool: 'WebFetch', args: { url: address }, result, at: NOW - 5000 }
  }

  test('a WebFetch result shows its text with the first heading as title', () => {
    const loaded = fromCapture(captured('Intro line\n\n## Getting started\n\nBody'), web('https://docs.test/page'), NOW)
    if (!loaded?.ok) throw new Error('no record')
    expect(loaded.tier).toBe('session')
    expect(loaded.fetchedAt).toBe(NOW - 5000)
    expect(loaded.record.title).toBe('Getting started')
    expect(loaded.record.trail).toEqual(['docs.test'])
    expect(loaded.record.body?.includes('Intro line')).toBe(true)
    expect(loaded.record.og).toBe(undefined)
    expect(loaded.record.favicon).toBe(undefined)
  })

  test('without a heading the host is the title', () => {
    const loaded = fromCapture(captured('just text'), web('https://docs.test/page'), NOW)
    expect(loaded?.ok && loaded.record.title).toBe('docs.test')
  })

  test('an unparseable address normalises to nothing', () => {
    expect(fromCapture(captured('x', 'not a url'), web('not a url'), NOW)).toBe(null)
  })
})
