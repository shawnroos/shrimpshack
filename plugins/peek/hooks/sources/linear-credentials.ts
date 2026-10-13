import type { RemoteFailure } from '../../types'
import { sessionMemo } from '../cache'
import type { SourceIo } from '../source-io'

// Copied from herdr-board crates/board-daemon/src/linear/credential.rs: one Keychain item serves both tools.
const KEYCHAIN_SERVICE = 'work-linear'
const KEYCHAIN_ACCOUNT = 'linear-api-key'
const SECURITY_BIN = '/usr/bin/security'
// A locked Keychain holds `security` on an unlock prompt nobody can answer, so the read is bounded.
const KEYCHAIN_TIMEOUT_MS = 3000

type CredentialIo = Pick<SourceIo, 'sessionId' | 'run' | 'linearKeyEnv' | 'home' | 'read'>

const keys = sessionMemo<string | null>()

function unquote(raw: string): string {
  const text = raw.trim()
  const first = text[0]
  if (text.length >= 2 && (first === '"' || first === "'") && text.endsWith(first)) return text.slice(1, -1)
  return text
}

export async function findKey(io: CredentialIo): Promise<string | null> {
  return keys.get(await io.sessionId(), () => lookupKey(io))
}

export async function forgetKey(io: Pick<SourceIo, 'sessionId'>, failure: RemoteFailure): Promise<void> {
  if (failure === 'key-refused' || failure === 'key-missing') keys.forget(await io.sessionId())
}

async function lookupKey(io: CredentialIo): Promise<string | null> {
  const keychain = await io
    .run([SECURITY_BIN, 'find-generic-password', '-a', KEYCHAIN_ACCOUNT, '-s', KEYCHAIN_SERVICE, '-w'], { timeoutMs: KEYCHAIN_TIMEOUT_MS })
    .catch(() => null)
  const fromKeychain = keychain && keychain.exitCode === 0 ? keychain.stdout.trim() : ''
  if (fromKeychain) return fromKeychain
  const fromEnv = ((await io.linearKeyEnv().catch(() => undefined)) ?? '').trim()
  if (fromEnv) return fromEnv
  const home = (await io.home().catch(() => undefined)) ?? ''
  if (!home) return null
  const secrets = await io.read(`${home}/.secrets`).catch(() => '')
  const line = /^[ \t]*(?:export[ \t]+)?LINEAR_API_KEY[ \t]*=[ \t]*(.*?)[ \t]*$/m.exec(secrets)
  const fromFile = line ? unquote(line[1] ?? '') : ''
  return fromFile || null
}
