export const STATUS_VALUES = ['todo', 'doing', 'done', 'cancelled'] as const
export type TaskStatus = (typeof STATUS_VALUES)[number]
export const OPEN_STATUSES: ReadonlySet<string> = new Set<TaskStatus>(['todo', 'doing'])
export const CLOSED_STATUSES: ReadonlySet<string> = new Set<TaskStatus>(['done', 'cancelled'])
