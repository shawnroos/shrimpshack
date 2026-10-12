import { expect, test } from 'claude-code/testing'
import { itemKey } from '../hooks/refs'
import { C } from '../hooks/theme'
import { LINEAR, PAGE, PANE_PROPS, PR, call, cardTitles, create, dirOf, editGroup, fakeFs, jsonOf, savedGroup } from './fixtures/world'

test('save_group with mixed targets creates a group; read_group returns every item, the repo files repo-relative', async ($, on) => {
  const w = fakeFs(on)
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', async () => ({ result: [{ type: 'text', text: '{"identifier":"WEB-12","url":"https://linear.app/acme/issue/WEB-12/fix-login"}' }] }) as never)
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__claude_ai_Linear__get_issue', tool_use_id: 'l1', id: 'WEB-12' } as never)
  const { text, id } = await create($, [
    { target: '/repo/docs/plan.md' },
    { target: 'notes/todo.md' },
    { target: `${PR}/files` },
    { target: 'WEB-12' },
    { target: PAGE },
    { target: '/home/notes.md' },
  ])
  expect(text.split('\n')[0]).toMatch(/^Created group "Launch" \([0-9a-z]{8}\)/)
  expect(id).toMatch(/^[0-9a-z]{8}$/)
  const read = jsonOf(await call($, 'read_group', { id })) as { items: Record<string, unknown>[] }
  expect(read.items.map(one => one.ref)).toEqual(['docs/plan.md', 'notes/todo.md', PR, LINEAR, PAGE, 'file:///home/notes.md'])
  expect(read.items.every(one => one.addedBy === 'agent' && one.state === 'ok' && one.title === null)).toBe(true)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual(['docs/plan.md', 'notes/todo.md', PR, LINEAR, PAGE, 'file:///home/notes.md'])
  expect(JSON.parse(w.files[`${dirOf('/repo/.git')}/${id}.json`] ?? '{}').projectKey).toBe('/repo/.git')
})

test('a batch with one nonexistent file adds the others and rejects that one with its reason', async ($, on) => {
  const w = fakeFs(on)
  const { text, id } = await create($, [{ target: 'docs/plan.md' }, { target: 'docs/gone.md' }, { target: PAGE }])
  const outcomes = jsonOf(text).outcomes as { op: string; status: string; reason: string; ref?: string }[]
  const gone = outcomes.find(one => one.ref === 'docs/gone.md')
  expect(gone?.status).toBe('refused')
  expect(gone?.reason).toMatch(/No file or URL at docs\/gone\.md/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual(['docs/plan.md', PAGE])
  expect(text.split('\n')[0]).toMatch(/1 refused/)
})

test('each write takes the lock, writes a staged file, moves it over the group file, then releases the lock', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.log = []
  await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  const steps = w.log
    .map(one => one.join(' '))
    .filter(one => one.includes(`${id}.json`))
  const staged = /^write (.*\.staged)$/.exec(steps[2] ?? '')?.[1] ?? ''
  expect(staged).toMatch(new RegExp(`^${file}\\.[0-9a-z]+\\.staged$`))
  expect(steps).toEqual([
    `run mkdir ${file}.lock`,
    `write ${file}.lock/owner`,
    `write ${staged}`,
    `run mv -f ${staged} ${file}`,
    `run rm -f ${file}.lock/owner`,
    `run rmdir ${file}.lock`,
  ])
  expect(Object.keys(w.files).some(one => one.startsWith(`${file}.`))).toBe(false)
})

test('two writers never share a staged path', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  w.log = []
  await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  await call($, 'save_group', { id, add: [{ target: 'notes/todo.md' }] })
  const staged = w.log.filter(one => one[0] === 'write' && one[1]?.endsWith('.staged')).map(one => one[1])
  expect(staged.length).toBe(2)
  expect(new Set(staged).size).toBe(2)
})

test('a holder whose lock is broken and retaken mid-write commits nothing, the newer edit survives, and the new holder keeps its lock', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  const lock = `${file}.lock`
  w.onWrite = path => {
    if (!path.endsWith('.staged')) return
    w.onWrite = undefined
    delete w.files[`${lock}/owner`]
    w.dirs.delete(lock)
    w.dirs.set(lock, w.now)
    w.files[`${lock}/owner`] = 'the-other-session'
    const group = JSON.parse(w.files[file] ?? '{}')
    group.items.push({ ref: 'notes/todo.md', addedBy: 'person', addedAt: w.now })
    w.files[file] = JSON.stringify(group)
  }
  w.log = []
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).toMatch(/busy, try again/)
  expect(text).not.toMatch(/added|applied/i)
  expect(w.log.some(one => one[0] === 'run' && one[1] === 'mv')).toBe(false)
  expect(savedGroup(w, id)?.items.map(one => `${one.ref}:${one.addedBy}`)).toEqual([`${PAGE}:agent`, 'notes/todo.md:person'])
  expect(w.files[`${lock}/owner`]).toBe('the-other-session')
  expect(w.dirs.has(lock)).toBe(true)
  expect(Object.keys(w.files).some(one => one.endsWith('.staged'))).toBe(false)
})

test('a holder whose lock vanished before its mv commits nothing', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.onWrite = path => {
    if (!path.endsWith('.staged')) return
    w.onWrite = undefined
    delete w.files[`${file}.lock/owner`]
    w.dirs.delete(`${file}.lock`)
  }
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).toMatch(/busy, try again/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE])
})

test('a save started while another session holds the lock waits, re-reads, and both changes land', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.dirs.set(`${file}.lock`, w.now)
  w.onLockBusy = lock => {
    const group = JSON.parse(w.files[file] ?? '{}')
    group.items.push({ ref: 'notes/todo.md', addedBy: 'person', addedAt: w.now })
    w.files[file] = JSON.stringify(group)
    w.dirs.delete(lock)
    w.onLockBusy = undefined
  }
  w.log = []
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).not.toMatch(/busy/)
  expect(w.log.filter(one => one.join(' ') === `run mkdir ${file}.lock`).length).toBe(2)
  expect(savedGroup(w, id)?.items.map(one => `${one.ref}:${one.addedBy}`)).toEqual([`${PAGE}:agent`, 'notes/todo.md:person', 'docs/plan.md:agent'])
})

test('two saves from this session to one group queue in process, so neither waits on the lock and both land', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.log = []
  await Promise.all([call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] }), call($, 'save_group', { id, add: [{ target: 'notes/todo.md' }] })])
  expect(w.log.filter(one => one.join(' ') === `run mkdir ${file}.lock`).length).toBe(2)
  expect(savedGroup(w, id)?.items.map(one => one.ref).sort()).toEqual(['docs/plan.md', 'notes/todo.md', PAGE].sort())
})

test('a lock older than 10 s is broken and the write proceeds', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.dirs.set(`${file}.lock`, w.now - 11_000)
  w.files[`${file}.lock/owner`] = 'a-stalled-session'
  w.mtimes.set(`${file}.lock/owner`, w.now - 11_000)
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).not.toMatch(/busy/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'docs/plan.md'])
  expect(w.dirs.has(`${file}.lock`)).toBe(false)
  expect(w.files[`${file}.lock/owner`]).toBeUndefined()
})

test('a fresh lock held past 2 s refuses the save as busy, and nothing reports the item as added', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.dirs.set(`${file}.lock`, w.now)
  const started = w.now
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).toMatch(/busy, try again/)
  expect(text).not.toMatch(/added|applied/i)
  expect(w.now - started).toBeGreaterThanOrEqual(2000)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE])
  expect(w.dirs.has(`${file}.lock`)).toBe(true)
})

test('a failing mv makes save_group return an error, and nothing reports the item as added', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.isMvBroken = true
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).toMatch(/^Could not save/)
  expect(text).not.toMatch(/added|applied/i)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE])
  expect(Object.keys(w.files).some(one => one.startsWith(`${file}.`))).toBe(false)
  expect(w.dirs.has(`${file}.lock`)).toBe(false)
})

test('a main checkout and a linked worktree share a project key; another project does not see the group', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  expect(w.log.some(one => one.join(' ') === 'run git -C /repo rev-parse --path-format=absolute --git-common-dir')).toBe(true)
  w.root = '/wt/feature'
  const fromWorktree = jsonOf(await call($, 'list_groups', {})) as unknown as { id: string }[]
  expect(fromWorktree.map(one => one.id)).toEqual([id])
  w.root = '/other'
  const fromOther = await call($, 'list_groups', {})
  expect(fromOther.split('\n')[0]).toMatch(/No groups/)
  expect(jsonOf(fromOther)).toEqual([])
})

test('a group file recording another project key is skipped even in the same folder', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const dir = dirOf('/repo/.git')
  const other = JSON.parse(w.files[`${dir}/${id}.json`] ?? '{}')
  w.files[`${dir}/zzzzzzzz.json`] = JSON.stringify({ ...other, id: 'zzzzzzzz', title: 'Elsewhere', projectKey: '/elsewhere/.git' })
  w.files[`${dir}/${id}.json.staged`] = '{}'
  const listed = jsonOf(await call($, 'list_groups', {})) as unknown as { id: string }[]
  expect(listed.map(one => one.id)).toEqual([id])
  expect(await call($, 'read_group', { id: 'zzzzzzzz' })).toMatch(/^No group zzzzzzzz/)
})

test('a damaged group file with a null item, a numeric ref, bad sections and non-text tombstones still reads, saves and draws', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  editGroup(w, id, group => {
    group.items = [null, { ref: 42, addedBy: 'agent', addedAt: 1 }, ...(group.items as unknown[]), 'docs/plan.md', { ref: 'notes/todo.md', section: 'abcdefgh', addedBy: 'agent', addedAt: 1 }]
    group.sections = [null, { id: 5, title: 'Numeric' }, { id: 'abcdefgh', title: 7 }, { id: 'keptsect', title: 'Kept' }]
    group.removed = [7, null, 'gone.md']
  })
  const read = jsonOf(await call($, 'read_group', { id })) as { items: { ref: string; section: string | null }[]; sections: { title: string }[]; removed: string[] }
  expect(read.items.map(one => `${one.ref}:${one.section}`)).toEqual([`${PAGE}:null`, 'notes/todo.md:null'])
  expect(read.sections.map(one => one.title)).toEqual(['Kept'])
  expect(read.removed).toEqual(['gone.md'])
  const saved = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md', section: 'Kept' }] })
  expect(saved.split('\n')[0]).toMatch(/1 applied/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'notes/todo.md', 'docs/plan.md'])
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['LAUNCH'])
  await ui.press({ key: 'item-0' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Launch/)
  await ui.unmount()
})

test('outside git the project key is the session root', async ($, on) => {
  const w = fakeFs(on, { '/plain/a.md': 'a\n' })
  w.root = '/plain'
  const { id } = await create($, [{ target: 'a.md' }])
  expect(savedGroup(w, id, '/plain')?.items.map(one => one.ref)).toEqual(['file:///plain/a.md'])
})

test('delete_group on a starred group without force is refused; with force the file is gone', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.files[file] = JSON.stringify({ ...JSON.parse(w.files[file] ?? '{}'), starred: true })
  const refused = await call($, 'delete_group', { id })
  expect(refused).toMatch(/^Not deleted: the person starred it/)
  expect(w.files[file]).toBeDefined()
  const forced = await call($, 'delete_group', { id, force: true })
  expect(forced).toMatch(/^Deleted group "Launch"/)
  expect(w.files[file]).toBeUndefined()
})

test('read_group marks a local file that vanished as missing; a repo-relative ref removes it', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }, { target: PAGE }])
  delete w.files['/repo/docs/plan.md']
  const read = jsonOf(await call($, 'read_group', { id })) as { items: { ref: string; state: string }[] }
  expect(read.items.map(one => `${one.ref}:${one.state}`)).toEqual(['docs/plan.md:missing', `${PAGE}:ok`])
  await call($, 'save_group', { id, remove: [{ target: 'docs/plan.md' }] })
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE])
})

test('an agent remove of a person-added item is refused without force', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  const group = JSON.parse(w.files[file] ?? '{}')
  group.items.push({ ref: 'notes/todo.md', addedBy: 'person', addedAt: w.now })
  w.files[file] = JSON.stringify(group)
  const text = await call($, 'save_group', { id, remove: [{ target: 'notes/todo.md' }] })
  const outcome = (jsonOf(text).outcomes as { status: string; needsForce?: boolean }[])[0]
  expect(outcome).toMatchObject({ status: 'refused', needsForce: true })
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'notes/todo.md'])
})

test('an id that is not a group id is refused before any file is touched', async ($, on) => {
  const w = fakeFs(on)
  w.log = []
  expect(await call($, 'read_group', { id: '../../etc' })).toMatch(/not a group id/)
  expect(await call($, 'save_group', { id: '../x', title: 'y' })).toMatch(/not a group id/)
  expect(w.log.some(one => one[0] === 'write' || one.includes('mkdir'))).toBe(false)
})

test('save_group refuses unreadable input with its exact message and writes no group file', async ($, on) => {
  const w = fakeFs(on)
  const cases: [Record<string, unknown>, string][] = [
    [{ title: 5 }, 'title must be text.'],
    [{ title: 'Launch', description: 5 }, 'description must be text.'],
    [{}, 'Give a title to create a group, or an id to change one.'],
    [{ title: 'Launch', sections: [{ action: 'explode', section: 'a' }] }, 'Unreadable section change {"action":"explode","section":"a"}'],
    [{ title: 'Launch', sections: 'Design' }, 'sections must be a list of { action, section, title }'],
    [{ title: 'Launch', order: ['a', 3] }, 'order must be a list of section ids or titles.'],
    [{ title: 'Launch', add: [{}] }, 'add, move and remove are lists of objects, each with a target.'],
    [{ title: 'Launch', add: [null] }, 'add, move and remove are lists of objects, each with a target.'],
    [{ id: 'BAD', title: 'Launch' }, 'BAD is not a group id. Use an id from list_groups.'],
    [{ title: 'Launch', sections: [{ action: 'add', title: 'Links', layout: 'grid' }] }, 'A section layout is cards or list, not "grid"'],
    [{ title: 'Launch', sections: [{ action: 'layout', section: 'Links' }] }, 'A section layout is cards or list, not "undefined"'],
  ]
  for (const [input, message] of cases) {
    expect([input, await call($, 'save_group', input)]).toEqual([input, message])
  }
  expect(Object.keys(w.files).filter(one => one.startsWith(`${dirOf('/repo/.git')}/`))).toEqual([])
})

test('save_group sets a section layout on add and with a layout change; read_group reads a missing or unknown layout as cards', async ($, on) => {
  const w = fakeFs(on)
  const text = await call($, 'save_group', {
    title: 'Launch',
    sections: [{ action: 'add', title: 'Links', layout: 'list' }, { action: 'add', title: 'Docs' }],
  })
  const id = String(jsonOf(text).id)
  const layouts = async () => ((jsonOf(await call($, 'read_group', { id })) as { sections: { layout: string }[] }).sections).map(one => one.layout)
  expect(await layouts()).toEqual(['list', 'cards'])
  const changed = await call($, 'save_group', { id, sections: [{ action: 'layout', section: 'Docs', layout: 'list' }] })
  expect(changed.split('\n')[0]).toMatch(/1 applied/)
  expect(await layouts()).toEqual(['list', 'list'])
  editGroup(w, id, group => {
    const sections = group.sections as Record<string, unknown>[]
    if (sections[0]) delete sections[0].layout
    if (sections[1]) sections[1].layout = 'mosaic'
  })
  expect(await layouts()).toEqual(['cards', 'cards'])
  await call($, 'save_group', { id, description: 'resaved' })
  const stored = JSON.parse(w.files[`${dirOf('/repo/.git')}/${id}.json`] ?? '{}') as { sections: { layout?: string }[] }
  expect(stored.sections.map(one => one.layout)).toEqual(['cards', 'cards'])
})

test('save_group moves items, reorders, renames and removes sections, and force overrides a person tombstone and a person add', async ($, on) => {
  const w = fakeFs(on)
  const text = await call($, 'save_group', {
    title: 'Launch',
    sections: [
      { action: 'add', title: 'Design' },
      { action: 'add', title: 'Build' },
    ],
    add: [{ target: 'docs/plan.md', section: 'Design' }, { target: PAGE }],
  })
  const id = String(jsonOf(text).id)
  const file = `${dirOf('/repo/.git')}/${id}.json`
  const stored = () => JSON.parse(w.files[file] ?? '{}') as { sections: { id: string; title: string }[]; items: { ref: string; section?: string; addedBy: string }[]; removed: string[] }
  const sectionId = (title: string) => stored().sections.find(one => one.title === title)?.id
  const placeOf = (ref: string) => stored().items.find(one => one.ref === ref)?.section

  await call($, 'save_group', { id, move: [{ target: 'docs/plan.md', section: 'Build' }, { target: PAGE, section: 'Design' }] })
  expect([placeOf('docs/plan.md'), placeOf(PAGE)]).toEqual([sectionId('Build'), sectionId('Design')])

  await call($, 'save_group', { id, order: ['Build', 'Design'] })
  expect(stored().sections.map(one => one.title)).toEqual(['Build', 'Design'])

  await call($, 'save_group', { id, sections: [{ action: 'rename', section: 'Design', title: 'Specs' }, { action: 'remove', section: 'Build' }] })
  expect(stored().sections.map(one => one.title)).toEqual(['Specs'])
  expect([placeOf('docs/plan.md'), placeOf(PAGE)]).toEqual([undefined, sectionId('Specs')])

  editGroup(w, id, group => {
    group.removed = [itemKey('notes/todo.md')]
    ;(group.items as unknown[]).push({ ref: LINEAR, addedBy: 'person', addedAt: w.now })
  })
  const blocked = jsonOf(await call($, 'save_group', { id, add: [{ target: 'notes/todo.md' }], remove: [{ target: LINEAR }] }))
  expect((blocked.outcomes as { status: string; needsForce?: boolean }[]).map(one => `${one.status}:${one.needsForce}`)).toEqual(['refused:true', 'refused:true'])
  expect(stored().items.map(one => one.ref)).toEqual(['docs/plan.md', PAGE, LINEAR])

  const forced = jsonOf(await call($, 'save_group', { id, add: [{ target: 'notes/todo.md', force: true }], remove: [{ target: LINEAR, force: true }] }))
  expect((forced.outcomes as { status: string }[]).map(one => one.status)).toEqual(['applied', 'applied'])
  expect(stored().items.map(one => `${one.ref}:${one.addedBy}`)).toEqual(['docs/plan.md:agent', `${PAGE}:agent`, 'notes/todo.md:agent'])
  expect(stored().removed).toEqual([])
})

test('a tool write in this session redraws the pane', async ($, on) => {
  const w = fakeFs(on)
  const before = w.invalidated
  await create($, [{ target: PAGE }])
  expect(w.invalidated).toBeGreaterThan(before)
})
