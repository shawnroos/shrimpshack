import { describe, expect, test } from 'claude-code/testing'

import { matches, problemLine, readDefinition, requiredPropsFor } from '../hooks/views/definition'
import type { Definition, DefinitionCheck } from '../hooks/views/definition'
import { createViewRegistry, problemsFor } from '../hooks/views/registry'
import type { ViewsIo } from '../hooks/views/registry'
import { PANE_PROPS, fakeFs } from './fixtures/world'

const FENCE = '```'

const TASK = [
  '---',
  'type: task',
  'match: { folder: .peek/tasks, prop: isTask, equals: true }',
  'props:',
  '  id:          { kind: text, required: true }',
  '  status:      { kind: choice, values: [todo, doing, done, cancelled], required: true }',
  '  creator:     { kind: text, required: true }',
  '  parent:      { kind: ref }',
  '  due:         { kind: date }',
  '  attachments: { kind: links }',
  'requires_when: { isTask: true, all: true }',
  'layout_default: { page: tree, group: list }',
  '---',
  '# {{name}}',
  '',
  `${FENCE}peek-tree parent={{id}}`,
  FENCE,
].join('\n')

// R6's fixed blocks: a list held inside one record, a section left out when empty, and a color map.
const PR = [
  '---',
  'type: gh-pr',
  'match: { record: gh-pr }',
  'props:',
  '  state: { kind: choice, values: [open, merged, closed] }',
  '  body:  { kind: text }',
  'colors:',
  '  state: { open: green, merged: mauve, closed: red }',
  '---',
  `${FENCE}peek-header title={{title}} status=state`,
  FENCE,
  '',
  '{{body}}',
  '',
  `${FENCE}peek-fields hide_empty=true color=state`,
  FENCE,
  '',
  `${FENCE}peek-comments from=comments`,
  FENCE,
  '',
  `${FENCE}ts`,
  'const shown = `${a}` + {{notAPlaceholder}} // code is shown, never run',
  `${FENCE}peek-not-a-block inside an ordinary fence`,
  FENCE,
].join('\n')

function withBody(body: string[], file = 'bad.md'): DefinitionCheck {
  return readDefinition(file, ['---', 'type: probe', 'match: { record: probe }', '---', ...body].join('\n'))
}

function loaded(check: DefinitionCheck): Definition {
  if (!check.ok) throw new Error(check.problems.map(problemLine).join('\n'))
  return check.definition
}

function problemsOf(check: DefinitionCheck): string[] {
  return check.ok ? [] : check.problems.map(problemLine)
}

describe('readDefinition: blocks (AE6)', () => {
  test('covers AE6: a definition using only the fixed blocks loads', () => {
    const definition = loaded(readDefinition('gh-pr.md', PR))
    expect(definition.type).toBe('gh-pr')
    expect(definition.match).toEqual({ record: 'gh-pr' })
    expect(definition.colors).toEqual({ state: { open: 'green', merged: 'mauve', closed: 'red' } })
    expect(definition.blocks.map(block => [block.language, block.line, block.options])).toEqual([
      ['peek-header', 10, { title: '{{title}}', status: 'state' }],
      ['peek-fields', 15, { hide_empty: 'true', color: 'state' }],
      ['peek-comments', 18, { from: 'comments' }],
    ])
  })

  const EXPRESSIONS = [
    'count(items)',
    'status==todo',
    'status=todo&&due',
    'when=a||b',
    'n=1+2',
    'x=$(rm)',
    '`code`',
    '{{#each items}}',
    '{% for x in y %}',
    'title={{ a + b }}',
    'title={{a.b()}}',
    'show=!done',
    'pick=a?b:c',
    'x=a;y=b',
    '"quoted"',
  ]
  for (const info of EXPRESSIONS) {
    test(`covers AE6: an info string holding ${info} errors naming the file and the block`, () => {
      const lines = problemsOf(withBody(['intro', '', `${FENCE}peek-list ${info}`, FENCE], 'tasks-view.md'))
      expect(lines).toHaveLength(1)
      expect(lines[0]).toMatch(/^tasks-view\.md: block 1 \(peek-list, line 7\) /)
      expect(lines[0]).toMatch(/no loops, expressions or code/)
    })
  }

  test('covers AE6: a placeholder that is not {{name}} in the prose errors with its line', () => {
    expect(problemsOf(withBody(['{{#each tasks}}', '- {{name}}', '{{/each}}']))).toEqual([
      'bad.md: line 5 "{{#each tasks}}" is not a {{name}} placeholder; definitions hold no loops, expressions or code',
      'bad.md: line 7 "{{/each}}" is not a {{name}} placeholder; definitions hold no loops, expressions or code',
    ])
    expect(problemsOf(withBody(['{% if done %}x{% endif %}']))[0]).toMatch(/^bad\.md: line 5 "{%/)
  })

  test('a peek- block outside the closed set errors; an ordinary ts fence is fine', () => {
    expect(problemsOf(withBody([`${FENCE}peek-chart by=status`, FENCE]))).toEqual([
      'bad.md: block 1 (peek-chart, line 5) is not a peek block; use one of peek-cards, peek-list, peek-tree, peek-sections, peek-board, peek-focus, peek-header, peek-fields, peek-media, peek-comments',
    ])
    expect(problemsOf(withBody([`${FENCE}ts`, 'const a = items.map(x => x.id) // {{#each}}', FENCE]))).toEqual([])
  })

  test('the same option twice in one block errors', () => {
    expect(problemsOf(withBody([`${FENCE}peek-list by=status by=due`, FENCE]))).toEqual(['bad.md: block 1 (peek-list, line 5) names the option "by" twice'])
  })
})

describe('readDefinition: frontmatter', () => {
  test('the task fixture reads its props, condition and layouts', () => {
    const definition = loaded(readDefinition('task.md', TASK))
    expect(definition.match).toEqual({ folder: '.peek/tasks', prop: { name: 'isTask', equals: true } })
    expect(definition.needsRecipe).toBe(false)
    expect(definition.props.status).toEqual({ kind: 'choice', isRequired: true, values: ['todo', 'doing', 'done', 'cancelled'] })
    expect(definition.props.due).toEqual({ kind: 'date', isRequired: false })
    expect(definition.requiresWhen).toEqual({ when: { isTask: true }, props: 'all' })
    expect(definition.layoutDefault).toEqual({ page: 'tree', group: 'list' })
    expect(definition.template.startsWith('# {{name}}')).toBe(true)
    expect(definition.templateStartLine).toBe(14)
  })

  test('an unknown prop kind and unknown keys are named', () => {
    const check = readDefinition(
      'odd.md',
      [
        '---',
        'type: odd',
        'owner: shawn',
        'match: { record: odd, where: here }',
        'props:',
        '  size: { kind: number }',
        '  note: { kind: text, default: hi }',
        '---',
      ].join('\n'),
    )
    expect(problemsOf(check)).toEqual([
      'odd.md: owner "owner" is not part of a definition; it takes type, match, props, requires_when, layout_default, colors, icons',
      'odd.md: match.where "where" is not part of match; it takes folder, prop, equals, record, recipe',
      'odd.md: props.size.kind "number" is not a prop kind; use text, choice, date, ref, links',
      'odd.md: props.note.default "default" is not part of a prop; it takes kind, required, values',
    ])
  })

  test('choice needs values, other kinds take none, and a bare kind is not a declaration', () => {
    const check = readDefinition(
      'kinds.md',
      ['---', 'type: kinds', 'match: { record: kinds }', 'props:', '  a: { kind: choice }', '  b: { kind: text, values: [x] }', '  c: date', '---'].join('\n'),
    )
    expect(problemsOf(check)).toEqual([
      'kinds.md: props.a.values is required for a choice prop',
      'kinds.md: props.b.values is only for a choice prop',
      'kinds.md: props.c a prop must be a map like { kind: text }, got text',
    ])
  })

  test('match needs one rule; a recipe source is accepted and marked as needing a recipe', () => {
    expect(problemsOf(readDefinition('none.md', ['---', 'type: none', '---'].join('\n')))).toEqual(['none.md: match is required'])
    expect(problemsOf(readDefinition('two.md', ['---', 'type: two', 'match: { record: a, recipe: b }', '---'].join('\n')))).toEqual([
      'two.md: match a record or recipe rule stands alone',
    ])
    const recipe = loaded(readDefinition('r.md', ['---', 'type: inbox', 'match: { recipe: my-inbox }', '---'].join('\n')))
    expect(recipe.needsRecipe).toBe(true)
    expect(matches(recipe, { recordKind: 'my-inbox', props: {} })).toBe(false)
  })

  test('a frontmatter the reader cannot read errors with the file and line', () => {
    expect(problemsOf(readDefinition('deep.md', ['---', 'type: deep', 'match:', '  a:', '    b: c', '---'].join('\n')))[0]).toMatch(/^deep\.md: frontmatter line 5 /)
    expect(problemsOf(readDefinition('plain.md', '# no frontmatter'))).toEqual(['plain.md: $ has no frontmatter; a definition starts with ---'])
  })

  test('icons maps a field label to a glyph; a label key is lowercase with - for spaces', () => {
    const check = readDefinition('icons.md', ['---', 'type: icons', 'match: { record: icons }', 'icons:', '  author: \u{f0004}', '  merge-state: \u{f419}', '---'].join('\n'))
    expect(loaded(check).icons).toEqual({ author: '\u{f0004}', 'merge-state': '\u{f419}' })
    expect(loaded(readDefinition('none.md', ['---', 'type: none', 'match: { record: none }', '---'].join('\n'))).icons).toEqual({})
  })

  test('an icon that is not a short glyph, or icons that are not a map, errors naming the label', () => {
    const lines = (icons: string[]) => problemsOf(readDefinition('icons.md', ['---', 'type: icons', 'match: { record: icons }', ...icons, '---'].join('\n')))
    expect(lines(['icons:', '  author: a whole sentence here'])).toEqual(['icons.md: icons.author "a whole sentence here" is not an icon; use one to four characters'])
    expect(lines(['icons:', '  author: [a, b]'])).toEqual(['icons.md: icons.author must be text, got a list'])
    expect(lines(['icons: author'])).toEqual(['icons.md: icons must map a field label to an icon, got text'])
  })

  test('a color name peek cannot draw is refused at load, listing the names it can', () => {
    const check = readDefinition('c.md', ['---', 'type: c', 'match: { record: c }', 'props:', '  state: { kind: text }', 'colors:', '  state: { open: purple, done: green }', '---'].join('\n'))
    expect(problemsOf(check)).toEqual([
      'c.md: colors.state.open "purple" is not a color peek draws; use red, yellow, green, teal, blue, mauve, peach, accent, text, subtext, gray, muted',
    ])
  })

  test('requires_when must name declared props', () => {
    const check = readDefinition(
      'when.md',
      ['---', 'type: when', 'match: { record: when }', 'props:', '  a: { kind: text }', 'requires_when: { isTask: true, props: [a, ghost] }', '---'].join('\n'),
    )
    expect(problemsOf(check)).toEqual(['when.md: requires_when.props "ghost" is not a declared prop'])
  })
})

describe('matches and requiredPropsFor', () => {
  const task = () => loaded(readDefinition('task.md', TASK))

  test('covers AE1: a plan doc with isTask: true matches and is flagged for exactly the missing deliverable props', () => {
    const plan = { path: '/repo/docs/plans/launch.md', props: { title: 'Launch', isTask: true, id: 'launch', creator: 'shawn' } }
    expect(matches(task(), plan)).toBe(true)
    expect(requiredPropsFor(task(), plan.props)).toEqual(['status', 'parent', 'due', 'attachments'])
  })

  test('a plain task in the tasks folder needs only its required props (R32)', () => {
    const doc = { path: '/repo/.peek/tasks/buy-milk.md', props: { id: 'buy-milk', status: 'todo', creator: 'shawn' } }
    expect(matches(task(), doc)).toBe(true)
    expect(requiredPropsFor(task(), doc.props)).toEqual([])
    expect(requiredPropsFor(task(), { status: '', creator: 'shawn' })).toEqual(['id', 'status'])
  })

  test('the folder rule matches whole path segments and the prop rule needs strict equality', () => {
    expect(matches(task(), { path: '/repo/.peek/tasks-old/a.md' })).toBe(false)
    expect(matches(task(), { path: '/repo/x.peek/tasks/a.md' })).toBe(false)
    expect(matches(task(), { path: '/repo/docs/a.md', props: { isTask: 'true' } })).toBe(false)
    expect(matches(task(), { recordKind: 'gh-pr' })).toBe(false)
    const pr = loaded(readDefinition('gh-pr.md', PR))
    expect(matches(pr, { recordKind: 'gh-pr' })).toBe(true)
    expect(matches(pr, { path: '/repo/gh-pr.md', props: {} })).toBe(false)
  })
})

const BUILT_IN = '/peek/views'
const USER = '/home/.local/share/claude-peek/views'
const FOLDERS = { builtIn: BUILT_IN, user: USER }

function fakeIo(files: Record<string, string>) {
  const store = new Map(Object.entries(files).map(([path, text]) => [path, { text, mtimeMs: 1 }]))
  const reads: string[] = []
  const io: ViewsIo = {
    async list(dir) {
      const names = [...store.keys()].filter(path => path.startsWith(`${dir}/`)).map(path => path.slice(dir.length + 1))
      if (!names.length) throw new Error(`ENOENT ${dir}`)
      return names.map(name => ({ name, kind: 'file' }))
    },
    async read(path) {
      reads.push(path)
      const one = store.get(path)
      if (!one) throw new Error(`ENOENT ${path}`)
      return one.text
    },
    async stat(path) {
      const one = store.get(path)
      return one ? { mtimeMs: one.mtimeMs } : null
    },
  }
  const edit = (path: string, text: string) => store.set(path, { text, mtimeMs: (store.get(path)?.mtimeMs ?? 0) + 1 })
  return { io, reads, edit }
}

const renamed = (text: string, type: string) => text.replace(/^type: .*$/m, `type: ${type}`)

describe('view registry', () => {
  test('loads both folders, reports a broken file by name, and the rest still load', async () => {
    const { io } = fakeIo({
      [`${BUILT_IN}/task.md`]: TASK,
      [`${BUILT_IN}/gh-pr.md`]: PR,
      [`${BUILT_IN}/notes.txt`]: 'not a definition',
      [`${USER}/broken.md`]: ['---', 'type: broken', 'match: { record: x }', '---', `${FENCE}peek-list count(x)`, FENCE].join('\n'),
    })
    const { definitions, problems } = await createViewRegistry().load(io, FOLDERS)
    expect(definitions.map(one => one.type)).toEqual(['gh-pr', 'task'])
    expect(problems.map(problemLine)).toEqual([
      `${USER}/broken.md: block 1 (peek-list, line 5) "count(x)" is not a key=value option or a {{name}} placeholder; blocks hold no loops, expressions or code`,
    ])
  })

  test('a missing user folder is not an error', async () => {
    const { io } = fakeIo({ [`${BUILT_IN}/task.md`]: TASK })
    const { definitions, problems } = await createViewRegistry().load(io, FOLDERS)
    expect(problems).toEqual([])
    expect(definitions.map(one => one.type)).toEqual(['task'])
  })

  test('a user definition with a built-in type name is an error on both, and both stay unloaded', async () => {
    const { io } = fakeIo({
      [`${BUILT_IN}/task.md`]: TASK,
      [`${BUILT_IN}/gh-pr.md`]: PR,
      [`${USER}/my-task.md`]: TASK,
    })
    const { definitions, problems } = await createViewRegistry().load(io, FOLDERS)
    expect(definitions.map(one => one.type)).toEqual(['gh-pr'])
    expect(problems.map(problemLine)).toEqual([
      `${BUILT_IN}/task.md: type "task" is also defined by ${USER}/my-task.md; neither loads`,
      `${USER}/my-task.md: type "task" is also defined by ${BUILT_IN}/task.md; neither loads`,
    ])
    expect(await createViewRegistry().definitionFor(io, FOLDERS, { path: '/repo/.peek/tasks/a.md', props: {} })).toBe(null)
  })

  test('editing a user definition takes effect on the next read, and an unchanged file is not re-read', async () => {
    const { io, reads, edit } = fakeIo({ [`${BUILT_IN}/gh-pr.md`]: PR, [`${USER}/chore.md`]: renamed(TASK, 'chore') })
    const registry = createViewRegistry()
    expect((await registry.load(io, FOLDERS)).definitions.map(one => one.type)).toEqual(['chore', 'gh-pr'])
    edit(`${USER}/chore.md`, renamed(TASK, 'errand'))
    expect((await registry.load(io, FOLDERS)).definitions.map(one => one.type)).toEqual(['errand', 'gh-pr'])
    expect(reads.filter(path => path.endsWith('gh-pr.md'))).toHaveLength(1)
    expect(reads.filter(path => path.endsWith('chore.md'))).toHaveLength(2)
  })

  test('definitionFor returns the type a doc or record belongs to, or null', async () => {
    const { io } = fakeIo({ [`${BUILT_IN}/task.md`]: TASK, [`${BUILT_IN}/gh-pr.md`]: PR })
    const registry = createViewRegistry()
    expect((await registry.definitionFor(io, FOLDERS, { path: '/repo/docs/plan.md', props: { isTask: true } }))?.type).toBe('task')
    expect((await registry.definitionFor(io, FOLDERS, { recordKind: 'gh-pr' }))?.type).toBe('gh-pr')
    expect(await registry.definitionFor(io, FOLDERS, { path: '/repo/docs/readme.md', props: {} })).toBe(null)
  })
})

describe('problems for a page', () => {
  const BROKEN_BLOCK = [`${FENCE}peek-list count(x)`, FENCE]
  const meeting = ['---', 'type: meeting', 'match: { folder: meetings }', '---', ...BROKEN_BLOCK].join('\n')

  test('covers AE6: a broken definition shows on the pages its match would apply to, and nowhere else', async () => {
    const { io } = fakeIo({ [`${BUILT_IN}/task.md`]: TASK, [`${USER}/meeting.md`]: meeting })
    const load = await createViewRegistry().load(io, FOLDERS)
    expect(problemsFor(load, { path: '/repo/meetings/standup.md', props: {} }).map(problemLine)).toEqual([
      `${USER}/meeting.md: block 1 (peek-list, line 5) "count(x)" is not a key=value option or a {{name}} placeholder; blocks hold no loops, expressions or code`,
    ])
    expect(problemsFor(load, { path: '/repo/docs/plan.md', props: {} })).toEqual([])
    expect(problemsFor(load, { recordKind: 'gh-pr' })).toEqual([])
  })

  test('a definition whose match cannot be read shows on the record page named like the file', async () => {
    const { io } = fakeIo({ [`${USER}/gh-pr.md`]: '# no frontmatter' })
    const load = await createViewRegistry().load(io, FOLDERS)
    expect(problemsFor(load, { recordKind: 'gh-pr' }).map(problemLine)).toEqual([`${USER}/gh-pr.md: $ has no frontmatter; a definition starts with ---`])
    expect(problemsFor(load, { recordKind: 'gh-issue' })).toEqual([])
    expect(problemsFor(load, { path: '/repo/gh-pr.md', props: {} })).toEqual([])
  })

  test('a type clash shows on a page either file would match, and each line names both files', async () => {
    const { io } = fakeIo({ [`${BUILT_IN}/task.md`]: TASK, [`${USER}/my-task.md`]: TASK.replace('match: { folder: .peek/tasks, prop: isTask, equals: true }', 'match: { folder: chores }') })
    const load = await createViewRegistry().load(io, FOLDERS)
    expect(problemsFor(load, { path: '/repo/chores/a.md', props: {} }).map(problemLine)).toEqual([
      `${USER}/my-task.md: type "task" is also defined by ${BUILT_IN}/task.md; neither loads`,
    ])
    expect(problemsFor(load, { path: '/repo/.peek/tasks/a.md', props: {} }).map(problemLine)).toEqual([
      `${BUILT_IN}/task.md: type "task" is also defined by ${USER}/my-task.md; neither loads`,
    ])
    expect(problemsFor(load, { path: '/repo/docs/plan.md', props: {} })).toEqual([])
  })
})

describe('problems on a file page', () => {
  type Pane = { redraw: () => Promise<unknown>; find: (q: { text: RegExp }) => Promise<unknown>; unmount: () => Promise<void> }
  const settle = async () => {
    for (let i = 0; i < 50; i++) await Promise.resolve()
  }
  const meeting = ['---', 'type: meeting', 'match: { folder: meetings }', '---', `${FENCE}peek-list count(x)`, FENCE].join('\n')

  test('covers AE6 on a file page: a broken definition whose match takes this page shows a line naming the file; another page shows none', async ($, on) => {
    fakeFs(on, { [`${USER}/meeting.md`]: meeting, '/repo/meetings/standup.md': '# Standup\n\nNotes.\n' })
    const ui = (await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' } as never)) as Pane
    const line = /^\/home\/\.local\/share\/claude-peek\/views\/meeting\.md: block 1 \(peek-list, line 5\) "count\(x\)"/
    await $.command.run({ command: 'peek', args: '/repo/meetings/standup.md' } as never)
    await settle()
    await ui.redraw()
    expect(await ui.find({ text: line })).toBeDefined()
    expect(await ui.find({ text: /^STANDUP$/ })).toBeDefined()
    await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
    await settle()
    await ui.redraw()
    expect(await ui.find({ text: line })).toBeUndefined()
    await ui.unmount()
  })
})
