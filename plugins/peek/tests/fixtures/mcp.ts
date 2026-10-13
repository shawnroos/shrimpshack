import type { McpToolResult } from 'claude-code'

// The MCP result shape `$.mcp.call` resolves with: content blocks plus isError, as in tests/fixtures/slack/mcp.ts.
export function textResult(text: string, isError = false): McpToolResult {
  return { content: [{ type: 'text', text }], isError }
}

export function blocksResult(texts: readonly string[]): McpToolResult {
  return { content: texts.map(text => ({ type: 'text', text })), isError: false }
}

export function structuredResult(value: unknown): McpToolResult {
  return { content: [], isError: false, structuredContent: value }
}

export const PAGE_RESULT_PAGE = {
  title: 'ENG-12 Fix the build',
  details: [{ label: 'Status', value: 'In Progress' }],
  sections: [{ heading: 'Description', block: { type: 'markdown', text: 'The build is red.' } }],
}

export const PAGE_RESULT = textResult(JSON.stringify(PAGE_RESULT_PAGE))

export const TOOL_ERROR = textResult('Issue not found: ENG-999', true)
