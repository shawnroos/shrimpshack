import { markedStderr } from '../wire'

// The engine cuts stdout at 4 MiB, so the status line rides on stderr where the cut cannot drop it.
export const MARKER = '__peek_curl__ '
// The content type rides on stderr so the stdout fields every caller parses keep their order.
export const TYPE_MARKER = '__peek_type__ '

export const PAGE_FORMAT = `%{stderr}${MARKER}%{http_code} %{url_effective}`
export const DOWNLOAD_FORMAT = `%{http_code} %{size_download} %{redirect_url}%{stderr}${TYPE_MARKER}%{content_type}`

// null when the status line never arrived; status is NaN when it arrived empty.
export function pageStatus(stderr: string): { status: number; finalUrl: string } | null {
  const marked = markedStderr(stderr, MARKER)
  if (marked === null) return null
  const [code = '', ...rest] = marked.trim().split(' ')
  return { status: Number.parseInt(code, 10), finalUrl: rest.join(' ') }
}

export function downloadStatus(stdout: string, stderr: string): { status: number; size: number; redirect: string; type?: string } {
  const [code = '', size = '', ...rest] = stdout.trim().split(' ')
  const type = markedStderr(stderr, TYPE_MARKER)?.trim() || undefined
  return { status: Number.parseInt(code, 10), size: Number.parseInt(size, 10), redirect: rest.join(' '), ...(type ? { type } : {}) }
}
