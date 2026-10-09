export type Mode = 'view' | 'recent' | 'gallery'

export type Mention = { href: string; at: number; count: number; isArtifact?: boolean }

export type Heading = { level: number; text: string }

export type RemoteKind = 'gh-repo' | 'gh-issue' | 'gh-pr' | 'linear-issue' | 'linear-project' | 'web'

export type FailureKind =
  | 'cli-missing'
  | 'cli-unauthed'
  | 'key-missing'
  | 'key-refused'
  | 'not-found-or-no-access'
  | 'rate-limited'
  | 'offline'
  | 'query-bug'
  | 'fetch-blocked'
  | 'process-unavailable'

export type Tier = 'cli' | 'api' | 'session'

export type RemoteComment = { author: string; at: string; body: string; depth?: number; isReview?: boolean }

export type RemoteListItem = { href: string; title: string; meta?: string; status?: string }

export type RemoteList = { heading: string; items: RemoteListItem[]; total: number; isPartial?: boolean }

export type CiTone = 'bad' | 'wait' | 'ok' | 'none'

export type RemoteRecord = {
  address: string
  kind: RemoteKind
  title: string
  trail: string[]
  status?: string
  isFrozen?: boolean
  meta: { label: string; value: string }[]
  stats?: { additions: number; deletions: number; changedFiles: number; ci: string; ciTone: CiTone }
  body?: string
  comments?: { shown: RemoteComment[]; total: number; inline?: number }
  lists?: RemoteList[]
  og?: { title?: string; description?: string; siteName?: string; image?: string }
  favicon?: string
  browserUrl: string
}

export type Loaded =
  | { ok: true; record: RemoteRecord; tier: Tier; fetchedAt: number; liveFailure?: FailureKind }
  | { ok: false; failure: FailureKind }

export type View = {
  href: string
  title: string
  location: string
  root?: string
  isWorktree?: boolean
  kind?: string
  meta?: string
  tasks?: string
  summary?: string
  table?: { header: string[]; rows: string[][]; total: number }
  dir?: { name: string; isDir: boolean; size: number; mtimeMs: number }[]
  outline?: Heading[]
  markdown?: string
  code?: { source: string; language: string; startLine: number; focusLine?: number }
  image?: { file: string; width: number; height: number }
  error?: string
  remote?: {
    record?: RemoteRecord
    tier?: Tier
    fetchedAt?: number
    failure?: FailureKind
    staleSince?: number
    favicon?: { file: string; width: number; height: number }
    preview?: { file: string; width: number; height: number }
  }
}

declare module 'claude-code' {
  interface PluginState {
    peek: {
      view: View | null
      mentions: Mention[]
      mode: Mode
      page: number
      trail: string[]
      section: number
      menuOpen: boolean
      scope: 'session' | 'worktree' | 'repo'
      galleryType: 'all' | 'markdown' | 'code' | 'data' | 'image' | 'diagram' | 'html'
      gallerySort: 'recent' | 'name' | 'size' | 'mentions'
      galleryFilter: string
      roleFilter: 'all' | 'artifacts' | 'touched'
      stars: string[]
      cursor: number
      menuFilter: string
      galleryPresses: number
      galleryText: string
      galleryPick: string
    }
  }
}
