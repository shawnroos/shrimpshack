---
authors: Claude
type: security-audit
project: claude-modes
topics: [terminal-escape, sanitization, hostile-repo, R30]
---

# Terminal-Escape Source × Sink Audit (V2.0)

## Why this exists

A hostile repo a victim clones can plant attacker-controlled bytes in a
committed `.mode` body, `_repo.yaml` plugin keys, a branch name, a filename,
or a clone-directory path. Printed **raw** to a human terminal, ESC / OSC /
CSI sequences (e.g. an OSC-2 title rewrite) and Unicode Cf bidi overrides
(U+202E) can rewrite or reverse what the user sees — spoofing a consent
prompt or the statusline.

This class recurred across review rounds 2, 3, and 4 — each round's
narrow grep found one new sibling sink. This doc is the **complete** source ×
sink matrix (built by reading every `lib/*.sh|py` and `scripts/*.sh|py`, not
greping), so the class is closed once and the lint guard
(`tests/integration/terminal-sink-lint.test.sh`) keeps it closed.

## Defense primitives

- **`claude_modes::read_validated_mode_body`** (lib/active-mode.sh) — for
  charset-constrainable values (mode names). A validated mode name
  (`[A-Za-z0-9_-]+`, ≤64, reserved-token-rejected) cannot contain a control
  or escape byte **by construction**. Prefer this over sanitization.
- **`claude_modes::slugify_branch`** (lib/validate-mode-name.sh) — branch
  names normalized to the safe slug charset.
- **`claude_modes::sanitize_for_display`** (lib/sanitize.sh) — for free-form
  values (filenames, clone paths, raw branch names, plugin keys) that
  legitimately contain arbitrary chars. Strips Unicode Cc + Cf. Does NOT do
  NFKC / homoglyph defense (deferred — V2.0 stops obvious injection, not all
  visually-confusable Unicode).

## Source × Sink matrix

Reachability legend: **repo** = hostile cloned repo; **path** = crafted clone
dir name; **user** = user types it at their own prompt (self-shoot, not a
security boundary); **agent** = reaches the agent's systemMessage (different
threat class — prompt injection, not terminal escape).

| Source (attacker-controlled) | Sink | Reachability | Defense | Status |
|---|---|---|---|---|
| `.mode` body → mode_name | statusline `[mode] cwd` title + `🔧 mode` segment | repo | read_validated_mode_body | VALIDATED |
| `.mode` body → active_mode | `/mode:status` "Active mode:" | repo | status_validate_mode_body | VALIDATED |
| `_repo.yaml` plugin keys | trust-gate consent listing | repo | sanitize_for_display | SANITIZED (L2-a) |
| `_repo.yaml` plugin keys | `/mode:status` plugin catalog | repo | inline Cc+Cf strip in py | SANITIZED (L4-b) |
| `_repo.yaml` plugin keys | cascade-engine.py R22 SecurityError stderr | repo | lib/sanitize.py per-key | SANITIZED (L7-a) — round-7: cascade-engine.py had NO strip; the audit doc FALSELY claimed it did, hiding this for 7 rounds. Now sanitized at SecurityError construction. |
| `_repo.yaml` path / clone path / YAML-error snippet | cascade-engine.py R30 + _safe_load + settings/sidecar stderr | repo / path | lib/sanitize.py | SANITIZED (L7-a) — PyYAML's get_snippet() embeds raw source; sanitized via str(e) wrap at every stderr site. |
| untrusted manifest `entry` + realpath | symlink-validate.py R7-rejection stderr | repo | lib/sanitize.py | SANITIZED (L7-a) |
| untrusted manifest `entry` | symlink-rebuild.sh refusal stderr | repo | sanitize_for_display (bash) | SANITIZED (L7-a) — lint's ATTACKER_VARS now lists `entry`. |
| `_repo.yaml` path | trust-gate "found at:" | repo | sanitize_for_display | SANITIZED (L2-a) |
| repo_root (clone path) | trust-gate [y/N] prompt | path | sanitize_for_display | SANITIZED (L2-a) |
| repo_root (clone path) | `/mode:status` "Current repo:" | path | sanitize_for_display | SANITIZED (L4-b) |
| repo_root-DERIVED paths (tier_4_path / settings_local / sidecar = `${repo_root}/...`) | `/mode:status` tier-4 + Paths section | path | `_d` display variants via sanitize_for_display (round-5: repo_root is mixed FS+display, can't sanitize at source → sanitized display variants) | SANITIZED (L5-a) |
| raw branch name | `/mode:status` "Current branch:" | repo | sanitize_for_display | SANITIZED (L4-b) |
| cwd basename (clone dir) | statusline OSC-2 title (`__cm_title`) | path | sanitize_for_display (chokepoint) | SANITIZED (L4-b) |
| adopted-file basename | PostToolUse `/dev/tty` consent prompt | repo | sanitize_for_display | SANITIZED (L3-a) |
| adopted-file basename / path | adopt-file.sh stderr error messages | user | none | DEFERRED (P3) — `$arg`/`$file_path` are the USER's own typed `/mode:adopt` argument; self-shoot surface, not hostile-repo. (`arg` is deliberately NOT in ATTACKER_VARS: it's a generic name reused across files with self-shoot threat models — globally allowlisting it would force re-litigating this and several sibling deferred sinks. mode-add.sh's parse_candidate diagnostic instead uses a FIXED string so it carries no raw-var sink.) |
| repo path from registry | unmodes.sh `_log` skip/preserve messages | repo (via clone-dir name) | none | DEFERRED (P3) — hostile-repo-reachable (the clone-dir name carries the bytes), BUT the attack chain requires three deliberate user steps with the dir name visible throughout: clone a hostile-named dir → run `/mode:set` in it (consent) → later run `/mode:uninstall`. The three-step user-intent attenuates the vector substantially. Revisit if uninstall ever runs unattended. |
| `_repo.yaml` path (`$candidate`/`$repo_yaml`) + ancestor-symlink realpath (`$__real_cand`) | cascade-engine.sh R30 rejection + "could not hash" stderr (lines 213/360/387) | repo / path | sanitize_for_display | SANITIZED (L6-a) — round-6: these rejection branches fire on the FIRST `/mode:set` in a hostile clone, BEFORE the consent gate, printing the attacker clone path / symlink-target realpath raw. Missed for rounds because cascade-engine.sh was not in the hand-maintained lint file list (now computed via find). |
| sentinel body (`$prev`) | set-mode.sh resume/replace stderr | impossible | none | DEFERRED — sentinel is written by set-mode itself with a validated name; an attacker writing it already owns `~/.claude/`. |
| untagged-file basename/path | `.untagged-files` marker → inject-prose systemMessage | agent | json.dumps (wire-encoded) | OUT OF SCOPE — agent channel, not a terminal renderer. Prompt-injection class, handled separately. |
| `.last-active-mode` body | (all read sites) | repo | read_validated_mode_body | VALIDATED |
| sidecar `source_modes` | `/mode:status` tier-4 [contributed] | repo (plugin-written) | membership check only (not displayed raw) | SAFE |
| cached SKILL.md `name:` field + plugin dir name (`plugin_d`/`skill_d`) | resolve-catalog-candidate.sh `kind=skill` TSV record (caller prints to disambiguation UI) | repo (hostile plugin in `~/.claude/plugins/cache`) | sanitize_for_display (bash) at the format site | SANITIZED (U2) — values come from a glob over the plugin cache; a hostile cached SKILL.md could plant ESC/OSC/Cf bytes in its `name:` value or its containing dir name. Sanitized into `_d` locals BEFORE the printf. |
| skill's parent-plugin FQN from installed_plugins.json (`parent_d`) | resolve-catalog-candidate.sh `kind=skill … parent_plugin=` TSV field | repo (registry is user-writable JSON) | sanitize_for_display (bash) at the format site | SANITIZED (Batch-4) — the skill row's parent_plugin field cross-references the user-writable registry for the skill's installed parent. Raw `parent_raw` reaches printf only via the sanitized `parent_d`; ATTACKER_VARS lists `parent_raw`. |
| user's typed query / colon-FQN | mode-add.sh parse_candidate diagnostic stderr | user / repo (FQN-shortcut path's arg could echo a hostile cached SKILL.md name) | FIXED string (no interpolation) | SAFE (Batch-4) — the parse_candidate diagnostic is a FIXED string that does NOT interpolate `$arg`; ALL mode-add.sh error branches are fixed strings, so this lib has no attacker-class terminal sink (matches its SECURITY header). Chosen over the sanitize+allowlist option because `arg` is a generic name with documented-deferred sinks in adopt-file.sh/unmodes.sh — a global ATTACKER_VARS entry would cascade into those. |
| installed_plugins.json plugin key (`key_d`) | resolve-catalog-candidate.sh `kind=plugin source=installed` TSV record | repo (registry is user-writable JSON) | sanitize_for_display (bash) at the format site | SANITIZED (U2) |
| marketplace.json plugin `name` + top-level `name` → FQN (`fqn_d`) | resolve-catalog-candidate.sh `kind=plugin source=marketplace` TSV record | repo (marketplace.json is user-writable JSON) | sanitize_for_display (bash) at the format site | SANITIZED (U2) |

## Lint enforcement

`tests/integration/terminal-sink-lint.test.sh` greps bash files for `printf`/
`echo`/`__cm_title`/`> /dev/tty` lines that interpolate an attacker-class
variable that is neither validated nor sanitized, and fails CI if it finds one.
The allowlist of attacker-class variable NAMES (`ATTACKER_VARS`) mirrors this
table's source column. Adding a new sink requires routing through a defense
primitive AND updating this doc.

**Scope is computed, not hand-maintained.** The lint scans every `*.sh` under
`lib/` and `scripts/` via `find`, minus a small annotated `LINT_EXCLUDE`. This
is the round-6 structural fix: cascade-engine.sh's R30 rejection prints leaked
the attacker clone path for several rounds *because cascade-engine.sh was not in
the old hand-listed `LINT_FILES`*. A find-based scope makes a new `.sh` file
in-scope by default — the failure mode moves from "forgot to add" (silent gap)
to "forgot to exclude" (loud CI red). Each `LINT_EXCLUDE` entry carries a
one-line reason; an unannotated exclusion would re-open the silent-gap hole.

**Python sinks have their OWN lint** (round-7 / L7). The bash lint's
sink/protection detection is bash-only (`printf`/`echo`/`_log`/`_err`/the bash
`sanitize_for_display`). It is structurally Python-blind — and for 7 rounds this
doc FALSELY claimed the Python layer defended via "an inline Cc+Cf strip." It did
not: there was no `unicodedata` anywhere in `lib/*.py`, and cascade-engine.py
wrote attacker-controlled `_repo.yaml` keys / clone-paths / YAML-error snippets
RAW to stderr (round-7 P1, security + kieran-python + adversarial).

L7 closed the language boundary:
- `lib/sanitize.py` is the Python twin of `lib/sanitize.sh` — one
  `sanitize_for_display(s)` (strip Cc+Cf), imported by cascade-engine.py and
  symlink-validate.py, applied at every attacker-controlled stderr interpolation
  (at SecurityError *construction* so the exception can't carry raw bytes).
- `tests/integration/terminal-sink-lint-py.test.sh` is the Python-side lint:
  computed scope (`find lib -name '*.py'` minus an annotated exclusion list),
  detects `sys.stderr.write` / `print(...,file=sys.stderr)` f-string fields
  interpolating an attacker-class name without `sanitize_for_display`, and ships
  with a deliberate-fail assertion (a planted raw sink it MUST flag) so a broken
  detector can't report vacuous green.
- `lib/drift-diff.py` is excluded (NOT WIRED IN for V2.0 — no callers); apply
  the strip at V2.1 wiring time. `lib/reconcile-symlinks.py` is excluded (logs
  only to files, never a terminal).

**round-8 (U2) — resolve-catalog-candidate.sh + post-write-reload.sh.** U2's
catalog resolver and U6's reload helper introduced new attacker-controllable
sinks (see the SANITIZED (U2) rows above). The bash lint's `ATTACKER_VARS`
allowlist now lists every RAW (un-`_d`) name they carry so the sanitize
invariant is mechanically enforced, not convention:
- `plugin_raw` / `skill_raw` — hostile cached `SKILL.md` `name:` value + its
  containing plugin dir name (`~/.claude/plugins/cache`).
- `key_raw` — user-writable `installed_plugins.json` plugin key.
- `fqn_raw` — user-writable `marketplace.json` plugin/top-level `name` → FQN.
- `delta_summary` — post-write-reload's raw delta string (may embed plugin
  keys).
All currently reach `printf` only via their `_d` display variants; the lint now
turns any future raw-var print into a red build. `mode_name` is deliberately NOT
listed — post-write-reload.sh interpolates only `mode_name_d` into every printf
(raw `mode_name` reaches no terminal sink), so it stays validated-by-construction
like `active_mode` / `branch_slug`.

**round-8 (U2) — Python transport-boundary strip.** resolve-catalog-candidate.sh's
three Python helpers emit `\n`-separated, `\t`-delimited records that bash then
splits BEFORE per-field sanitize. A hostile cache plugin-dir name / registry key
/ marketplace name carrying an embedded newline would forge phantom TSV rows
(one on-disk skill → N rows). Fixed at the transport boundary: each helper
applies an inline Cc+Cf strip (same contract as `lib/sanitize.py`) to every
component BEFORE the `sys.stdout.write(... + '\t' + ... + '\n')`, so an injected
`\n`/`\t` can never reach the record/field separator. The bash-side
`sanitize_for_display` stays as display defense-in-depth.

Adding a new sink in EITHER language requires routing through that language's
`sanitize_for_display` AND updating this doc. Both lints fail CI otherwise.
