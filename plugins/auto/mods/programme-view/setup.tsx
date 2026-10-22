import type { RenderElement } from 'claude-code'

import { COLOR, GLYPH } from './palette'
import type { Ui } from './tree'
import type { Decision, Setup, SetupStep } from './view'

const MARK = {
  done: { glyph: GLYPH.done, color: COLOR.done },
  current: { glyph: GLYPH.current, color: COLOR.current },
  upcoming: { glyph: GLYPH.planned, color: undefined },
} as const

const SCOPE_PARTS = ['spaces', 'tabs', 'repos', 'tracker'] as const
const LABEL_COLUMNS = 28

function title(name: string): string {
  const words = name.replaceAll('_', ' ')
  return words.charAt(0).toUpperCase() + words.slice(1)
}

function scopeText(lists: Record<string, string[]>): string | undefined {
  const parts = SCOPE_PARTS.flatMap(part => {
    const names = lists[part] ?? []
    return names.length > 0 ? [`${part} ${names.join(', ')}`] : []
  })
  return parts.length > 0 ? parts.join(' · ') : undefined
}

function groups(steps: SetupStep[]): { group: string; steps: SetupStep[] }[] {
  const out: { group: string; steps: SetupStep[] }[] = []
  for (const step of steps) {
    const last = out.at(-1)
    if (last?.group === step.group) last.steps.push(step)
    else out.push({ group: step.group, steps: [step] })
  }
  return out
}

function currentIndex(setup: Setup): number {
  const named = setup.steps.findIndex(step => step.key === setup.current)
  if (named !== -1) return named
  const unfinished = setup.steps.findIndex(step => step.state !== 'done')
  return unfinished === -1 ? setup.steps.length - 1 : unfinished
}

export function setupBandText(setup: Setup): string {
  const at = currentIndex(setup)
  const rest = setup.steps.slice(Math.max(0, at)).map(step => step.key.replaceAll('_', ' '))
  return `Setup ${at + 1}/${setup.steps.length} · ${rest.join(' ▸ ')}`
}

export function SetupBand(ui: Ui, setup: Setup): RenderElement {
  const { Text } = ui
  return (
    <Text key="setup-band" wrap="truncate">
      <Text color={COLOR.current}>{`${GLYPH.current} `}</Text>
      <Text>{setupBandText(setup)}</Text>
    </Text>
  )
}

export function decisionLines(ui: Ui, decisions: Decision[], line: (key: string, ...cells: RenderElement[]) => void) {
  const { Text } = ui
  if (decisions.length === 0) return
  line('decisions:gap', <Text> </Text>)
  line('decisions', <Text bold>Waiting on you</Text>)
  for (const [index, decision] of decisions.entries()) {
    line(`decision:${index}`, <Text color={COLOR.warning}>{`${GLYPH.warning}  `}</Text>, <Text>{decision.question}</Text>)
    if (decision.reply === null) continue
    line(`decision:${index}:label`, <Text dimColor>{'   Type this:'}</Text>)
    line(`decision:${index}:reply`, <Text bold>{`   ${decision.reply}`}</Text>)
  }
}

export function DecisionsView(ui: Ui, decisions: Decision[]): RenderElement {
  const { Box } = ui
  const out: RenderElement[] = []
  decisionLines(ui, decisions, (key, ...cells) =>
    out.push(
      <Box key={`line:${key}`} flexDirection="row">
        {cells}
      </Box>,
    ),
  )
  return <Box flexDirection="column">{out}</Box>
}

export function SetupView(ui: Ui, props: { setup: Setup; decisions: Decision[] }): RenderElement {
  const { Box, Text } = ui
  const { setup } = props
  const out: RenderElement[] = []
  const line = (key: string, ...cells: RenderElement[]) =>
    out.push(
      <Box key={`line:${key}`} flexDirection="row">
        {cells}
      </Box>,
    )
  const pad = (width: number) => ' '.repeat(width)

  line('setup:head', <Text bold>Programme setup</Text>, <Text dimColor>{'   draft, not accepted'}</Text>)
  line('setup:in', <Text bold>{'In   '}</Text>, <Text>{scopeText(setup.scope.in) ?? 'nothing chosen yet'}</Text>)
  const outText = setup.scope.probed ? (scopeText(setup.scope.out) ?? 'nothing seen outside the remit') : 'not probed yet'
  line('setup:out', <Text bold>{'Out  '}</Text>, <Text>{outText}</Text>)
  line('setup:gap', <Text> </Text>)

  for (const { group, steps } of groups(setup.steps)) {
    const headed = steps.length > 1 || steps[0]?.key !== group
    if (headed) line(`group:${group}`, <Text bold>{title(group)}</Text>)
    const indent = headed ? 2 : 0
    for (const step of steps) {
      const mark = MARK[step.state]
      const isCurrent = step.state === 'current'
      line(
        `step:${step.key}`,
        <Text>{pad(indent)}</Text>,
        <Text color={mark.color} dimColor={step.state === 'upcoming'}>{`${mark.glyph}  `}</Text>,
        <Text bold={isCurrent}>{title(step.label).padEnd(LABEL_COLUMNS - indent)}</Text>,
        <Text dimColor>{` ${step.values}`}</Text>,
        isCurrent ? <Text color={COLOR.current}>{'   ← current'}</Text> : <Text>{''}</Text>,
      )
      const inner = pad(indent + 3)
      for (const item of step.items) {
        line(
          `step:${step.key}:item:${item.item}`,
          <Text>{inner}</Text>,
          <Text color={item.adopted ? COLOR.done : undefined}>{`${item.adopted ? GLYPH.done : GLYPH.item}  `}</Text>,
          <Text>{item.title || item.item}</Text>,
        )
      }
      if (step.reply !== null) {
        line(`step:${step.key}:label`, <Text dimColor>{`${inner}Type this:`}</Text>)
        line(`step:${step.key}:reply`, <Text bold>{`${inner}${step.reply}`}</Text>)
      }
      if (!isCurrent) continue
      if (step.recommendation !== null) {
        const source = step.recommendation_source ? ` · ${step.recommendation_source}` : ''
        line(`step:${step.key}:recommended`, <Text dimColor>{`${inner}Recommended: ${step.recommendation}${source}`}</Text>)
      }
      if (step.reply === null) line(`step:${step.key}:hint`, <Text dimColor>{`${inner}Answer in the chat.`}</Text>)
    }
  }
  decisionLines(ui, props.decisions.filter(decision => decision.kind !== 'agreement'), line)
  return <Box flexDirection="column">{out}</Box>
}
