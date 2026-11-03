---
title: "feat: Rituals that ship inside the repo"
type: feat
status: revised-after-review-awaiting-pm
date: 2026-11-02
product_contract_source: ce-plan-bootstrap
origin: Shawn's pick (option A, point 7 of docs/ritual-options-note.md)
---

# feat: Rituals that ship inside the repo

The PM approved this design (answers below). Second of two PRs; it follows the ritual-checks plan. This changes who can make the PM run something, so reviewers read the authority section first.

## Goal Capsule

**Objective.** A ritual written as a file inside a repo is in force for every programme that has that repo in its remit, on any machine with a clone. The shrimpshack "versions bumped" ritual then ships with shrimpshack.

**Shawn's decision (typed in the PM chat).** Read rituals from a file inside the repo. Treat a changed repo file as code that is reviewed.

**Depends on.** PR #192, then the ritual-checks PR (the shipped example uses `check: versions-bumped`).

**Today.** The repo layer is a section of the machine-wide `rituals.json` (confirmed in PR #192; a test pins it). Nothing is read from inside a repo.

## Authority: what a repo file can and cannot do

| Question | Answer |
|---|---|
| Does a file in a repo make the PM run something on its own? | **No.** A file ritual is only *proposed* until Shawn adopts it. |
| What is "reviewed like code"? | Two gates. (1) The PM reads the file only from the repo's **default branch** (committed, merged), never from a worker's folder or an uncommitted edit, so a change takes effect only after the repo's normal review and merge. (2) Shawn's typed words adopt the ritual by **content hash**. |
| What happens when the file changes? | Its hash changes, so the ritual goes back to *proposed* and the PM shows Shawn what changed. Until he types his words, the old adopted version stays in force (or none, if it was never adopted). |
| Can a file carry more power than a stored ritual? | **No.** Same validator: a step that names a protected action is refused; `offers` are questions; `check` names must be in the fixed list. A file cannot add a command. |
| Can a worker edit the file to change the PM's behaviour? | A worker can open a PR that edits it. That PR is reviewed and merged by the usual process, and Shawn still has to adopt the new hash. A worker's local edit has no effect. |
| What if the file is bad? | A rejected row names the file, line and reason in the Programme view. It never crashes the sweep and never runs. |

## Design

1. **Location and format.** One convention with the shipped behaviours (#165): a folder named for the kind, one `<id>.md` per entry, flat frontmatter keys, the same parser module, the same 64 KB file and 500-character line caps (`programme_behaviour_files.py`: `FOLDER_NAME`, `MAX_FILE_BYTES`, `MAX_LINE_CHARS`). Shipped behaviours live at `<plugin>/behaviours/`; repo rituals live at `<repo>/.auto/rituals/`. The `.auto/` prefix keeps the repo root clean; the folder is one constant, so moving it is a one-line change. Fields match a ritual entry: `when`, `schedule` or `trigger`, `steps`, optional `offers`, optional `check`, `why`.
2. **Which repos.** The remit repos of the programme (`remit.repos[].path`). Each is read with `git show <default-ref>:.auto/rituals/<file>` and `git ls-tree`, never from the working folder. Default ref: the repo's `origin/HEAD` target, falling back to `main`. If the ref cannot be resolved, the repo is skipped with a notice in the view (not silently).
3. **Limits.** Only regular files; symlinks refused; names `^[a-z][a-z0-9-]*\.md$`; file size cap; at most N files per repo.
4. **Layer and ids.** File rituals are layer `repo` with `source: file`. An id used by both a file and a stored repo entry is rejected on both with a row naming each, so there is no silent winner. A programme-layer ritual with the same id still wins, as today.
5. **Adoption.** The existing adoption machinery (`adopt`, `content_hash`, the `rule_adopted` row) is reused with the hash of the file's committed content. State is `proposed` until adopted. A programme records its adoption in its own record, since file content differs per commit.
6. **Authoring.** v1 loads and adopts only; people write the file by hand in a normal PR. A later verb could draft one from a stored ritual; out of scope here.
7. **Programme view.** Shows layer "repo (file)", the file path, the commit it was read at **and the age of that ref** (time since its commit), and adoption state (adopted / proposed / changed since adoption).

## Units (sequential)

| Unit | What | Tests (red first) |
|---|---|---|
| F1 | File parser and validator for `.auto/rituals/*.md` (reuse the behaviour-file frontmatter parser) | each bad frontmatter case becomes a rejected row; protected step in a file refused; `offers` accepted; unknown `check` name refused |
| F2 | Read from the default branch only | an uncommitted edit and a worker-branch edit are not picked up; unresolved ref is a visible notice; symlink and path-traversal names refused; size cap |
| F3 | Resolve: merge file entries with stored entries; duplicate-id rule | same id in file and store rejects both; programme layer still wins |
| F4 | Adoption by content hash | a new file is `proposed` and not in force; adoption by typed words puts it in force; a changed file returns to `proposed` and the adopted older hash stays in force until re-adopted |
| F5 | Programme view, `programme-rituals-format.md`, skill and sweep reference text; the shrimpshack `plugin-versions-bumped.md` as the shipped example (after the checks PR) | skill test; the example validates and appears as `proposed` |

## Risks

| Risk | Mitigation |
|---|---|
| The repo becomes a way to change what the PM does | default-branch-only reading plus per-hash adoption; no new powers in a file |
| A clone is stale, so the "default branch" is old | read the local default ref and show the commit hash in the view; do not fetch automatically in v1 |
| Adoption record bloat | one small record per adopted hash; old hashes are pruned when superseded |
| Old plugin copies ignore the folder | harmless: they do not read it, and no store key changes |

## PM answers (settled)

1. Keep both gates: Shawn's content-hash adoption and the default-branch merge review. "Reviewed like code" means both.
2. Read the local default branch with no auto-fetch, and show the age of the ref it read in the row.
3. Use the same folder and file convention as the shipped default behaviours (see Design 1).
4. No authoring command in v1.

## Changes after the document review (1 P1 theme: adoption must be tied to the content Shawn saw)

The review found 7 P1 and 7 P2 issues. These change the design above; they tighten it.

1. **Adoption is bound to what Shawn saw.** Shawn's typed words must name the ritual id and the content hash (a short prefix is shown in the proposal), like `adopt-behaviour-file`. If the file moved after the proposal was shown, the hash differs and the adoption is refused.
2. **Per-programme adoption is new work.** `adopt()` records nothing today and the store is machine-wide. A new adoption record in the programme block holds `{ritual id, repo key, content hash, a snapshot of the adopted entry}`. The snapshot is the "old adopted version stays in force" source, since the branch holds only the new content.
3. **The default-branch gate is Shawn's adoption plus a safe read, not a local ref alone.** A local `main` can hold unpushed commits and workers share the git folder, so the read is `origin/HEAD` target only (no fallback to local `main`; if it does not resolve, skip with a visible notice), the symref target is checked to be a branch under `refs/remotes/origin/`, and the content hash Shawn adopts is the control.
4. **Safe git reads.** Use the existing git runner `programme_gitio.Git`, not raw `git show`. Read with `cat-file commit`, `ls-tree -z -l` and `cat-file blob <oid>` (no commands that honour repo-set `gpg.program` or `textconv`). Check size before reading; refuse symlinks and gitlinks, including a symlinked `.auto` or `.auto/rituals`; require `rev-parse --show-toplevel` to equal the remit path; exclude `worker_repos`.
5. **`resolve()` must not let a proposed or declined file hide an adopted or personal entry** with the same id (the behaviours resolver has this guard; rituals do not yet).
6. **A repo file with `check:` is safe only because Plan 1 never runs a repo script.** Plan 1's checks are plugin code, so a file changes nothing about what runs. Adoption of a file with a check must name the check, per Plan 1.
7. **Parser work is larger than "reuse".** `KEYS` rejects `steps`, `offers`, `schedule`, `check`; the body parser accepts only Do/Don't; `entry_from_text` is tied to the behaviour validator; `source` is an object in the ritual validator. Plan: add a ritual front end over the shared tokenising helpers, with `FOLDER_NAME` for rituals.
8. **Hash input is defined.** SHA-256 of the canonical JSON of the parsed entry plus a schema version, not raw bytes, so a plugin upgrade that changes parsing re-proposes rather than silently re-trusting.
9. **Id collisions, all shapes.** Same id in two remit repos; file vs personal ritual; file vs stored repo entry under any remit key: all reject every colliding source with a row naming each. File entries never enter `loaded["repos"]`, so `retire-ritual` cannot copy them into the machine store.
10. **A file ritual can be declined or retired.** A `declined` adoption record by hash (and `retired`) takes it out of force; a changed file proposes again.
11. **Age of the ref = age of the clone's last fetch (`FETCH_HEAD` modification time),** not the commit date, which can be forged and says nothing about freshness. The row also shows the commit sha.
12. **Cost.** Files load inside `resolve`, are cached for the sweep, and every git call has a timeout; a slow or broken repo shows as a notice and never blocks a sweep.
13. **Wording.** The ritual is `proposed`, per programme, until Shawn adopts it; "in force for every programme" is true only after adoption in each.
