import type { EngineInterface, HttpInit, HttpResponse, ProcessRunInit, ProcessRunResult } from 'claude-code'

type Fs = EngineInterface['fs']

// `$` cannot cross an import (claude plugin validate), so register.tsx builds this record from `$` and each module
// names the members it uses with Pick.
export type Ports = {
  sessionId: () => Promise<string>
  sessionRoot: () => Promise<string>
  cwd: () => Promise<string>
  home: () => Promise<string | undefined>
  linearKeyEnv: () => Promise<string | undefined>
  run: (argv: readonly string[], init?: ProcessRunInit) => Promise<ProcessRunResult>
  spawn: (argv: readonly string[]) => AsyncGenerator<{ stream: 'stdout' | 'stderr'; text: string }, unknown>
  fetch: (url: string, init?: HttpInit) => Promise<HttpResponse>
  read: (path: string) => Promise<string>
  readBytes: (path: string) => Promise<{ base64: string }>
  write: (path: string, text: string) => Promise<void>
  list: (path: string) => ReturnType<Fs['list']>
  stat: (path: string) => ReturnType<Fs['stat']>
  exists: (path: string) => Promise<boolean>
  now: () => Promise<number>
  sleep: (ms: number) => Promise<void>
  every: (ms: number, fn: () => void) => void
  after: (ms: number, fn: () => void) => { cancel: () => void }
  mcpCall: (server: string, tool: string, args: Record<string, unknown>) => Promise<{ content: unknown[]; isError: boolean }>
}
