export type Mode = 'view' | 'recent'

export type Mention = { href: string; at: number; count: number }

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
      menuFilter: string
      galleryPresses: number
      galleryText: string
      galleryPick: string
    }
  }
}
