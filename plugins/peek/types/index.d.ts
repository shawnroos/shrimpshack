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

export type PropScalar = string | number | boolean | null
// Spelled out rather than recursive: a recursive type on View is too deep for the state types to instantiate.
export type PropValue = PropScalar | PropScalar[] | Record<string, PropScalar | PropScalar[] | Record<string, PropScalar | PropScalar[]>>

export type View = {
  href: string
  title: string
  location: string
  root?: string
  isWorktree?: boolean
  kind?: string
  meta?: string
  tasks?: string
  props?: Record<string, PropValue>
  summary?: string
  table?: { header: string[]; rows: string[][]; total: number }
  dir?: { name: string; isDir: boolean; size: number; mtimeMs: number }[]
  outline?: Heading[]
  markdown?: string
  code?: { source: string; language: string; startLine: number; focusLine?: number }
  image?: { file: string; width: number; height: number }
  error?: string
  page?: RecipePage
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

// The recipe page vocabulary lives here because this contract file may not import; types/recipes.d.ts re-exports it.
export type Detail = { label: string; value: string }
export type MediaItem = { url: string; alt?: string; kind: 'image' | 'video' }
export type TableRow = { cells: string[]; href?: string }
export type CardItem = { title: string; meta?: string; href?: string; image?: string }
export type PageListItem = { title: string; meta?: string; href?: string }

export type MarkdownBlock = { type: 'markdown'; text: string }
export type MediaBlock = { type: 'media'; items: MediaItem[] }
export type PageTableBlock = { type: 'table'; columns: string[]; rows: TableRow[] }
export type CardsBlock = { type: 'cards'; items: CardItem[] }
export type PageListBlock = { type: 'list'; items: PageListItem[] }
export type FieldsBlock = { type: 'fields'; rows: Detail[] }
export type PageBlock = MarkdownBlock | MediaBlock | PageTableBlock | CardsBlock | PageListBlock | FieldsBlock
export type BlockType = PageBlock['type']

export type PageSection = { heading?: string; block: PageBlock }
export type OpenAction = { label: string; open: string }
export type CopyAction = { label: string; copy: string }
export type PageAction = OpenAction | CopyAction
export type Page = { title: string; details?: Detail[]; sections: PageSection[]; actions?: PageAction[] }

export type RecipeFailureKind =
  | 'invalid-recipe'
  | 'changed-during-run'
  | 'needs-permission'
  | 'started-failed'
  | 'timeout'
  | 'exit-nonzero'
  | 'output-truncated'
  | 'not-JSON'
  | 'server-not-connected'
  | 'tool-error'
  | 'empty-result'
  | 'invalid-page'
  | 'route'

export type RecipeRouted = {
  id: string
  name: string
  link: string
  isDraft: boolean
  digest: string
  refreshMinutes: number
  review?: RecipeReview
  isRefreshing?: boolean
}

export type RecipePage =
  | (RecipeRouted & { phase: 'loading' })
  | (RecipeRouted & {
      phase: 'ready'
      page: Page
      fetchedAt: number
      media?: Record<string, { file?: string; play?: string }>
      pictures?: Record<string, { file: string; width: number; height: number }>
      refreshFailure?: string
    })
  | (RecipeRouted & { phase: 'failed'; failure: string; failureKind: RecipeFailureKind })
  | { phase: 'conflict'; link: string; isDraft: boolean; failure: string }

export type ReviewFile = { path: string; change: 'new' | 'changed'; size: number; text?: string }
export type ReviewRefusal = { kind: 'changed' } | { kind: 'overlap'; id: string } | { kind: 'failed'; message: string }
export type RecipeReview = {
  runs: string
  match: string[]
  overrides: string[]
  refreshMinutes: number
  env: string[]
  overlap?: string
  warnings: string[]
  files: ReviewFile[]
  removed: string[]
  isStructureOnly: boolean
  refusal?: ReviewRefusal
  isShowingFiles?: boolean
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
      openGroup: { id: string; item: string | null } | null
    }
  }
}
