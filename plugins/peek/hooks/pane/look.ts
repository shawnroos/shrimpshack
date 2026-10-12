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
  return {
    name:
      title?.title ??
      fallback.label ??
      ref?.key ??
      (ref?.number ? `#${ref.number}` : fallback.namesThread && ref?.channel ? `Thread in ${ref.channel}` : fallback.bare.replace(/^https?:\/\/(www\.)?/, '')),
    where: ref?.owner ? `${ref.owner}/${ref.repo}` : title?.trail?.join(' · ') || fallback.host(),
    kind: title?.kind ?? ref?.kind ?? 'web',
  }
}
