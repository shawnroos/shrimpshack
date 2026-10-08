# Programme protocol format

The protocol is the set of rules that map a kind of change to its required deliverables and evidence bar. A programme run uses it to decide what "done" means for each item. `lib/programme_protocol.py` loads and checks it. This document is the format that the loader enforces.

## 1. Layers

The loader reads three JSON layers in this order. A later layer is more specific.

| Layer | Path | Notes |
| --- | --- | --- |
| plugin | `plugins/auto/protocol/defaults.json` | Ships with the plugin. Its entries need no adoption record. |
| personal | `~/.claude/shared/auto/protocol.json` | Syncthing syncs it between machines. The env var `CLAUDE_AUTO_PERSONAL_PROTOCOL` replaces the path (tests use it). |
| project | `<repo>/.claude/auto-protocol.json` | Read from the default branch, never from the working tree. |

Project layer rules:

- The loader resolves the default branch with `git symbolic-ref refs/remotes/origin/HEAD`, then reads `<that ref>:.claude/auto-protocol.json` with `git cat-file`. A worker's uncommitted or unpushed edit has no effect.
- The loader never fetches. The caller keeps the remote ref current.
- If the ref does not resolve, the project layer does not load, and the loader reports `no_default_branch`.
- If git fails or times out while it reads the ref, the layer does not load, and the loader reports `malformed_layer`.
- If the file is not on the default branch, the layer is missing. This is not an error.

A missing personal file is not an error. A personal path that cannot be read (a folder, no permission, not UTF-8) rejects that layer as `malformed_layer`. The loader ignores every file whose name contains `.sync-conflict-` beside the personal file, and reports each one in `notices` with kind `sync_conflict`.

## 2. Layer file

```json
{
  "protocol_format": 1,
  "rules": [ /* rule objects, section 3 */ ],
  "autonomy": { "<action>": { "level": "act", "adoption": { } } },
  "checks": { /* section 6 */ }
}
```

- All keys are optional. Any other top-level key rejects the whole layer (`unknown_key`).
- A layer that is not a JSON object, or that has a key of the wrong type, is rejected whole (`malformed_layer`).
- A `protocol_format` above 1 rejects the whole layer (`newer_format`).
- A rejected layer does not stop the other layers from loading.

## 3. Rule

Every rule has all nine fields. A missing field rejects the rule (`missing_field`, with the field name as detail). Any other key rejects the rule (`unknown_key`). The only optional key is `adoption`.

| Field | Type | Check |
| --- | --- | --- |
| `id` | string | `^[a-z][a-z0-9-]*$`. Unique in its layer; a repeat rejects every rule with that id in that layer (`duplicate_id`). |
| `applies_when` | object | Exactly `{"change_kinds": [<kind>, ...]}`, not empty. Each kind matches `^[a-z][a-z0-9_]*$`. |
| `requires` | list | Not empty, no repeats. Each entry is a deliverable or an outcome (below), else `unknown_deliverable`. |
| `evidence_bar` | object | One non-empty string for each entry in `requires`, and no other keys. |
| `caveat` | string | Can be empty. |
| `autonomy` | string | `act`, `act_and_tell`, `propose` or `never`, else `unknown_autonomy`. |
| `added_by` | string | Not empty. |
| `added_at` | string | UTC time as `YYYY-MM-DDTHH:MM:SSZ`. |
| `why` | string | Not empty. |

Deliverables: `merged`, `flagged`, `verified`, `released`, `recorded`.

Outcomes: `handed` (the item goes to Shawn) and `debugged` (the PM debugged the blocker at runtime and recorded its trace or job id). An outcome is not a deliverable. The match result lists outcomes in `requires` only, never in `deliverables`.

Change kinds in the plugin layer: `flagged_code`, `fix_only`, `shared_package`, `evals_or_docs`, `product_question`, `shared_blocker`. A more specific layer can name a new kind.

## 4. Adoption record

Every personal or project rule, autonomy entry and check needs an `adoption` object. If it is missing, the entry does not load (`not_adopted`, or `check_not_adopted` for a check).

```json
{
  "machine": "studio",
  "run_id": "prog-20261006-101010-abc123",
  "prompt_id": "p3",
  "quote": "yes, adopt it",
  "prompt_hash": "<text_hash of the prompt in the run journal>",
  "hash": "sha256:<content hash>",
  "widening": true
}
```

- The six fields other than `widening` are required strings. Only `quote` can be empty. `widening` is optional and boolean. Any other problem gives `adoption_malformed`.
- `hash` is `content_hash(entry)`: the SHA-256 of the entry without its `adoption` key, as JSON with sorted keys and no spaces. An edit after adoption gives `adoption_unverified`.
- `machine` is compared with `machine_name()`. The env var `CLAUDE_AUTO_MACHINE` replaces the host name (tests use it).
- `prompt_hash` is the prompt's `text_hash`: `"sha256:"` followed by the hex SHA-256 of the prompt's `payload.text` in the run journal, encoded as UTF-8. That text is already redacted when the journal stores it, so the hash is over the redacted text. `programme.text_hash(text)` computes it, and the adopt verbs write `prompt_hash` with it.
- When `machine` is this machine, the loader calls `prompt_lookup(run_id, prompt_id)`. The result must be an object with `origin` equal to `typed`, `text_hash` equal to `prompt_hash`, and `approved` containing `approval_key(target, hash)`. A missing prompt, another origin, a different hash, no matching approval (detail `no approval`), no lookup, or a lookup that raises gives `adoption_unverified`.
- `target` names the place the entry loads into: `rule:<id>`, `autonomy:<action>`, or `check:<repo>:<check>` (for a project-layer check, `<repo>` is the repo key the loader was given). `target_of(section, name, repo)` builds it, and `approval_key(target, hash)` is `<target>@<hash>`. The target matters because an autonomy entry or a check hashes only its body: `{"level": "act"}` has the same hash for every action, so an approval for one action must not load the same body under another.
- `approved` lists `approval_key(payload.target, payload.hash)` for every approval record in the cited run's journal that cites `prompt_id`. An approval record is a `rule_adopted` entry whose `cites[0]` and `payload.prompt_id` both equal `prompt_id`. A hash beside the entry is not proof by itself: anyone can recompute it after changing the entry, so the loader needs the journal record that the approval wrote at that time.
- When `machine` is another machine, only a personal-layer rule or autonomy entry loads without a lookup, and `adopted_on` names that machine. Syncthing syncs the personal layer between Shawn's machines; nothing else carries an adoption from another machine. Such an entry is checked only by its own `hash`, which anyone who can write the synced file can recompute, so it may keep or narrow a level but never widen one: an entry from another machine whose adoption has `"widening": true`, or whose level is wider than the entry it replaces, gives `widening_not_adopted_here`. To widen on this machine, adopt the entry here. `programme.py status` and the rules in force show a loaded entry from another machine as `adopted on <machine>`. A project-layer rule or autonomy entry from another machine gives `not_adopted_here`, and a check from another machine does not load (section 6).
- Three verbs adopt into the personal layer, each with a typed `--prompt`:
  - `adopt-rule <rule-id>` adopts a proposed rule (`entry: "rule"`).
  - `adopt-autonomy <action> <level> [--widening]` sets one autonomy entry (`entry: "autonomy"`). A level wider than the plugin default needs `--widening`, which also writes `"widening": true`.
  - `adopt-check <repo> <check> <argv-json>` sets one command of a repo's checks block (`entry: "check"`). The checker uses a repo's commands only when both `verified.lookup` and `verified.deployed_sha` load, so adopt both.
- The cited prompt must name what it approves: for `adopt-rule`, the rule id; for `adopt-autonomy`, the action and the level; for `adopt-check`, the repo and the check key (for example `verified.lookup`). With `--widening`, the text must also contain `widen`, `widening` or `widened`. Each name must appear in the redacted text as whole words, case ignored: a run of words that, with `_` and `-` dropped, spells the name. So `merge_pr`, `merge-pr`, `merge pr` and `MergePR` all name `merge_pr`, while `AI-801` does not name `AI-80`, `1800` does not name `180`, `actually` does not name `act`, and `auto-merge-docs-only` does not name `auto-merge`. Levels are read longest first, so `act and tell` names `act_and_tell` and never `act`. An occurrence right after `not`, `never`, `no` or a `n't` word (`don't`, `do not widen`, `never act`) does not count. A prompt that does not name them is refused, and the refusal lists the words it lacks. The check stops a prompt about something else from being cited; it does not prove intent, and other negations (`without widening`, `rather than act`) are not detected.
- Each verb writes the entry and its adoption record in one atomic rename, then journals `rule_adopted` with `entry`, `target`, `hash`, `prompt_id`, `quote` and `cites: [prompt_id]`. Until that journal entry exists, the entry does not load. A project-layer entry is committed by hand, so on this machine it loads only when a `rule_adopted` entry for its target and hash is journaled.

## 5. Merge and autonomy width

Layers merge in order. A rule with the same `id` as a loaded rule replaces it. An autonomy entry with the same action replaces it.

Width order, widest first: `act`, `act_and_tell`, `propose`, `never`. A replacement may keep or narrow the level with a plain adoption. A replacement that widens the level loads only when its adoption record has `"widening": true`, else `widening_unmarked`. A new id or a new action is an addition, not a widening.

The plugin layer maps these actions:

| Level | Actions |
| --- | --- |
| `act` | `merge_at_gate`, `prod_off_flag`, `file_issue` |
| `act_and_tell` | `eval_backed_prerelease`, `worker_session_approval` |
| `propose` | `prod_deploy`, `full_release`, `eval_waiver`, `spend_over_cap`, `product_call` |
| `never` | `fix_other_team_code`, `merge_around_gate` |

The programme's autonomy term overrides these levels. They are defaults only.

## 6. Checks

A check is an argv template that an evidence checker runs. The only command keys are `verified.lookup` and `verified.deployed_sha`.

```json
"checks": {
  "acme/web": {
    "verified.lookup": { "argv": ["trace-cli", "show", "{id}"], "adoption": { } },
    "verified.deployed_sha": { "argv": ["deploy-cli", "sha", "{id}"], "adoption": { } }
  }
}
```

- In the plugin and personal layers, `checks` is keyed by repo. In the project layer, `checks` holds the command keys directly. Its repo is the `repo_key` that the caller gives, or the real path of the repo.
- `argv` is a non-empty list of non-empty strings. Placeholders are `{id}`, `{sha}` and `{repo}`.
- An unknown command key rejects the block for that repo (`unknown_check`). A bad `argv`, an unknown placeholder or an unknown entry key also rejects the block.
- A command loads only with an adoption record from this machine that passes section 4. An adoption from another machine gives `check_not_adopted_here`. This stops a worker from supplying the command that checks its own claim.
- A project command replaces a personal command with the same key for the same repo.

### 6.1 Output contract

The `verified` checker runs both commands for a deliverable whose `merged` entry is confirmed with a merge commit.

| Placeholder | Value |
| --- | --- |
| `{id}` | The deliverable's ref: the `--ref` given, else the newest claim's ref, else the stored ref, else the item's `waiting_on.trace_id` or `job_id`. |
| `{sha}` | The merge commit, from the `merged` entry's `fields.merge_commit`. |
| `{repo}` | The `checks` key that matched: `owner/name` from the merged PR ref when that key has both commands, else the clone's real path. |

- Each command runs with the clone as its working folder, an environment of only `PATH` and `HOME`, stdin from `/dev/null`, and the `CLAUDE_AUTO_CHECK_TIMEOUT_SECONDS` limit (default 30). Output past 1 MB is cut off and gives `unknown`.
- `verified.lookup` must exit 0 and print some text. The checker keeps that text, redacted and capped at 500 characters, as `fields.lookup`. It does not parse it.
- `verified.deployed_sha` must exit 0 and print a 40-character lowercase hex commit sha. The first such sha in its output is the build sha.
- A non-zero exit, a timeout, empty output, or no sha gives `unknown`, never `refuted`.
- The checker then runs `git -C <clone> merge-base --is-ancestor <merge commit> <build sha>`. Exit 0 confirms. Exit 1 refutes ("build X does not contain the merge commit Y"). Any other exit, for example a sha the clone does not have, gives `unknown`. The checker never fetches.

## 7. Proposed rules

A proposed rule lives in the programme record at `programme.proposed_rules`, never in a layer file. It uses the section 3 format with no `adoption` key. `validate_proposal(rule)` checks it. A proposed rule never changes a match result. `summary(protocol, record)` lists it with status `proposed`.

## 8. Loader interface

`load(repo_path=None, repo_key=None, prompt_lookup=None, plugin_path=None)` returns:

```json
{
  "rules":    { "<id>": { "<rule fields>": "...", "layer": "personal", "adopted_on": null, "adoption": {} } },
  "autonomy": { "<action>": { "level": "act", "layer": "plugin", "adopted_on": null } },
  "checks":   { "<repo>": { "verified.lookup": { "argv": [], "layer": "project" } } },
  "rejected": [ { "layer": "personal", "id": "docs-verified", "reason": "not_adopted", "detail": null } ],
  "notices":  [ { "layer": "personal", "kind": "sync_conflict", "path": "..." } ],
  "layers":   [ { "layer": "plugin", "source": "...", "status": "loaded" } ]
}
```

- `adopted_on` is null for the plugin layer and for an adoption from this machine.
- A rejection for a whole layer has `id` null. A rejection for one check has id `<repo>:<command key>`.
- `prompt_lookup(run_id, prompt_id)` returns `{"origin": ..., "text_hash": ..., "approved": ["<target>@<hash>", ...]}` or null. `programme.prompt_lookup` is the real supplier: it finds the prompt in the run journal, hashes its stored text, and collects the approval records as section 4 defines. The loader never loads the journal itself.

Rejection reasons: `malformed_layer`, `newer_format`, `no_default_branch`, `unknown_key`, `missing_field`, `bad_value`, `unknown_deliverable`, `unknown_autonomy`, `duplicate_id`, `not_adopted`, `not_adopted_here`, `adoption_malformed`, `adoption_unverified`, `widening_unmarked`, `widening_not_adopted_here`, `unknown_check`, `check_not_adopted`, `check_not_adopted_here`.

`match(protocol, change_kinds)` returns the rules whose `change_kinds` include any given kind:

```json
{ "matched_rule": ["flagged-code"], "requires": ["merged", "flagged", "verified", "recorded"],
  "deliverables": ["merged", "flagged", "verified", "recorded"], "autonomy": "act", "reason": null }
```

- `requires` is the union of the matched rules, in the fixed order of deliverables and then outcomes. `deliverables` is the same list without outcomes.
- `autonomy` is the narrowest level of the matched rules.
- With no match, `matched_rule` is null, both lists are empty, and `reason` is `no_matching_rule`. Such an item cannot reach "done" until a rule matches it.
