import { expect, test } from 'claude-code/testing'

import type { ClassicHookInputs, ClassicResultFields, SessionEndReason } from 'claude-code'

// Facts observed live on 2026-10-14 (Claude Code 2.1.299) in a disposable
// `claude -p --session-id <uuid>` session, plus a read-only census of
// ~/.claude/tasks. Full evidence: the U1 findings file of the plan run.
//
// Task folders
// - Current folders are named by the full session UUID
//   (~/.claude/tasks/<session uuid>/); 322 older `session-<first 8 hex>`
//   folders exist, all without item files.
// - One item per file, `<id>.json`, ids are decimal strings from "1", plus a
//   0-byte `.lock`. Items carry id, subject, description, status, blocks,
//   blockedBy (activeForm when set) and no repo or folder.
// - Under -p and --resume nothing is deleted: after completing 1-3 and
//   creating 4, files 1.json..4.json all remain. Ids continue across
//   --resume and across a fully completed list.
// - A list reset (not reproduced headless) leaves `.highwatermark` holding the
//   last id before the reset, and the next id is watermark + 1: one live
//   folder holds `.highwatermark` = 18 with items 19..50; a cleared folder
//   holds only `.lock` and `.highwatermark` = 3. A cleared folder is therefore
//   not empty; "cleared" means no `*.json` left.
//
// Hooks
// - Classic TaskCreated and TaskCompleted fired live for same-session task
//   tool calls (task_id, task_subject, task_description). No classic event
//   covers a move to in_progress.
// - SessionEnd reason was `other` for each -p run, and the same session id
//   was then reopened by --resume and kept counting ids, so `other` is not
//   final.
// - A plugin can hook classic FileChanged (file_path, event) and return
//   SessionStart watchPaths; the types put no limit on the path, and delivery
//   for a path outside the repo was not proven, so KTD6 stays on the poll.

const END_STATE: Record<SessionEndReason, 'ended' | 'cleared' | 'replaced'> = {
  clear: 'cleared',
  resume: 'replaced',
  prompt_input_exit: 'ended',
  logout: 'ended',
  other: 'ended',
}

const FILE_EVENTS: Record<ClassicHookInputs['FileChanged']['event'], true> = {
  change: true,
  add: true,
  unlink: true,
}

const SESSION_START_SOURCES: Record<ClassicHookInputs['SessionStart']['source'], true> = {
  startup: true,
  resume: true,
  clear: true,
  compact: true,
  fork: true,
}

const isWatchPathsReturnable: 'watchPaths' extends ClassicResultFields['SessionStart'] ? true : false = true

test('probes: session-end reasons are the five the engine types name', () => {
  expect(Object.keys(END_STATE).sort()).toEqual(['clear', 'logout', 'other', 'prompt_input_exit', 'resume'])
})

test('probes: a plugin can be told of file changes and can name watch paths at session start', () => {
  expect(Object.keys(FILE_EVENTS).sort()).toEqual(['add', 'change', 'unlink'])
  expect(isWatchPathsReturnable).toBe(true)
})

test('probes: session start reports clear and resume as sources', () => {
  expect(Object.keys(SESSION_START_SOURCES).sort()).toEqual(['clear', 'compact', 'fork', 'resume', 'startup'])
})
