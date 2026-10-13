export type Mode = 'view' | 'recent' | 'gallery' | 'groups'

export type Mention = { href: string; at: number; count: number; isArtifact?: boolean }

export type Heading = { level: number; text: string }

export type RemoteKind = 'gh-repo' | 'gh-issue' | 'gh-pr' | 'linear-issue' | 'linear-project' | 'slack-thread' | 'web'

export type RemoteFailure =
  | 'cli-missing'
  | 'cli-unauthed'
  | 'key-missing'
  | 'key-refused'
  | 'not-found-or-no-access'
  | 'gone'
  | 'rate-limited'
  | 'offline'
  | 'query-bug'
  | 'fetch-blocked'
  | 'process-unavailable'
  | 'slack-unavailable'

export type LiveFailure = 'live-unavailable' | 'live-crashed' | 'live-stalled'

export type Tier = 'cli' | 'api' | 'mcp' | 'session'

export type RemoteFile = { id: string; name: string; type: string; size: string }

export type RemoteComment = {
  author: string
  at: string
  body: string
  depth?: number
  isReview?: boolean
  authorId?: string
  href?: string
  files?: RemoteFile[]
}

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
  lead?: RemoteComment
  avatars?: Record<string, string>
  lists?: RemoteList[]
  og?: { title?: string; description?: string; siteName?: string; image?: string }
  favicon?: string
  media?: Record<string, { file?: string; play?: string }>
  browserUrl: string
}

export type Loaded =
  | { ok: true; record: RemoteRecord; tier: Tier; fetchedAt: number; liveFailure?: RemoteFailure }
  | { ok: false; failure: RemoteFailure; detail?: string }

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
    failure?: RemoteFailure
    failureDetail?: string
    staleSince?: number
    favicon?: { file: string; width: number; height: number }
    preview?: { file: string; width: number; height: number }
    pictures?: Record<string, { file: string; width: number; height: number }>
    avatars?: Record<string, { file: string; width: number; height: number }>
  }
}

export type GroupActor = 'agent' | 'person'

export type SectionLayout = 'cards' | 'list'

export type GroupSection = { id: string; title: string; layout?: SectionLayout }

export type GroupItem = { ref: string; section?: string; addedBy: GroupActor; addedAt: number; label?: string }

export type Group = {
  projectKey: string
  id: string
  title: string
  description: string
  starred: boolean
  updatedAt: number
  sections: GroupSection[]
  items: GroupItem[]
  removed: string[]
}

// A section is named by its id or, case-insensitively, by its title, so one call can add a section and fill it.
export type GroupOp =
  | { op: 'setTitle'; title: string }
  | { op: 'setDescription'; description: string }
  | { op: 'addSection'; title: string; layout?: SectionLayout }
  | { op: 'renameSection'; section: string; title: string }
  | { op: 'removeSection'; section: string }
  | { op: 'setSectionLayout'; section: string; layout: SectionLayout }
  | { op: 'reorderSections'; order: string[] }
  | { op: 'addItem'; ref: string; section?: string; label?: string; force?: boolean }
  | { op: 'moveItem'; ref: string; section?: string }
  | { op: 'removeItem'; ref: string; force?: boolean }

export type GroupOutcome = {
  op: GroupOp['op'] | 'create' | 'delete' | 'star'
  status: 'applied' | 'unchanged' | 'refused'
  reason: string
  ref?: string
  groupId?: string
  sectionId?: string
  needsForce?: boolean
}

export type GroupResult = { group: Group | null; outcomes: GroupOutcome[] }

export type GroupContext = { now: number; newId: () => string; actor: GroupActor; others: readonly Group[] }

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
      openGroup: { id: string; item: string | null } | null
    }
  }
}
