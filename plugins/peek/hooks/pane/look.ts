import type { FileEntry } from '../gallery'
import type { Ref } from '../refs'
import type { TitleEntry } from '../refresh'

export type ItemState = 'ok' | 'missing' | 'unavailable'

export type ItemLook = { key: string; href: string; name: string; kind: string; where: string; state: ItemState; favicon?: string }

// The two callers disagree on purpose (Recent names a Slack thread by channel, a group item does not; a group item's
// own label outranks the fallback), so each passes its own fallback. `host` stays lazy: Recent's URL parse may throw.
export function remoteNaming(
  ref: Ref | null,
  title: TitleEntry | undefined,
  fallback: { label?: string; bare: string; namesThread: boolean; host: () => string },
): { name: string; where: string; kind: string } {
  const issueKey = ref?.kind === 'linear-issue' ? ref.key : undefined
  const number = ref && 'number' in ref ? ref.number : undefined
  const channel = ref?.kind === 'slack-thread' ? ref.channel : undefined
  const github = ref && 'owner' in ref ? ref : undefined
  return {
    name:
      title?.title ??
      fallback.label ??
      issueKey ??
      (number ? `#${number}` : fallback.namesThread && channel ? `Thread in ${channel}` : fallback.bare.replace(/^https?:\/\/(www\.)?/, '')),
    where: github?.owner ? `${github.owner}/${github.repo}` : title?.trail?.join(' · ') || fallback.host(),
    kind: title?.kind ?? ref?.kind ?? 'web',
  }
}

export function lookOf(entry: FileEntry, where: string): ItemLook {
  return { key: entry.href, href: entry.href, name: entry.name, kind: entry.kind, where, state: 'ok', favicon: entry.favicon }
}
