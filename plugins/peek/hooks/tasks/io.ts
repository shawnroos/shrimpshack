import type { GroupsIo } from '../groups'
import type { TasksIo } from './store'

export const tasksIoOf = (io: { groupsIo: () => GroupsIo; home: TasksIo['home'] }): TasksIo => ({ ...io.groupsIo(), home: io.home })
