// 0 exact label, 1 label starts with the query, 2 every word starts a label word, 3 anywhere.
export function rankCommands<T extends { label: string }>(rows: readonly T[], filter: string): T[] {
  const words = filter.toLowerCase().split(/\s+/).filter(Boolean)
  if (words.length === 0) return [...rows]
  const query = words.join(' ')
  const scored = rows.flatMap((row, index) => {
    const label = row.label.toLowerCase()
    if (!words.every(word => label.includes(word))) return []
    const labelWords = label.split(/[^\p{L}\p{N}]+/u).filter(Boolean)
    const score =
      label === query ? 0
      : label.startsWith(query) ? 1
      : words.every(word => labelWords.some(one => one.startsWith(word))) ? 2
      : 3
    return [{ row, score, index }]
  })
  return scored.sort((a, b) => a.score - b.score || a.index - b.index).map(one => one.row)
}
