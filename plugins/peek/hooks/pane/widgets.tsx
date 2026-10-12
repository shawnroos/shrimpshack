import type { WidgetCtx } from './types'

export function SectionRule(ctx: WidgetCtx, label: string, right: string, width: number, key?: string) {
  const { Text, C } = ctx
  const head = `${label} `
  const tail = right ? ` ${right}` : ''
  return (
    <Text key={key} wrap="truncate-end">
      <Text color={C.accent} bold>{head}</Text>
      <Text color={C.surface1}>{'─'.repeat(Math.max(1, width - head.length - tail.length))}</Text>
      <Text color={C.overlay0}>{tail}</Text>
    </Text>
  )
}
