import { describe, expect, test } from 'claude-code/testing'

import { loadRecipe } from '../hooks/recipes'
import { failureText, runRecipe } from '../hooks/recipe-run'
import type { RunOutcome } from '../hooks/recipe-run'
import { PAGE_RESULT, PAGE_RESULT_PAGE, structuredResult, TOOL_ERROR, textResult } from './fixtures/mcp'
import { HOME, mcpFolder, PAGE, ROOT, scriptFolder, world } from './fixtures/recipes/world'
import type { World } from './fixtures/recipes/world'

const LINK = 'https://figma.com/file/abc/Design'
const DIR = `${ROOT}/figma-files`
const SCRIPT = `${DIR}/fetch.sh`

async function run(w: World, options: { draft?: boolean; id?: string; digest?: string; link?: string } = {}): Promise<RunOutcome> {
  const id = options.id ?? 'figma-files'
  const loaded = await loadRecipe(w.io, ROOT, id)
  if (!loaded.ok) throw new Error(`${id} did not load: ${JSON.stringify(loaded.problems)}`)
  return runRecipe(w.io, { root: ROOT, id, digest: options.digest ?? loaded.digest, draft: options.draft ?? false }, options.link ?? LINK)
}

function failed<K extends Exclude<RunOutcome, { ok: true }>['kind']>(outcome: RunOutcome, kind: K): Extract<RunOutcome, { kind: K }> {
  if (outcome.ok || outcome.kind !== kind) throw new Error(`expected ${kind}, got ${JSON.stringify(outcome)}`)
  return outcome as Extract<RunOutcome, { kind: K }>
}

describe('runRecipe: script source', () => {
  test('a script printing a valid page returns the checked page', async () => {
    const w = world({ files: scriptFolder('figma-files') })
    const outcome = await run(w)
    if (!outcome.ok) throw new Error(JSON.stringify(outcome))
    expect(outcome.page).toEqual(PAGE)
    expect(outcome.name).toBe('Figma files')
    expect(w.calls.run).toHaveLength(1)
  })

  test('runs through env -i in the recipe folder with the link last and in PEEK_URL', async () => {
    const w = world({ files: scriptFolder('figma-files', { run: ['./fetch.sh', '--mode', 'full'] }) })
    await run(w)
    const [call] = w.calls.run
    expect(call?.argv.slice(0, 2)).toEqual(['/usr/bin/env', '-i'])
    expect(call?.init?.cwd).toBe(DIR)
    expect(call?.init?.timeoutMs).toBe(20_000)
    const [child] = w.calls.children
    expect(child?.argv).toEqual([SCRIPT, '--mode', 'full', LINK])
    expect(child?.env).toEqual({ HOME, PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8', TMPDIR: '/tmp/u/', PEEK_URL: LINK })
  })

  test('a session secret never reaches the script unless the recipe declares it', async () => {
    const env = { LINEAR_API_KEY: 'lin_api_SECRET123', OTHER: 'x' }
    const plain = world({ files: scriptFolder('figma-files'), env })
    await run(plain)
    expect(plain.calls.children[0]?.env.LINEAR_API_KEY).toBeUndefined()
    expect(JSON.stringify(plain.calls.run[0])).not.toContain('lin_api_SECRET123')

    const declared = world({ files: scriptFolder('figma-files', { env: ['LINEAR_API_KEY', 'MISSING_ONE'] }), env })
    await run(declared)
    expect(declared.calls.children[0]?.env.LINEAR_API_KEY).toBe('lin_api_SECRET123')
    expect(declared.calls.children[0]?.env.OTHER).toBeUndefined()
    expect('MISSING_ONE' in (declared.calls.children[0]?.env ?? {})).toBe(false)
  })

  test('a declared name cannot replace PEEK_URL or HOME', async () => {
    const w = world({ files: scriptFolder('figma-files', { env: ['PEEK_URL', 'HOME'] }), env: { PEEK_URL: 'https://evil.example/' } })
    await run(w)
    expect(w.calls.children[0]?.env.PEEK_URL).toBe(LINK)
    expect(w.calls.children[0]?.env.HOME).toBe(HOME)
  })

  test('a recipe timeout is used, capped at 60 seconds', async () => {
    const w = world({ files: scriptFolder('figma-files', { timeoutSeconds: 45 }) })
    await run(w)
    expect(w.calls.run[0]?.init?.timeoutMs).toBe(45_000)
  })
})

describe('runRecipe: failures by name', () => {
  test('covers AE3: exit code 2 with stderr boom is exit-nonzero carrying boom, named for the recipe', async () => {
    const w = world({ files: scriptFolder('figma-files'), script: () => ({ exitCode: 2, stderr: 'boom\n', stdout: JSON.stringify(PAGE) }) })
    const outcome = failed(await run(w), 'exit-nonzero')
    expect(outcome.exitCode).toBe(2)
    expect(outcome.stderr).toBe('boom\n')
    expect(outcome.name).toBe('Figma files')
    expect(failureText(outcome)).toContain('Figma files')
    expect(failureText(outcome)).toContain('boom')
  })

  test('a process.run rejection that comes before the limit is started-failed', async () => {
    const w = world({ files: scriptFolder('figma-files'), script: () => new Error('spawn EACCES') })
    const outcome = failed(await run(w), 'started-failed')
    expect(outcome.message).toContain('EACCES')
  })

  test('a rejection once the limit has passed is timeout, naming the limit', async () => {
    const w = world({ files: scriptFolder('figma-files', { timeoutSeconds: 7 }), script: () => 'timeout' })
    const outcome = failed(await run(w), 'timeout')
    expect(outcome.limitSeconds).toBe(7)
    expect(failureText(outcome)).toContain('7 s')
  })

  test('truncated stdout is output-truncated even when the cut text parses', async () => {
    const w = world({ files: scriptFolder('figma-files'), script: () => ({ stdout: JSON.stringify(PAGE), isStdoutTruncated: true }) })
    failed(await run(w), 'output-truncated')
  })

  test('empty stdout and non-JSON stdout are not-JSON', async () => {
    const empty = world({ files: scriptFolder('figma-files'), script: () => ({ stdout: '  \n' }) })
    expect(failed(await run(empty), 'not-JSON').message).toContain('nothing')
    const prose = world({ files: scriptFolder('figma-files'), script: () => ({ stdout: 'not json' }) })
    failed(await run(prose), 'not-JSON')
  })

  test('an unknown block is invalid-page with its path', async () => {
    const bad = { title: 'x', sections: [{ block: { type: 'chart' } }] }
    const w = world({ files: scriptFolder('figma-files'), script: () => ({ stdout: JSON.stringify(bad) }) })
    const outcome = failed(await run(w), 'invalid-page')
    expect(outcome.problems.map(problem => problem.path)).toContain('sections[0].block.type')
  })

  test('stderr is redacted of declared values before it is capped at 500 characters', async () => {
    const secret = 'lin_api_SECRET123'
    const stderr = `${'x'.repeat(490)}${secret} tail`
    const w = world({
      files: scriptFolder('figma-files', { env: ['LINEAR_API_KEY'] }),
      env: { LINEAR_API_KEY: secret },
      script: () => ({ exitCode: 1, stderr }),
    })
    const outcome = failed(await run(w), 'exit-nonzero')
    expect(outcome.stderr).not.toContain('lin_api')
    expect(outcome.stderr.length).toBeLessThanOrEqual(500)
    expect(outcome.stderr).toContain('[redacted]')
  })

  test('stderr control characters are stripped', async () => {
    const w = world({ files: scriptFolder('figma-files'), script: () => ({ exitCode: 1, stderr: 'bad\u001B[31m red‮' }) })
    expect(failed(await run(w), 'exit-nonzero').stderr).toBe('bad[31m red')
  })

  test('a started-failed message is redacted too, since it can echo the argv', async () => {
    const secret = 'tok_SECRET_456'
    const w = world({
      files: scriptFolder('figma-files', { env: ['TOKEN'] }),
      env: { TOKEN: secret },
      script: child => new Error(`cannot run ${child.argv.join(' ')} TOKEN=${secret}`),
    })
    expect(failed(await run(w), 'started-failed').message).not.toContain(secret)
  })

  test('a not-JSON excerpt of stdout, and the parser error that quotes it, are redacted of declared values', async () => {
    const secret = 'tok_SECRET_789'
    for (const stdout of [`${secret} is not a page`, `{"title": ${secret}}`, `Authorization: Bearer ${secret}\n`]) {
      const w = world({ files: scriptFolder('figma-files', { env: ['TOKEN'] }), env: { TOKEN: secret }, script: () => ({ stdout }) })
      const message = failed(await run(w), 'not-JSON').message
      expect(message.includes('SECRET') ? `${stdout} -> ${message}` : '').toBe('')
      expect(message).toContain('[redacted]')
    }
  })
})

describe('runRecipe: the folder is what runs', () => {
  test('a digest that no longer matches is changed-during-run before anything runs', async () => {
    const w = world({ files: scriptFolder('figma-files') })
    const outcome = failed(await run(w, { digest: 'stale' }), 'changed-during-run')
    expect(outcome.phase).toBe('before')
    expect(w.calls.run).toHaveLength(0)
  })

  test('a file that changes while the script runs is changed-during-run and the page is discarded', async () => {
    const w = world({
      files: scriptFolder('figma-files'),
      script: (_child, self) => {
        self.write(SCRIPT, '#!/bin/sh\necho changed\n')
        return { stdout: JSON.stringify(PAGE) }
      },
    })
    const outcome = failed(await run(w), 'changed-during-run')
    expect(outcome.phase).toBe('after')
    expect('page' in outcome).toBe(false)
  })

  test('a recipe folder that became invalid is invalid-recipe and never runs', async () => {
    const w = world({ files: scriptFolder('figma-files') })
    const loaded = await loadRecipe(w.io, ROOT, 'figma-files')
    if (!loaded.ok) throw new Error('did not load')
    w.write(`${DIR}/recipe.json`, '{')
    const outcome = await runRecipe(w.io, { root: ROOT, id: 'figma-files', digest: loaded.digest, draft: false }, LINK)
    expect(failed(outcome, 'invalid-recipe').problems[0]?.path).toBe('recipe.json')
    expect(w.calls.run).toHaveLength(0)
  })

  test('argv that escapes the folder is refused before running', async () => {
    for (const run0 of ['../../bin/sh', './a/../../x', '/bin/bash']) {
      const w = world({ files: scriptFolder('figma-files', { run: [run0] }) })
      const loaded = await loadRecipe(w.io, ROOT, 'figma-files')
      expect(loaded.ok).toBe(false)
      const outcome = await runRecipe(w.io, { root: ROOT, id: 'figma-files', digest: 'any', draft: false }, LINK)
      failed(outcome, 'invalid-recipe')
      expect(w.calls.run).toHaveLength(0)
    }
  })

  test('a symlinked script is refused before running', async () => {
    const w = world({ files: { ...scriptFolder('figma-files'), [SCRIPT]: { link: '/bin/sh' }, '/bin/sh': 'ELF' } })
    const outcome = await runRecipe(w.io, { root: ROOT, id: 'figma-files', digest: 'any', draft: false }, LINK)
    failed(outcome, 'invalid-recipe')
    expect(w.calls.run).toHaveLength(0)
  })

  test('a script whose real path lands outside the folder is refused even when its spelling is inside', async () => {
    const w = world({ files: scriptFolder('figma-files') })
    const stat = w.io.stat
    w.io.stat = async path => (path === SCRIPT ? { kind: 'file', size: 21, isLink: false, realPath: '/tmp/elsewhere.sh' } : stat(path))
    const outcome = failed(await run(w), 'invalid-recipe')
    expect(outcome.problems[0]?.path).toBe('source.run[0]')
    expect(w.calls.run).toHaveLength(0)
  })

  test('a script that is not a regular file is refused', async () => {
    const w = world({ files: scriptFolder('figma-files') })
    const stat = w.io.stat
    w.io.stat = async path => (path === SCRIPT ? { kind: 'other', size: 0, isLink: false, realPath: SCRIPT } : stat(path))
    failed(await run(w), 'invalid-recipe')
    expect(w.calls.run).toHaveLength(0)
  })

  test('the script runs from its real path, so a home reached through a link still lands inside the folder', async () => {
    const real = '/data/u/.local/share/claude-peek/recipes/figma-files'
    const w = world({
      files: {
        [`${real}/recipe.json`]: JSON.stringify({ name: 'Figma files', match: [{ host: 'figma.com' }], source: { run: ['./fetch.sh'] } }),
        [`${real}/fetch.sh`]: '#!/bin/sh\n',
        '/home': { link: '/data' },
      },
    })
    const outcome = await run(w)
    expect(outcome.ok).toBe(true)
    expect(w.calls.children[0]?.argv[0]).toBe('/data/u/.local/share/claude-peek/recipes/figma-files/fetch.sh')
    expect(w.calls.run[0]?.init?.cwd).toBe('/data/u/.local/share/claude-peek/recipes/figma-files')
  })
})

describe('runRecipe: drafts run only what the session would run', () => {
  test('a draft script the session would ask about is needs-permission and never runs', async () => {
    const w = world({ files: scriptFolder('figma-files', { run: ['./fetch.sh', 'two words'] }), decision: 'ask' })
    const outcome = failed(await run(w, { draft: true }), 'needs-permission')
    expect(w.calls.run).toHaveLength(0)
    expect(w.calls.check).toEqual([{ tool: 'Bash', input: { command: `${SCRIPT} 'two words' ${LINK}` } }])
    expect(outcome.tool).toBe('Bash')
    expect(outcome.command).toBe(`${SCRIPT} 'two words' ${LINK}`)
    expect(failureText(outcome)).toContain(SCRIPT)
  })

  test('a draft script the session denies is needs-permission', async () => {
    const w = world({ files: scriptFolder('figma-files'), decision: 'deny' })
    expect(failed(await run(w, { draft: true }), 'needs-permission').decision).toBe('deny')
    expect(w.calls.run).toHaveLength(0)
  })

  test('a draft script the session allows runs', async () => {
    const w = world({ files: scriptFolder('figma-files'), decision: 'allow' })
    expect((await run(w, { draft: true })).ok).toBe(true)
    expect(w.calls.check).toHaveLength(1)
    expect(w.calls.run).toHaveLength(1)
  })

  test('an approved recipe runs without asking', async () => {
    const w = world({ files: scriptFolder('figma-files'), decision: 'deny' })
    expect((await run(w, { draft: false })).ok).toBe(true)
    expect(w.calls.check).toHaveLength(0)
  })

  test('a draft MCP source the session would prompt for is needs-permission and the tool is never called', async () => {
    const w = world({ files: mcpFolder('figma-files', { server: 'claude.ai Linear', tool: 'get_issue', args: { id: '{{url}}' } }), decision: 'ask' })
    const outcome = failed(await run(w, { draft: true }), 'needs-permission')
    expect(w.calls.mcp).toHaveLength(0)
    expect(w.calls.check).toEqual([{ tool: 'mcp__claude_ai_Linear__get_issue', input: { id: LINK } }])
    expect(outcome.tool).toBe('mcp__claude_ai_Linear__get_issue')
  })
})

describe('runRecipe: MCP source', () => {
  test('substitutes {{url}} in nested string arguments and returns the page', async () => {
    const w = world({
      files: mcpFolder('figma-files', { server: 'claude.ai Linear', tool: 'get_issue', args: { id: '{{url}}', opts: { q: 'see {{url}}', n: 3, list: ['{{url}}'] } } }),
      mcp: () => PAGE_RESULT,
    })
    const outcome = await run(w)
    if (!outcome.ok) throw new Error(JSON.stringify(outcome))
    expect(outcome.page).toEqual(PAGE_RESULT_PAGE)
    expect(w.calls.mcp).toEqual([{ server: 'claude.ai Linear', tool: 'get_issue', args: { id: LINK, opts: { q: `see ${LINK}`, n: 3, list: [LINK] } } }])
  })

  test('a rejected call is server-not-connected', async () => {
    const w = world({ files: mcpFolder('figma-files', { server: 'linear', tool: 'get_issue' }), mcp: () => new Error('MCP server "linear" is not connected') })
    const outcome = failed(await run(w), 'server-not-connected')
    expect(outcome.server).toBe('linear')
    expect(failureText(outcome)).toContain('linear')
  })

  test('isError is tool-error carrying the text', async () => {
    const w = world({ files: mcpFolder('figma-files', { server: 'linear', tool: 'get_issue' }), mcp: () => TOOL_ERROR })
    expect(failed(await run(w), 'tool-error').message).toContain('ENG-999')
  })

  test('a call that never answers is timeout at the limit', async () => {
    const w = world({ files: mcpFolder('figma-files', { server: 'linear', tool: 'get_issue' }, { timeoutSeconds: 5 }), mcp: () => 'hang' })
    expect(failed(await run(w), 'timeout').limitSeconds).toBe(5)
  })

  test('text that is not JSON is not-JSON; a bad page is invalid-page', async () => {
    const prose = world({ files: mcpFolder('figma-files', { server: 'linear', tool: 'get_issue' }), mcp: () => textResult('Here is the issue') })
    failed(await run(prose), 'not-JSON')
    const empty = world({ files: mcpFolder('figma-files', { server: 'linear', tool: 'get_issue' }), mcp: () => ({ content: [], isError: false }) })
    failed(await run(empty), 'not-JSON')
    const bad = world({ files: mcpFolder('figma-files', { server: 'linear', tool: 'get_issue' }), mcp: () => textResult('{"title":""}') })
    failed(await run(bad), 'invalid-page')
  })

  test('structured content is used when the tool returns no text', async () => {
    const w = world({ files: mcpFolder('figma-files', { server: 'linear', tool: 'get_issue' }), mcp: () => structuredResult(PAGE) })
    const outcome = await run(w)
    expect(outcome.ok && outcome.page).toEqual(PAGE)
  })

  test('a recipe.json edited during the call is changed-during-run', async () => {
    const w = world({
      files: mcpFolder('figma-files', { server: 'linear', tool: 'get_issue' }),
      mcp: (_server, _tool, _args, self) => {
        self.write(`${DIR}/notes.txt`, 'new')
        return PAGE_RESULT
      },
    })
    expect(failed(await run(w), 'changed-during-run').phase).toBe('after')
  })
})

describe('failureText', () => {
  test('names the recipe for every failure kind', async () => {
    const w = world({ files: scriptFolder('figma-files'), script: () => ({ exitCode: 0, stdout: '' }) })
    const outcome = await run(w)
    expect(failureText(outcome as Exclude<RunOutcome, { ok: true }>)).toContain('Figma files')
  })
})
