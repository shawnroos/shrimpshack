export type Mode = 'view' | 'recent' | 'gallery'

export type Mention = { href: string; at: number; count: number; isArtifact?: boolean }

export type Heading = { level: number; text: string }

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
