import type { Loaded, RemoteRecord, Tier } from '../../types'

export function ok(record: RemoteRecord, tier: Tier, fetchedAt: number): Loaded {
  return { ok: true, record, tier, fetchedAt }
}
