import type { Group, GroupResult } from '../types/groups'
import { fileOf, isGroupId, listGroups, readGroup, writeGroup } from './groups'
import type { GroupPlace, GroupWrite, GroupsIo } from './groups'

export type GroupStore = {
  shown: (io: GroupsIo, place: GroupPlace) => Promise<readonly Group[]>
  shownOne: (io: GroupsIo, place: GroupPlace, id: string) => Promise<Group | null>
  write: (io: GroupsIo, place: GroupPlace, id: string, change: (current: Group | null) => GroupResult) => Promise<GroupWrite>
}

export function createGroupStore(): GroupStore {
  // Render reads only: a write that decided from these could act on another session's stale group.
  const groupLists = new Map<string, { mtimeMs: number | null; groups: readonly Group[] }>()
  let openGroupFile: { file: string; projectKey: string; mtimeMs: number; group: Group | null } | null = null

  return {
    async shown(io, place) {
      const mtimeMs = (await io.stat(place.dir))?.mtimeMs ?? null
      const key = `${place.dir}|${place.projectKey}`
      const known = groupLists.get(key)
      if (known && known.mtimeMs === mtimeMs) return known.groups
      const groups = await listGroups(io, place)
      groupLists.set(key, { mtimeMs, groups })
      return groups
    },
    async shownOne(io, place, id) {
      const file = fileOf(place, id)
      const stat = isGroupId(id) ? await io.stat(file) : null
      const known = openGroupFile
      if (stat && known?.file === file && known.projectKey === place.projectKey && known.mtimeMs === stat.mtimeMs) return known.group
      const group = await readGroup(io, place, id)
      openGroupFile = stat ? { file, projectKey: place.projectKey, mtimeMs: stat.mtimeMs, group } : null
      return group
    },
    write(io, place, id, change) {
      return writeGroup(io, place, id, change).then(write => {
        if (write.ok && write.isChanged) {
          groupLists.delete(`${place.dir}|${place.projectKey}`)
          openGroupFile = null
        }
        return write
      })
    },
  }
}
