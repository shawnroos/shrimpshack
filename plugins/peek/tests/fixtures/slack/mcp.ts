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
