// Shapes copied from real mcp__plugin_slack_slack__slack_read_thread / slack_read_channel results (2026-10-12), values replaced.
export const THREAD_TEXT = [
  '=== THREAD PARENT MESSAGE ===',
  'From: Ada Lovelace <ada@example.com> (U0AAA1111)',
  'Time: 2026-10-12 01:03:16 CAT',
  'Message TS: 1791759796.763609',
  '_Widgets 0.82 published_',
  '',
  '`widgets` _0.82.0_, tag `next` only. See <https://github.com/acme/widgets/pull/147|widgets #147> and ping <@U0BBB2222|Grace>.',
  '• *Contract change:* `capabilities` gains `cut`.',
  '• Built from &lt;main&gt; &amp; nothing else.',
  'Files: notes.mp4 (ID: F0AAA, video/quicktime, 2.0 MB)',
  '',
  '=== THREAD REPLIES (2 total) ===',
  '',
  '--- Reply 1 of 2 ---',
  'From: Grace Hopper <grace@example.com> (U0BBB2222)',
  'Time: 2026-10-12 01:25:28 CAT',
  'Message TS: 1791761128.357239',
  'Text only: ~old~ new wording.',
  '',
  '--- Reply 2 of 2 ---',
  'From: Ada Lovelace <ada@example.com> (U0AAA1111)',
  'Time: 2026-10-12 02:00:00 CAT',
  'Message TS: 1791763200.000100',
  'Thanks, see <https://example.com/doc>.',
  'Reactions: +1 (1)',
  '',
].join('\n')

export const THREAD_RESULT = JSON.stringify({ messages: THREAD_TEXT, pagination_info: 'There are no more messages in this thread.\n' })

export const THREAD_MORE = JSON.stringify({ messages: THREAD_TEXT, pagination_info: 'There are more messages in this thread. To view the next page, use cursor: `abc`\n' })

export const CHANNEL_RESULT = JSON.stringify({
  messages: 'Channel: #release-notes (C0123ABCD)\n\n=== Message from Ada Lovelace <ada@example.com> (U0AAA1111) at 2026-10-12 01:03:16 CAT === \nMessage TS: 1791759796.763609\nhello\n',
  pagination_info: 'There are more messages available.',
})

// The server's own spelling: "messsages".
export const LONE_MESSAGE = JSON.stringify({
  messages: '=== THREAD PARENT MESSAGE ===\nFrom: Ada Lovelace <ada@example.com> (U0AAA1111)\nTime: 2026-10-12 01:25:28 CAT\nMessage TS: 1791761128.357239\nhello\n\nNo thread messsages\n',
  pagination_info: 'There are no more messages in this thread.\n',
})

// Slack Web API conversations.replies / conversations.info, as `slack api` would print them.
export const CLI_REPLIES = JSON.stringify({
  ok: true,
  messages: [
    { ts: '1791759796.763609', user: 'U0AAA1111', user_profile: { real_name: 'Ada Lovelace' }, text: 'Parent *text*', reply_count: 1 },
    { ts: '1791761128.357239', user: 'U0BBB2222', text: 'A reply' },
  ],
  has_more: false,
})

export const CLI_CHANNEL = JSON.stringify({ ok: true, channel: { id: 'C0123ABCD', name: 'release-notes' } })

// A parent with a screenshot and a reply carrying two files on one Files: line. The single-file line is copied from a real
// thread; two files on one line joined by ", " is assumed, not observed.
export const FILES_TEXT = [
  '=== THREAD PARENT MESSAGE ===',
  'From: Ada Lovelace <ada@example.com> (U0AAA1111)',
  'Time: 2026-10-06 19:23:12 CAT',
  'Message TS: 1791307392.000200',
  'Cutting too early, see the shot.',
  'Files: Screenshot 2026-10-06 at 1.22.47 PM.png (ID: F0C7A02R0AY, image/png, 221.4 KB)',
  '',
  '=== THREAD REPLIES (1 total) ===',
  '',
  '--- Reply 1 of 1 ---',
  'From: Grace Hopper <grace@example.com> (U0BBB2222)',
  'Time: 2026-10-06 19:30:00 CAT',
  'Message TS: 1791307800.000300',
  'Spec attached.',
  'Files: spec, v2.pdf (ID: F0DDD4444, application/pdf, 1.2 MB), crop.jpg (ID: F0EEE5555, image/jpeg, 80.0 KB)',
  '',
].join('\n')

export const FILES_RESULT = JSON.stringify({ messages: FILES_TEXT, pagination_info: 'There are no more messages in this thread.\n' })

// slack_read_file on an image, as the session saw it: a metadata text block, then an image block. The harness showed the
// image; `data` + `mimeType` is the MCP image-block shape, inferred rather than seen as raw JSON.
export function fileResult(id: string, data: string, mimeType = 'image/png') {
  return {
    content: [
      { type: 'text', text: `File ID: ${id}\nTitle: Screenshot 2026-10-06 at 1.22.47 PM.png\nMIME Type: ${mimeType}\nSize: 221.4 KB\nCreated: 2026-10-06 19:23:12 CAT\n` },
      { type: 'image', data, mimeType },
    ],
    isError: false,
  }
}

// slack_search_users, detailed: the only Slack MCP read that returns a profile picture (slack_read_user_profile has none).
export function usersResult(people: { name: string; id: string; pic?: string }[]): string {
  const blocks = people.map(
    (one, i) =>
      `### Result ${i + 1} of ${people.length}\nName: ${one.name}\nUser ID: ${one.id}\nTitle: Engineer\nEmail: x@example.com\nTimezone: Africa/Harare\n${one.pic ? `Profile Pic: [Photo](${one.pic})\n` : ''}Permalink: [link](https://acme.slack.com/team/${one.id})\n\n---\n\n`,
  )
  return JSON.stringify({ results: `# Search Results for: \n\n## Users (${people.length} results)\n${blocks.join('')}`, pagination_info: 'End of results - No more pages available.\\n' })
}

export const ADA_PIC = 'https://avatars.slack-edge.com/2022-11-23/4416337781877_a24dc51906aa11d635a2_original.png'
