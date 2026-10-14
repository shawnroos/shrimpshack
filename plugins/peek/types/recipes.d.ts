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
