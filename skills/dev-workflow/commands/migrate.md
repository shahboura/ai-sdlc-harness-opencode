# Migrate v1.x Workspace to v2.0 Layout

> Canonical spec: [README.md#migrating-from-v1x](../../../README.md#migrating-from-v1x)
> Authoritative references: [workflow-paths](../context/workflow-paths.md), [timestamp](../context/timestamp.md)

<!-- Created by: dev-workflow-plan.md [v2.0 release]
     Reason: One-time migration utility — moves v1.x split layout
     `ai/plans/<id>.md` + `ai/tasks/<id>.md` into the v2.0 per-workflow
     layout `ai/<YYYY-MM-DD>-<work-item-id>/{plan,tracker}.md`.
     CC conventions applied: CC-07.3, CC-05.7, CC-05.7.1, CC-04.3. -->

**Phase**: Utility (one-time, idempotent — safe to re-run).
**Actor**: Orchestrator only (no agents spawned). Human confirms each move via a per-story summary before any file mutates on disk.

## When to run this

You must run `/dev-workflow migrate` when:

1. You're upgrading from harness v1.x (any 1.y.z release) to v2.0.
2. A `/dev-workflow` invocation refused to start with the message `❌ v1.x layout detected — run /dev-workflow migrate before proceeding.` (the **defensive check** in `SKILL.md` fires this).

Symptoms of a v1.x workspace:
- `ai/plans/` directory exists and contains `.md` files
- `ai/tasks/` directory exists and contains `.md` files
- No `ai/<YYYY-MM-DD>-<work-item-id>/` per-workflow directories yet

## Prerequisites

- Bootstrap is complete (`.claude/context/state.md` declares `Bootstrap completed: …`). Migration does not run on un-bootstrapped workspaces — run `/init-workspace` first.
- The active git branches (if any) for in-flight stories are intact. Migration only touches files under `ai/`; it never touches branches, worktrees, or commits.

## What gets migrated

The v1.x → v2.0 jump introduces three classes of change. The migrate command handles all three in a single pass:

1. **Workflow artifacts** — Stories under `ai/plans/<id>.md` + `ai/tasks/<id>.md` move to `ai/<YYYY-MM-DD>-<work-item-id>/{plan,tracker}.md` (CC-05.7).
2. **Plugin-shared agent references** — The plugin's `agents/shared/*.md` files (status-schema, tracker-field-schema, tracker-transition-rules, engineering-principles, diagram-styling) get mirrored to `.claude/context/agents-shared/` so subagent `Read` calls resolve. Same job as `/init-workspace --refresh-shared`.
3. **New + updated context files** — v2.0 introduces `naming-config.md` (M-15) and `state.md` (M-02). The migrate command provisions both with safe defaults (matching v1.x literal patterns) so the workspace passes the v2.0 startup gates.

## Steps

### S1 — Discover legacy artifacts

```
ls -1 ai/plans/*.md 2>/dev/null
ls -1 ai/tasks/*.md 2>/dev/null
```

Both directories are scanned. A story may appear in one, the other, or both:

- **plan + tracker pair** — typical case (Phase 2 ran).
- **plan only** — story is mid-Phase-1 / Phase-2 (no tracker yet).
- **tracker only** — defensive; suggests a corrupt v1.x state. Migrate but warn.

Build an in-memory mapping `{story_id: {plan_path, tracker_path}}` keyed by filename stem (filenames are the work-item IDs in v1.x).

### S2 — Determine the canonical workflow date per story

For each `story_id`:

1. Open `tracker_path` (if present) and grep for `Plan approved:` or any `YYYY-MM-DD` line near the top. Use that date.
2. Else fall back to `plan_path`'s mtime → `date '+%Y-%m-%d' -r <plan_path>`.
3. Else (neither exists) skip the story and surface to the human.

Apply CC-05.7.1 work-item-ID normalisation: replace `/`, `:`, and spaces with `-`. Example: `PROJ/123` → `PROJ-123`.

Result: `target_dir = ai/<YYYY-MM-DD>-<safe-id>/`.

### S3 — Detect target collisions

For each `target_dir`:

```
test -e <target_dir>
```

If the directory already exists, it's either:
- A v2.0 directory for the same story (re-run scenario — idempotent, skip).
- A different story that hit the same date+id (very unlikely with normalised IDs but possible). Surface the conflict.

Build a `collisions[]` list of conflicting stories. Halt before any disk write if `collisions[]` is non-empty — the human must resolve manually.

### S4 — Present the plan to the human

Print a table:

```
| # | Story ID | Source files                              | → Target dir                     |
|---|----------|-------------------------------------------|----------------------------------|
| 1 | PROJ-123 | ai/plans/PROJ-123.md + ai/tasks/PROJ-123.md| ai/2026-05-18-PROJ-123/         |
| 2 | PROJ-124 | ai/plans/PROJ-124.md                       | ai/2026-04-30-PROJ-124/ (plan only) |
```

Then prompt:

```
Migrate <N> story directory(ies)? [y/N]
```

**Default is NO.** Anything other than `y` / `yes` (case-insensitive) cancels — nothing is moved.

### S5 — Per-story migration (atomic per story)

For each row, in order:

1. `mkdir -p <target_dir>`
2. If `plan_path` exists:
   - `mv <plan_path> <target_dir>/plan.md`
3. If `tracker_path` exists:
   - Read the tracker header. If `Story-State: Archived` is present, target filename is `tracker.archived.md`; else `tracker.md`.
   - `mv <tracker_path> <target_dir>/<tracker-filename>`
4. Stamp a migration footer in the tracker (or plan if no tracker) so the audit trail survives:

```
> Migrated from v1.x layout on <YYYY-MM-DD HH:MM UTC>
```

5. Verify post-conditions: `target_dir` exists and contains at least one of `plan.md` / `tracker.md` / `tracker.archived.md`.

6. **Cross-repo contracts extraction (in-flight stories only).** If the plan contains a `### 2b. Cross-Repo Contracts` section (or `## Cross-Repo Contracts`) AND the tracker's Story-State is NOT `Archived` / `Done` (i.e. work is still in flight), extract the contracts to a dedicated `contracts.md` per the new layout in [`workflow-paths`](../context/workflow-paths.md). Steps:

   a. Read `<target_dir>/plan.md`. Find the section heading `### 2b. Cross-Repo Contracts` (legacy plan-generator output) or `## Cross-Repo Contracts` (alternative heading style). If neither is present → no contracts; skip this sub-step.

   b. Slice from the heading to the next sibling heading (next `###`/`##` at the same level). The slice is the inline contract body.

   c. Write `<target_dir>/contracts.md` with the canonical contracts.md header (`# Cross-Repo Contracts — <story-id>` + provenance line) followed by the sliced body, reformatting `C<n> — <type>` lines as `## C<n> — <type>` section headings if they aren't already. Preserve `Producer:` / `Consumer:` / `Definition:` field formats verbatim.

   d. Replace the original section in `plan.md` with a one-line stub:
      ```markdown
      ## Cross-Repo Contracts
      > Moved to `contracts.md` during v1.x → v2.0 migration on <YYYY-MM-DD>.
      ```

   e. For **closed stories** (Story-State `Archived` / `Done` / `Aborted`), do NOT extract — they're frozen audit artifacts; the inline section in their plan.md stays as-is. The reviewer / developer never re-reads a closed story's contracts.

Errors mid-migration: stop, do not roll back already-migrated stories (each story is atomic on its own). Surface the failure with the specific story ID.

### S6 — Sweep empty source directories

After all stories are migrated:

```
rmdir ai/plans/ 2>/dev/null
rmdir ai/tasks/ 2>/dev/null
```

`rmdir` only succeeds on empty directories — defensive against accidental data loss if some other artifact lives in either folder. If the `rmdir` fails because the directory is non-empty (e.g. a `.gitkeep` or stray file), leave it and surface the residual contents to the human.

### S7 — Mirror plugin shared files (same as `/init-workspace --refresh-shared`)

The v2.0 agents reference shared schema files via workspace-relative paths (`.claude/context/agents-shared/<name>.md`). v1.x workspaces don't have this mirror because the agent-runtime path resolution fix landed post-1.7.2. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/refresh-shared.sh" "$PWD"
```

If `CLAUDE_PLUGIN_ROOT` isn't set (the command was invoked from a context where the env var isn't propagated), fall back to the manual discovery the script does internally — the latest cached plugin install under `~/.claude/plugins/cache/ai-sdlc-harness/ai-sdlc-harness/<version>/`. The script copies every `.md` from `agents/shared/` into `.claude/context/agents-shared/`. Idempotent — overwrites are intentional so plugin updates propagate.

Exit codes from `refresh-shared.sh`:
- `0` — files copied or already current
- `1` — plugin install path could not be discovered (warn the user; the migration is still usable, but per-agent `Read` calls to the shared schemas may surface as "not found" until they install/update the plugin)
- `2` — `.claude/context/` missing (should not happen if S0 prerequisites passed)

### S8 — Provision new context files (v2.0 introduced)

v2.0 introduces two workspace context files that v1.x setups don't have. Provision them only if absent — never overwrite an existing file.

**`.claude/context/naming-config.md`** — declares branch / commit / PR-title / tag templates (CC-01.8). The migrate command writes defaults that **match the v1.x literal patterns** so existing branches and commits stay valid:

```bash
test -f .claude/context/naming-config.md || cat > .claude/context/naming-config.md <<'EOF'
# Naming Config

> Owner: workspace
> Version: 1.0 (migrated from v1.x defaults)

<!-- Provisioned by /dev-workflow migrate on <YYYY-MM-DD HH:MM UTC>.
     Templates below match the v1.x hardcoded patterns so existing
     branches / commits remain valid. Re-run /init-workspace
     --keep-legacy to re-propose templates from the current schema. -->

branch_format: ${team}/feature/${story_id}-${slug}
commit_format: #${story_id} #${task_id}: ${slug}
pr_title_format: [${repo}] ${slug}
tag_format: v${story_id}
EOF
```

**`.claude/context/state.md`** — workspace bootstrap marker (CC-05.4). The v1.x workspace IS bootstrapped (you've been running stories), just without the v2.0 sentinel. Stamp it now:

```bash
test -f .claude/context/state.md || cat > .claude/context/state.md <<EOF
# Workspace State

> Owner: workspace
> Version: 1.0

Bootstrap completed: $(date -u '+%Y-%m-%d %H:%M UTC')
Workflow active:
Last metric stamp:

<!-- Provisioned by /dev-workflow migrate — pre-existing v1.x
     workspace was bootstrapped in-place; the timestamp records the
     migration moment, not the original bootstrap. -->
EOF
```

### S9 — Update existing context files if needed

For each of the five v1.x context files that should still exist (`provider-config.md`, `repos-metadata.md`, `repos-paths.md`, `language-config.md`, `conventions.md`):

1. Verify the file exists. If missing → surface to the human; this is an incomplete v1.x bootstrap and `/init-workspace` should be re-run instead.
2. Check the header for `> Version:` and `> Owner:` lines (CC-04.4/.6). If missing → backfill in place:

```bash
# Detect a v1.x file without the Owner/Version pair
if ! grep -qE '^> Owner:' .claude/context/<file>.md; then
    # Insert the two-line header after the first H1
    python3 - <<'PY'
import re, pathlib
p = pathlib.Path('.claude/context/<file>.md')
text = p.read_text(encoding='utf-8')
if not re.search(r'^>\s*Owner:', text, re.MULTILINE):
    new = re.sub(
        r'^(#\s.+\n)',
        r'\1\n> Owner: workspace\n> Version: 1.0\n',
        text,
        count=1,
    )
    p.write_text(new, encoding='utf-8')
PY
fi
```

No other in-place mutation. The user's existing settings (repo paths, conventions, language toolchains, provider config) are preserved verbatim.

### S10 — Confirm + summarise

Print:

```
✅ Migrated <N> story directory(ies) from v1.x to v2.0 layout
   <N> plans moved
   <M> trackers moved
   <K> directories created under ai/

✅ Plugin shared files mirrored to .claude/context/agents-shared/
   (status-schema, tracker-field-schema, tracker-transition-rules,
    engineering-principles, diagram-styling)

✅ New context files provisioned
   .claude/context/naming-config.md (v1.x-compatible defaults)
   .claude/context/state.md         (bootstrap marker)

✅ Existing context files backfilled with Owner/Version headers
   (CC-04.4/.6) where missing

Next: run /dev-workflow <work-item-id> as usual. The legacy
ai/plans/ + ai/tasks/ folders have been removed (or are empty).
```

## Exit Criteria

- Every legacy `ai/plans/<id>.md` and `ai/tasks/<id>.md` has been moved into a `ai/<YYYY-MM-DD>-<safe-id>/` directory.
- `ai/plans/` and `ai/tasks/` are either absent OR present-but-empty.
- A migration footer is stamped in every migrated tracker (or plan when no tracker existed).
- No collisions remain unresolved.
- `.claude/context/agents-shared/` exists and contains the plugin's five shared schema files.
- `.claude/context/naming-config.md` exists (provisioned with v1.x-compatible defaults if absent before migration).
- `.claude/context/state.md` exists with a `Bootstrap completed:` timestamp.
- The five v1.x context files (`provider-config.md`, `repos-metadata.md`, `repos-paths.md`, `language-config.md`, `conventions.md`) all carry `> Owner:` + `> Version:` headers.

## Failure Modes

| Failure | Detection | Response |
|---|---|---|
| Workspace not bootstrapped (no `provider-config.md`) | `.claude/context/provider-config.md` absent | Refuse with `❌ Workspace not bootstrapped — run /init-workspace before /dev-workflow migrate.` (Note: a v1.x workspace lacks `state.md`; that file gets provisioned by S8 here. The migrate command's bootstrap check looks at `provider-config.md` instead — that's the v1.x bootstrap artifact.) |
| Both source directories empty / absent AND new context files already present | `ai/plans/` and `ai/tasks/` are missing or empty; `state.md` + `naming-config.md` exist | Already-migrated workspace — print `Workspace already on v2.0 layout — nothing to migrate.` and exit 0 |
| Source directories empty / absent but new context files missing | layout already migrated but `state.md` / `naming-config.md` / `agents-shared/` missing | Proceed with S7+S8+S9 only — print `Layout already v2.0; provisioning new v2.0 context files now.` |
| `refresh-shared.sh` fails (plugin install not discoverable) | exit code 1 from S7 invocation | Warn — do not block. Migration completes; agent `Read` calls to shared schemas may surface as "not found" until the plugin is installed or refreshed. |
| Mid-Phase-2 plan with no tracker | Only `ai/plans/<id>.md` exists | Migrate the plan-only; warn that the story will need a fresh tracker via the appropriate phase command |
| Target dir already exists | `target_dir` exists with conflicting contents | Halt before any write; require human to inspect — never overwrite |
| Date undeterminable | No tracker, no mtime accessible | Surface the story to the human; skip migration for that story until they specify the date |
| Write permission denied | `mv` or `mkdir` fails | Surface immediately; remaining stories are untouched |

## Idempotency

The migration is safe to re-run. On a second invocation:
- S1 finds an empty `ai/plans/` + `ai/tasks/` → S6/S7 short-circuit with `Workspace already on v2.0 layout`.
- S1 finds residual files → S3 detects the existing target dirs → skips already-migrated stories.

## Worked Example

Starting state:

```
ai/
├── plans/
│   ├── PROJ-123.md
│   └── PROJ-124.md
└── tasks/
    └── PROJ-123.md
```

After `/dev-workflow migrate`:

```
ai/
├── 2026-04-30-PROJ-124/
│   └── plan.md
└── 2026-05-18-PROJ-123/
    ├── plan.md
    └── tracker.md     (with migration footer)
```

The `ai/plans/` and `ai/tasks/` directories are removed once empty.

## Next Phase

None — this is a utility command. Continue with the normal workflow via `/dev-workflow <work-item-id>`.
