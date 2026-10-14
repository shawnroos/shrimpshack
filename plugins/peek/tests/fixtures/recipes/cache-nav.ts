import type { NavIo } from '../../../hooks/navigation'
import { recipeNav } from './nav'

// Text files peek writes in the recipe world (the recipe cache), and the `/bin/mv` that moves one into place.
export const written = new Map<string, string>()

const missing = (path: string) => Object.assign(new Error(`ENOENT: ${path}`), { code: 'ENOENT' })

export const cacheNav: NavIo = {
  ...recipeNav.io,
  readFile: async path => {
    const text = written.get(path)
    if (text === undefined) throw missing(path)
    return text
  },
  writeFile: async (path, text) => {
    written.set(path, text)
  },
  run: async (argv, init) => {
    if (argv[0] !== '/bin/mv') return recipeNav.io.run(argv, init)
    const [from, to] = argv.slice(-2)
    const text = from === undefined ? undefined : written.get(from)
    if (from === undefined || to === undefined || text === undefined) return { exitCode: 1, stdout: '', stderr: 'no such file', isStdoutTruncated: false, isStderrTruncated: false }
    written.delete(from)
    written.set(to, text)
    return { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
  },
}
