import type { ProcessRunResult } from 'claude-code'
import { parseRef } from '../../hooks/refs'
import type { Ref } from '../../hooks/refs'
import type { Loaded, RemoteRecord } from '../../types'

export function exited(exitCode: number, stdout = '', stderr = '', isStdoutTruncated = false): ProcessRunResult {
  return { exitCode, stdout, stderr, isStdoutTruncated, isStderrTruncated: false }
}

export function ref(text: string): Ref {
  const found = parseRef(text)
  if (!found) throw new Error(`bad ref ${text}`)
  return found
}

export function record(loaded: Loaded | null): RemoteRecord {
  if (!loaded || !loaded.ok) throw new Error(`not loaded: ${JSON.stringify(loaded)}`)
  return loaded.record
}

export function meta(rec: RemoteRecord, label: string): string | undefined {
  return rec.meta.find(entry => entry.label === label)?.value
}
