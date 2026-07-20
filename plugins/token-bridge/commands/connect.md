---
description: "Connect a codebase to a Paper file — scaffold its token-bridge.config.json (reference an existing file or create a new one)"
argument-hint: "--repo <path> --source <css-path> (--file <id|URL> | --create-file [--name <n>]) [--prefix <p>] [--convention data-attribute|media-query|class ...]"
---

# Connect a repo to a Paper file

One-time setup: write a `token-bridge.config.json` at the target codebase's root binding it to a single Paper file, so the other commands (status, normalize-to-code, normalize-to-design, refresh-components) know the source CSS, the theme convention, and the target file.

Either reference an existing Paper file by its id or URL, or create a fresh one via the Paper daemon and capture its id. It refuses to overwrite an existing config unless `--force`, so re-running is safe.

Use the Skill tool to invoke: `connect`
