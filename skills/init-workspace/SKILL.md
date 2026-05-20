---
name: init-workspace
description: >
  One-time workspace setup. Generates local context files (.claude/context/, git-ignored)
  that all workflows depend on — repo metadata, coding conventions, local repo paths,
  language configuration (discovered, not hard-coded), and provider configuration.
  Supports ADO, Jira, GitLab, GitHub, Zoho, and local-markdown as work item providers,
  plus GitHub CLI (gh-cli) and GitLab CLI (glab-cli) as no-MCP git providers. Run once
  before using /dev-workflow or /story-workflow.
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Agent
argument-hint: "[--full | --refresh-conventions | --refresh-permissions | --refresh-shared | --keep-legacy]"
---

# /init-workspace — Workspace Setup

One-time workspace setup, or new-developer onboarding. Generates the context files that all other workflows depend on.

> **Hard constraint — human-only command.** `/init-workspace` requires interactive human confirmation during language discovery (Phase 3 negotiate). It MUST NEVER be invoked by a background agent. The orchestrator must never delegate this command to a sub-agent lane. If language configuration is missing when a workflow starts, ask the human to run `/init-workspace` directly.

## Usage

```
/init-workspace                         # First-time setup or onboarding
/init-workspace --full                  # Force full regeneration
/init-workspace --refresh-conventions   # Only regenerate conventions.md
/init-workspace --refresh-permissions   # Only re-propose Bash permissions (Step 3c)
/init-workspace --refresh-shared        # Only re-mirror plugin agents/shared/ files (Step 6c)
/init-workspace --keep-legacy           # In-place schema upgrade without re-running discovery
```

## Output Files

All generated files live at `.claude/context/`:

| File | Description |
|------|-------------|
| `provider-config.md` | Work item and git provider settings, tool mappings, field mappings |
| `repos-metadata.md` | Each repo's purpose, stack, domain, default branch |
| `repos-paths.md` | Maps repo names to local filesystem paths |
| `language-config.md` | Discovered per-repo language, toolchain, commands, regex patterns, permissions |
| `conventions.md` | Team coding patterns, language baselines, repo-specific patterns |
| `state.md` | Workspace lifecycle state (Bootstrap completed, Workflow active, Last metric stamp) — owner: P0 |

All files are local and git-ignored. Each developer generates their own set by running `/init-workspace`.

<!-- Changed by: dev-workflow-plan.md [M-02] [IMPL-02-01]
     Reason: Add state.md to the output file inventory per CC-01.4 / CC-04.4 / GAP-12.
     CC conventions applied: CC-01.4, CC-04.4. -->

### `naming-config.md` schema (CC-01.8 — IMPL-15-01)

`.claude/context/naming-config.md` holds the four required naming templates (`branch_format`, `commit_format`, `pr_title_format`, `tag_format`). Per CC-01.8 every consumer reads from here — never hardcodes.

> Schema and placeholder DSL: [naming-templates](../dev-workflow/context/naming-templates.md) · Defaults: [naming-defaults.md](naming-defaults.md).

### `state.md` schema (CC-01.4 — IMPL-02-01)

`state.md` is the workspace-level lifecycle file. The orchestrator reads it at startup (per CC-05.4) and refuses to enter P1 until `Bootstrap completed <ts>` is present. Fields: `Bootstrap completed`, `Workflow active`, `Last metric stamp`.

> Full schema and example: [language-discovery.md](language-discovery.md).

Language configuration is **discovered at setup time** (no hard-coded language adapters). All agents read only `language-config.md` and `conventions.md` at runtime.

## Reference Documents

| Topic | File |
|-------|------|
| Four-phase language discovery pipeline + `language-config.md` schema | [`language-discovery.md`](language-discovery.md) |
| Bash permissions proposal + Read pre-approvals (Step 3c) and preflight semantics | [`permissions.md`](permissions.md) |
| Legacy schema migration + `--keep-legacy` semantics | [`schema-upgrade.md`](schema-upgrade.md) |

## Behavior

### Step 0 — Detect Existing Context

Before doing anything, check which context files already exist in `.claude/context/`:
- `.claude/context/provider-config.md`
- `.claude/context/repos-metadata.md`
- `.claude/context/repos-paths.md`
- `.claude/context/language-config.md`
- `.claude/context/conventions.md`

Also check for the legacy `ado-config.md` — if it exists but `provider-config.md` does not, offer to migrate per [`schema-upgrade.md`](schema-upgrade.md):
> "I found a legacy `ado-config.md` file. I'll migrate its settings to the new `provider-config.md` format which supports multiple providers."

If **all five files** exist, the workspace is already fully initialized. Inform the user:

> "Your workspace is already fully initialized — all context files exist:
> - `provider-config.md`, `repos-metadata.md`, `repos-paths.md`, `language-config.md`, `conventions.md`
>
> Nothing to do. If you want to update files, use:
> - `/init-workspace --refresh-conventions` to regenerate conventions
> - `/init-workspace --refresh-permissions` to re-propose Bash permissions only
> - `/init-workspace --full` to regenerate everything from scratch"

Then **stop**.

If **some files** exist but not all, inform the user which files are missing and proceed to generate only the missing ones. Offer `--full` to regenerate everything instead.

If **no files** exist, proceed with **full setup** from Step 1.

### Step 1 — Provider Selection

Ask the user to select their work item provider and git provider:

> **Work Item Provider** — where your stories/issues live:
> 1. **ADO** (Azure DevOps Work Items)
> 2. **Jira** (Atlassian Jira Issues)
> 3. **GitLab** (GitLab Issues)
> 4. **GitHub** (GitHub Issues)
> 5. **Zoho** (Zoho Mail Group Tasks)
> 6. **local-markdown** (Local `.md` file — no external system required)

> **Git Provider** — where your code repos and PRs/MRs live:
> 1. **ADO** (Azure DevOps Repos)
> 2. **GitLab** (GitLab Repos + Merge Requests — via GitLab MCP)
> 3. **GitLab CLI** (`glab-cli`) (via `glab` CLI, no MCP needed)
> 4. **GitHub** (GitHub Repos + Pull Requests — via `@anthropic/github-mcp`)
> 5. **GitHub CLI** (`gh-cli`) (via `gh` CLI, no MCP needed)

After selection, **verify MCP server / CLI availability** by exercising a lightweight call:

| Provider | Verification |
|----------|--------------|
| ADO | Call any `mcp__azure-devops__*` tool |
| Jira | Call `mcp__jira__get_issue` |
| GitLab | Call `mcp__gitlab__get_issue` |
| GitHub | Call `mcp__github__get_issue` |
| GitHub CLI | Run `gh --version && gh auth status` |
| GitLab CLI | Run `glab --version && glab auth status` |
| Zoho | Call `mcp__zoho__ZohoMail_getMailAccounts` |
| local-markdown | No verification — `Read`/`Write` tools are always available |

If the required MCP server or CLI is not available or not authenticated, warn the user with the appropriate remediation (`gh auth login`, install MCP server, etc.) and proceed only after they confirm.

### Step 2 — Provider Configuration

Based on the selected providers, collect provider-specific settings.

#### ADO (Work Item Provider)
1. **Organization URL**: e.g., `https://dev.azure.com/your-org`
2. **Project name**: e.g., `MyProject`
3. **Area path**: e.g., `MyProject\Engineering\Backend Team`
4. **Iteration path pattern**: e.g., `MyProject\Sprint 42`
5. **Work item types**: Confirm hierarchy (Epic > Feature > User Story > Task, or custom)
6. **Custom fields**: Any team-specific fields

#### Jira (Work Item Provider)
1. **Jira instance URL**: e.g., `https://your-company.atlassian.net`
2. **Project key**: e.g., `PROJ`
3. **Acceptance Criteria field**: Custom field (get field ID), embedded in description, or subtasks
4. **Sprint field** / **Story points field**: Default or custom field name
5. **Issue types**: Confirm hierarchy

#### GitLab (Work Item Provider)
1. **GitLab URL**: `https://gitlab.com` or self-hosted
2. **Group/Project path**: e.g., `myorg/myproject`
3. **AC convention** and **label taxonomy**

#### GitHub (Work Item Provider)
1. **Organization/Owner**, **issue repo(s)**
2. **AC convention** and **label taxonomy**

#### Zoho (Work Item Provider)
1. **Group ID** — integer from the Zoho Mail URL or group settings. Verify by calling `mcp__zoho__ZohoMail_listGroupTask`. Record as `zoho_group_id`.
2. **Categories** — call `mcp__zoho__ZohoMail_getCategoriesInGroupTasks`. Record names and IDs.
3. **AC convention** — confirm ACs are embedded in the task description under `## Acceptance Criteria` (no dedicated field exists in Zoho Group Tasks).
4. **Assignee Zuids** — record team member Zuids; `ZohoMail_getMailAccounts` returns the current user's Zuid.

#### local-markdown (Work Item Provider)
1. **Default stories directory** (optional): stored as `stories_dir` in `provider-config.md`. Story-workflow commands always accept an explicit file path regardless of this setting.
2. No further configuration needed.

#### Git Provider Settings (if different from work item provider)
Collect repository-specific settings (these overlap with Step 3 — combine them): GitLab project paths, GitHub owner/repo names, ADO already collected above.

### Step 3 — Repo Discovery

Ask the user to provide the local filesystem path for each team repo:

> "Please provide the local path for each of your team's repos, one at a time.
> For example: `/home/dev/repos/auth-service`
> Type 'done' when you've listed all repos."

For each path provided:
1. Verify the path exists and is a git repo.
2. Identify the default branch (`main` or `master`).
3. **Ensure the repo is on the default branch and up to date:**
   ```bash
   git -C <path> checkout <default-branch>
   git -C <path> pull
   ```
   If `git pull` fails (no remote, auth issue), warn but continue with the local state. If the checkout fails (uncommitted changes), warn and proceed on the current branch.
4. **Detect the git provider's remote** by parsing `git remote get-url origin`:
   - `dev.azure.com` / `*.visualstudio.com` → ADO
   - `gitlab.com` or configured GitLab host → GitLab
   - `github.com` → GitHub

   Extract the project/repo identifier from the remote URL.
5. Scan the repo for metadata: name, type, stack, domain, key patterns.
6. Present for confirmation and apply corrections.

Write `.claude/context/repos-metadata.md` with the standard format.

**Multi-language monorepos:** If a single git repo contains more than one primary language (e.g. Python backend + TypeScript frontend), ask the user to register it as **two logical repos** in `repos-paths.md`, each with its own `project_root` (e.g. `monorepo-api` → `/path/to/monorepo/api` and `monorepo-web` → `/path/to/monorepo/web`). The language-config schema is one language per logical repo.

### Step 3b — Language Discovery

Run the four-phase language discovery pipeline (Detect → Infer → Negotiate → Write) per repo. The full procedure, marker file lists, inference rules, negotiation prompts, and `language-config.md` schema live in [`language-discovery.md`](language-discovery.md).

If `--keep-legacy` was passed, follow the in-place upgrade flow in [`schema-upgrade.md`](schema-upgrade.md) instead of running Phase 3 negotiation.

### Step 3c — Permissions Proposal

After Phase 3 negotiate completes for **all repos**, propose Bash permissions (interactive, per-command-head) **and** auto-add Read pre-approvals for the harness plugin files (`Read(~/.claude/plugins/**)`) and every repo path in `repos-paths.md` (`Read(//<repo-path>/**)`). Read pre-approvals are added without prompting — the paths are already trusted by virtue of installation and configuration, and prompting would stall background agents that cannot respond. Full procedure (collation, presentation, JSON edit, idempotency, fallback, preflight semantics) in [`permissions.md`](permissions.md).

### Step 4 — Conventions Extraction

Compose `.claude/context/conventions.md` — the single authoritative conventions file that all agents consume at runtime. Assemble it from three layers:

1. **Team Rules (universal)** — Ask the user before writing:

   > "A few team-wide conventions to capture:
   > 1. **Team name** — used as the branch prefix (e.g. `backend`, `platform`, `payments`).
   >    All feature branches will be `<team-name>/feature/<id>-<slug>`.
   > 2. **Coverage threshold** — minimum line coverage required (default: 90%).
   > 3. **PR title format** — any required prefix or format? (e.g. `[STORY-ID] title`, or leave blank for default)"

   Record the answers as concrete values — never leave `<team>` as a placeholder. The team name is **required**; re-prompt if left blank.

2. **Language Baselines** — one section per distinct language detected across the workspace. Naming, project structure, testing patterns. Generated from the Phase 2 inferences and Phase 3 negotiated answers — **not** from any static adapter file.

3. **Repo-Specific Patterns** — per-repo section with the architecture style, detected frameworks, and any review enforcements the user requested in Phase 3 (e.g. "no DB imports in api/").

Write `.claude/context/conventions.md` with the combined result. This is the only conventions file agents read.

> **SOLID / DRY / YAGNI do NOT live in `conventions.md`.** Those universal engineering principles are baked into the Developer and Reviewer agent prompts directly — static, identical across all projects, not discovered per-repo.

#### `conventions.md` schema

Three sections: `## 1. Team Rules (universal)` (team name, commit format, coverage threshold), `## 2. Language Baselines` (per-language naming/structure/testing), `## 3. Repo-Specific Patterns` (architecture, frameworks, review enforcements).

> Full schema with example: [language-discovery.md](language-discovery.md).

### Step 5 — Local Repo Paths

Generate `.claude/context/repos-paths.md` mapping repo names to local paths. For multi-language monorepos registered as two logical repos, each entry points to its own `project_root`.

### Step 5b — Propose Naming Templates (IMPL-15-02 / CC-01.8)

<!-- Changed by: dev-workflow-plan.md [M-15] [IMPL-15-02]
     Reason: Propose-or-customise step for naming templates per CC-01.8.
     CC conventions applied: CC-01.8. -->

Read the shipped defaults from [`naming-defaults.md`](naming-defaults.md) and present them to the human:

```
Proposed naming templates (from naming-defaults.md):
  Branch:     ${type}/${story_id}-${slug}
  Commit:     #${story_id} #${task_id} ${type}: ${slug}
  PR title:   [${repo}] ${slug}
  Tag:        v${story_id}

Accept defaults (Y), customise (c), or skip and accept later (s)?
```

### Step 5c — Cross-check against pr-conventions (IMPL-15-06)

Resolve the configured git provider (from Step 1) and check its `skills/providers/<provider>/pr-conventions.md` (or `pull-requests.md`) for any required PR-title prefix or shape constraint. If the chosen `pr_title_format` conflicts (e.g. ADO requires `[<team>]` prefix and the chosen template omits it), surface the conflict to the human before writing:

```
⚠ Your chosen pr_title_format `${slug}` does not include the `[<team>]` prefix
that the configured git provider (ado) expects per shared/pr-conventions.md.
[a] Accept anyway (record deviation as a comment in naming-config.md)
[c] Customise pr_title_format
[d] Drop the cross-check entirely
```

The user's choice wins; the validator records the deviation in `naming-config.md` as a comment so future audits can locate it.

### Step 5d — Emit `naming-config.md`

Write `.claude/context/naming-config.md` with the four chosen templates. The file format matches the schema declared at the top of this SKILL.md. Cross-check warnings (if any) are appended as `<!-- deviation: ... -->` comments below the relevant key.

### Step 6 — Generate Provider Config

Read the template from `skills/providers/provider-config-template.md` and fill in all values based on the selections from Steps 1–2. Read the relevant provider adapters from `skills/providers/<provider>/` to populate tool mappings.

Write `.claude/context/provider-config.md` with the completed configuration.

### Step 6b — Emit `state.md` (IMPL-02-02 / CC-05.3)

Write `.claude/context/state.md` with the `Bootstrap completed` line. Use the canonical UTC timestamp helper per CC-05.3 — never reproduce the `date -u` literal inline.

> Authoritative reference: [timestamp](../dev-workflow/context/timestamp.md)

```bash
TS=$(date -u +"%Y-%m-%d %H:%M UTC")
cat > .claude/context/state.md <<EOF
# Workspace State

Bootstrap completed: ${TS}
Workflow active: none
Last metric stamp: Bootstrap completed ${TS}
EOF
```

Idempotency: re-running `init-workspace` rewrites `state.md` only when the file is absent OR `--full` was passed. When the file exists and `--full` was not passed, the existing `Bootstrap completed` timestamp is preserved (the user accepted the bootstrap state previously); the `Workflow active` and `Last metric stamp` lines are reset on `--full`.

### Step 6c — Mirror plugin shared files into the workspace

Subagents (planner / developer / tester / reviewer) reference shared markdown
in `agents/shared/` via their `Read` tool — but `CLAUDE_PLUGIN_ROOT` is **not**
exported to the agent runtime (only to hook scripts), so a relative path like
`agents/shared/engineering-principles.md` resolves against the user's project
workspace, where the file doesn't exist. The agents report `not found`
(non-blocking but noisy). Resolution: mirror the plugin's `agents/shared/*.md`
into the workspace at `.claude/context/agents-shared/` so agents resolve them
via workspace-relative paths.

Run the shared-files refresh script (idempotent — overwrites existing copies
so a plugin upgrade propagates on the next run):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/refresh-shared.sh" "$PWD"
```

`refresh-shared.sh` discovers the latest installed plugin version under
`~/.claude/plugins/cache/ai-sdlc-harness/ai-sdlc-harness/<version>/` and copies
every `.md` file from its `agents/shared/` directory into the workspace's
`.claude/context/agents-shared/`. The agent index files reference
`.claude/context/agents-shared/<file>.md` (workspace-relative) — this Step
ensures those paths resolve.

Exit codes from the script:
- `0` — copied (count printed) or already in sync
- `1` — plugin install not found (the user must install / update the plugin)
- `2` — workspace lacks `.claude/context/` (an earlier Step failed)

`/init-workspace --refresh-shared` re-runs only this Step — useful after a
plugin upgrade adds new shared files. Existing workspace files are
overwritten; agent customisations in `.claude/context/agents-shared/` are not
preserved (the directory is plugin-managed, not user-edited).

### Step 6d — Emit `cost-config.md` (IMPL-25-03 / ADR-010)

<!-- Added by: dev-workflow-plan.md [M-25] [IMPL-25-03]
     Reason: User-supplied cost-config template per ADR-010; consumed by /dev-workflow report.
     CC conventions applied: CC-02.4.2 (null-safe cost fields), ADR-010. -->

Write `.claude/context/cost-config.md` from the shipped template at
`skills/init-workspace/templates/cost-config.md`.

Idempotency: skip if the file already exists and `--full` was **not** passed —
the user may have filled in their rates and a re-run must not overwrite them.
On `--full`, overwrite and note in the summary that the file was reset.

After writing, remind the human to fill in their model rates:

> "📊 `cost-config.md` created at `.claude/context/cost-config.md`.
> Edit the rate table to enable `$` cost columns in `/dev-workflow report`.
> Leave cells empty for models you don't use — empty rates render as
> `cost: n/a` rather than `$0.00`."

### Step 7 — Summary

Present a summary:

> "Workspace initialized! Here's what was generated:
> - `provider-config.md` — Work items: <provider>, Git: <provider>
> - `repos-metadata.md` — [N] repos registered
> - `repos-paths.md` — local paths configured
> - `language-config.md` — [N] repos with discovered toolchains
> - `conventions.md` — team rules + language baselines + repo-specific patterns
> - `cost-config.md` — fill in model rates to enable `$` columns in reports (ADR-010)
>
> **Languages discovered:**
> - AuthService → python 3.12 (FastAPI, layered, zero_warning_support=linter-based)
> - PaymentGateway → go 1.22 (Gin, hexagonal, zero_warning_support=native)
>
> **Permissions updated:** N Bash entries (per-command) plus 1 plugin-read entry (`Read(~/.claude/plugins/**)`) and M repo-read entries (`Read(//<repo-path>/**)`) added to `settings.json`. Restart your session if you hit unexpected permission prompts.
>
> **Next steps:**
> - All context files are local and git-ignored — no commit needed.
> - You're ready to use `/dev-workflow` and `/story-workflow`."

## Flags

- `--full` — Force full setup even if context files exist. Will overwrite all context files. Asks for confirmation before proceeding.
- `--refresh-conventions` — Only regenerate `conventions.md` from the current codebase and prior `language-config.md`. Useful after major architectural changes.
- `--refresh-permissions` — Re-run only Step 3c against the existing `language-config.md`. Does not touch discovery. See [`permissions.md`](permissions.md).
- `--keep-legacy` — In-place schema upgrade for an existing legacy-schema `language-config.md`. See [`schema-upgrade.md`](schema-upgrade.md).
