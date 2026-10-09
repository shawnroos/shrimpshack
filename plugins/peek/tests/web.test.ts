import { describe, expect, test } from 'claude-code/testing'
import type { HttpResponse, ProcessRunInit, ProcessRunResult } from 'claude-code'

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

const PUBLIC_IP = '93.184.216.34'

type DefuddleFake = { isInstalled?: boolean; installExit?: number; output?: string; parseExit?: number }

function world(options: { pages?: Record<string, Page>; images?: Record<string, number | string>; hasCurl?: boolean; fetch?: (url: string) => HttpResponse; dns?: Record<string, string | null>; defuddle?: DefuddleFake }) {
  const session = `web-${++sessions}`
  const argvs: string[][] = []
  const fetched: string[] = []
  const stdins: string[] = []
  let isInstalled = options.defuddle?.isInstalled ?? false
  const run = async (argv: readonly string[], init?: ProcessRunInit): Promise<ProcessRunResult> => {
    argvs.push([...argv])
    const [bin = ''] = argv
    if (bin === 'test') return exited(isInstalled ? 0 : 1)
    if (bin === 'npm') {
      const exit = options.defuddle?.installExit ?? 0
      if (exit === 0) isInstalled = true
      return exited(exit, '', exit === 0 ? '' : 'npm ERR! network')
    }
    if (bin === 'node') {
      stdins.push(init?.stdin ?? '')
      return exited(options.defuddle?.parseExit ?? 0, options.defuddle?.output ?? '')
    }
    if (bin === 'sh') return exited(0, options.hasCurl === false ? '' : 'curl\n')
    if (bin === '/usr/bin/security') return exited(44, '', 'item not found')
    if (bin === 'mkdir') return exited(0)
    if (bin === '/usr/bin/dscacheutil') {
      const name = argv[argv.length - 1] ?? ''
      const answer = options.dns && name in options.dns ? options.dns[name] : `name: ${name}\nip_address: ${PUBLIC_IP}\n`
      return answer === null || answer === undefined ? exited(1, '', 'lookup failed') : exited(0, answer)
    }
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
    home: async () => (options.defuddle ? '/home' : undefined),
    read: async (path: string) => {
      throw new Error(`ENOENT ${path}`)
    },
    sleep: async () => {},
  }
  const curls = () => argvs.filter(argv => argv[0] === 'curl')
  const downloads = () => curls().filter(argv => argv.includes('-o')).map(argv => argv[argv.length - 1])
  return { io, argvs, curls, downloads, fetched, stdins }
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
    expect(argv.includes('--globoff')).toBe(true)
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

  for (const image of ['http://{a.com,127.0.0.1}/x.png', 'http://[1-2].example/x.png', 'http://a{1,2}.example/x.png']) {
    test(`a curl glob in the image URL ${image} never reaches curl`, async () => {
      const page = `https://glob-${sessions}.test/`
      const { io, curls, downloads } = world({ pages: { [page]: { html: privateImage(image) } }, images: { [image]: 200 } })
      const loaded = await loadWeb(io, web(page), NOW)
      if (!loaded.ok) throw new Error(loaded.failure)
      expect(downloads().some(url => (url ?? '').includes('127.0.0.1') || (url ?? '').includes('a.com') || (url ?? '').includes('.example'))).toBe(false)
      expect(loaded.record.og?.image).toBe(undefined)
      assertProtocolPinned(curls())
    })
  }

  test('every curl the page fetch and image download build carries --globoff', async () => {
    const page = 'https://globoff.test/'
    const { io, curls, downloads } = world({ pages: { [page]: { html: FULL_OG } }, images: { 'https://pets.test/img/card.png': 200 } })
    await loadWeb(io, web(page), NOW)
    expect(downloads().length > 0).toBe(true)
    assertProtocolPinned(curls())
  })

  test('an image host whose name resolves to loopback is never downloaded', async () => {
    const page = 'https://rebind.test/'
    const image = 'https://localtest.me/x.png'
    const { io, downloads } = world({
      pages: { [page]: { html: privateImage(image) } },
      images: { [image]: 200 },
      dns: { 'localtest.me': 'name: localtest.me\nipv6_address: ::1\n\nname: localtest.me\nip_address: 127.0.0.1\n' },
    })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(downloads().includes(image)).toBe(false)
    expect(loaded.record.og?.image).toBe(undefined)
    expect(loaded.record.favicon).toBe(undefined)
  })

  test('a name with one public and one private answer is never downloaded', async () => {
    const page = 'https://mixed.test/'
    const image = 'https://mixed-cdn.test/x.png'
    const { io, downloads } = world({
      pages: { [page]: { html: privateImage(image) } },
      images: { [image]: 200 },
      dns: { 'mixed-cdn.test': `ip_address: ${PUBLIC_IP}\nip_address: 192.168.0.9\n` },
    })
    await loadWeb(io, web(page), NOW)
    expect(downloads().includes(image)).toBe(false)
  })

  test('an image host that resolves publicly is downloaded pinned to the checked address', async () => {
    const page = 'https://pin.test/'
    const image = 'https://cdn.pin.test/x.png'
    const { io, curls } = world({ pages: { [page]: { html: privateImage(image) } }, images: { [image]: 200 } })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    const fetch = curls().find(argv => argv.includes('-o') && argv[argv.length - 1] === image)
    expect(fetch?.[(fetch?.indexOf('--resolve') ?? -2) + 1]).toBe(`cdn.pin.test:443:${PUBLIC_IP}`)
    expect(loaded.record.og?.image?.endsWith('.png')).toBe(true)
  })

  test('an explicit port and an IPv6 answer are pinned in curl --resolve form', async () => {
    const page = 'https://pin6.test/'
    const image = 'http://cdn.pin6.test:8080/x.png'
    const { io, curls } = world({
      pages: { [page]: { html: privateImage(image) } },
      images: { [image]: 200 },
      dns: { 'cdn.pin6.test': 'ipv6_address: 2606:4700::1111\n' },
    })
    await loadWeb(io, web(page), NOW)
    const fetch = curls().find(argv => argv.includes('-o') && argv[argv.length - 1] === image)
    expect(fetch?.[(fetch?.indexOf('--resolve') ?? -2) + 1]).toBe('cdn.pin6.test:8080:[2606:4700::1111]')
  })

  for (const [label, answer] of [['fails', null], ['returns nothing', '']] as const) {
    test(`an image host whose lookup ${label} is never downloaded`, async () => {
      const page = `https://nodns-${sessions}.test/`
      const image = 'https://unresolved.test/x.png'
      const { io, downloads } = world({ pages: { [page]: { html: privateImage(image) } }, images: { [image]: 200 }, dns: { 'unresolved.test': answer } })
      const loaded = await loadWeb(io, web(page), NOW)
      if (!loaded.ok) throw new Error(loaded.failure)
      expect(downloads().includes(image)).toBe(false)
      expect(loaded.record.og?.image).toBe(undefined)
    })
  }

  test('a redirect hop to a name resolving to a private address fetches nothing further', async () => {
    const page = 'https://hop-dns.test/'
    const { io, downloads } = world({
      pages: { [page]: { html: privateImage('https://cdn.hop-dns.test/a.png') } },
      images: { 'https://cdn.hop-dns.test/a.png': 'https://internal.hop-dns.test/x.png', 'https://internal.hop-dns.test/x.png': 200 },
      dns: { 'internal.hop-dns.test': 'ip_address: 10.0.0.5\n' },
    })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(downloads().includes('https://cdn.hop-dns.test/a.png')).toBe(true)
    expect(downloads().includes('https://internal.hop-dns.test/x.png')).toBe(false)
    expect(loaded.record.og?.image).toBe(undefined)
  })

  test('the page the person opens is fetched without a DNS check', async () => {
    const page = 'https://localtest.me/'
    const { io, argvs } = world({ pages: { [page]: { html: TITLE_ONLY } }, dns: { 'localtest.me': 'ip_address: 127.0.0.1\n' } })
    const loaded = await loadWeb(io, web(page), NOW)
    expect(loaded.ok).toBe(true)
    const pageFetch = argvs.find(argv => argv[0] === 'curl' && !argv.includes('-o'))
    expect(pageFetch?.includes('--resolve')).toBe(false)
  })

  test('an HTTP error maps to a fixed failure kind', async () => {
    const page = 'https://gone.test/'
    const { io } = world({ pages: { [page]: { html: 'secret body text', status: 404 } } })
    expect(await loadWeb(io, web(page), NOW)).toEqual({ ok: false, failure: 'not-found-or-no-access', detail: 'HTTP 404 Not Found from gone.test' })
  })

  test('a site that refuses the fetch names the status and the host that sent it', async () => {
    const page = 'https://www.news24.co.za/'
    const { io } = world({ pages: { [page]: { html: 'Forbidden', status: 403, finalUrl: 'https://www.news24.com/' } } })
    expect(await loadWeb(io, web(page), NOW)).toEqual({ ok: false, failure: 'not-found-or-no-access', detail: 'HTTP 403 Forbidden from www.news24.com' })
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
    const loaded = fromCapture(captured('Intro line\n\n## Getting started\n\nBody'), web('https://docs.test/page'))
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
    const loaded = fromCapture(captured('just text'), web('https://docs.test/page'))
    expect(loaded?.ok && loaded.record.title).toBe('docs.test')
  })

  test('an unparseable address normalises to nothing', () => {
    expect(fromCapture(captured('x', 'not a url'), web('not a url'))).toBe(null)
  })
})

describe('reader body through defuddle', () => {
  const page = 'https://site.test/post'
  const html = '<html><head><title>Post</title></head><body><nav>Careers</nav><article><p>Real text.</p></article></body></html>'
  const parsed = (content: string) => JSON.stringify({ title: 'Post', content })

  test('the body is defuddle\'s markdown, with relative links made absolute', async () => {
    const { io, stdins } = world({ pages: { [page]: { html } }, defuddle: { isInstalled: true, output: parsed('Real text. [More](/more) and ![pic](img/a.png) and [top](#top) and [ext](https://x.test/)') } })
    const loaded = await loadWeb(io, web(page), NOW)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(loaded.record.body).toBe('Real text. [More](https://site.test/more) and ![pic](https://site.test/img/a.png) and [top](#top) and [ext](https://x.test/)')
    expect(stdins).toEqual([html])
  })

  test('a missing defuddle is installed once, pinned, with install scripts off', async () => {
    const { io, argvs } = world({ pages: { [page]: { html } }, defuddle: { output: parsed('Real text.') } })
    await loadWeb(io, web(page), NOW)
    await loadWeb(io, web(page), NOW)
    const installs = argvs.filter(argv => argv[0] === 'npm')
    expect(installs.length).toBe(1)
    expect(installs[0]?.includes('--ignore-scripts')).toBe(true)
    expect(installs[0]?.some(arg => /^defuddle@\d+\.\d+\.\d+$/.test(arg))).toBe(true)
  })

  test('a failed install or parse falls back to the built-in reader', async () => {
    for (const defuddle of [{ installExit: 1 }, { isInstalled: true, parseExit: 1 }, { isInstalled: true, output: 'not json' }, { isInstalled: true, output: parsed('') }]) {
      const { io } = world({ pages: { [page]: { html } }, defuddle })
      const loaded = await loadWeb(io, web(page), NOW)
      if (!loaded.ok) throw new Error(loaded.failure)
      expect(loaded.record.body?.includes('Real text.')).toBe(true)
      expect(loaded.record.body?.includes('Careers')).toBe(true)
    }
  })
})
