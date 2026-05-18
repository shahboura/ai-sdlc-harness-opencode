# GitLab CLI Merge Request Adapter

Provider adapter for GitLab Merge Requests via the `glab` CLI. Used when
`provider-config.md` specifies `Git Provider: glab-cli`.

Use this adapter instead of `providers/gitlab/merge-requests.md` when:
- The GitLab MCP server is not available or not configured.
- The team prefers CLI-based tooling over MCP.

## Prerequisites

```bash
glab --version          # Confirm glab CLI is installed
glab auth status        # Confirm authenticated (run glab auth login if not)
```

## Tool Reference

All operations use the `Bash` tool to invoke `glab` CLI commands.

### Create a Merge Request

```bash
glab mr create \
  --repo <group>/<project> \
  --source-branch <branch> \
  --target-branch <default-branch> \
  --title "<ID-DISPLAY>: <summary>" \
  --description "<MR-body>" \
  --remove-source-branch
```

**Parameters:**
- `--repo` — `group/project` path (e.g., `myorg/auth-service`). Omit if running from inside the repo directory.
- `--source-branch` — Source branch, bare name (e.g., `backend/feature/123-add-notifications`)
- `--target-branch` — Target branch (e.g., `main`, `develop`)
- `--title` — MR title following the project convention
- `--description` — Markdown MR description
- `--remove-source-branch` — Auto-delete the source branch after merge (recommended)

**Important:** Bare branch names only — no `refs/heads/` prefix.

**Response:** Prints the MR URL to stdout (e.g., `https://gitlab.com/myorg/auth-service/-/merge_requests/42`).

### Full Example

```bash
glab mr create \
  --repo myorg/auth-service \
  --source-branch backend/feature/123-add-notifications \
  --target-branch main \
  --title "#123: Add notifications support" \
  --description "Closes #123

## Summary
- Added new configuration endpoint
- Implemented token validation

## Test Plan
- [x] Unit tests pass (92% coverage)
- [x] Integration tests pass

---
🤖 Generated with [Claude Code](https://claude.ai/claude-code)" \
  --remove-source-branch
```

### Draft MR

```bash
glab mr create \
  --repo <group>/<project> \
  --source-branch <branch> \
  --target-branch <default-branch> \
  --title "Draft: <ID-DISPLAY>: <summary>" \
  --description "<body>" \
  --draft \
  --remove-source-branch
```

GitLab marks an MR as draft when the title is prefixed with `Draft:` or the `--draft` flag is passed.

### Add MR Comment

```bash
glab mr note <MR-IID> --repo <group>/<project> --message "<Markdown comment>"
```

### View MR Details

```bash
glab mr view <MR-IID> --repo <group>/<project>
```

## MR Creation Flow

1. Push the feature branch to remote:
   ```bash
   git -C <repo-path> push -u origin $(git -C <repo-path> rev-parse --abbrev-ref HEAD)
   ```
2. Create the MR with `glab mr create`. Include `Closes #<ISSUE-IID>` in `--description`
   to auto-link and auto-close the GitLab Issue when merged.
3. Capture the MR URL from stdout and record it in the task tracker.
4. For multi-repo stories with separate GitLab projects, use cross-project references:
   ```
   Closes mygroup/other-project#123
   ```

**If work item provider is Jira:** See `skills/providers/shared/pr-conventions.md` — [When Work Item Provider is Jira](../shared/pr-conventions.md#when-work-item-provider-is-jira).

## MR Title Convention

- **Single repo**: `#<ISSUE-IID>: <summary>`
- **Multi-repo**: `#<ISSUE-IID>: <summary> [<RepoName>]`

**If work item provider is Jira:** See `skills/providers/shared/pr-conventions.md` — [When Work Item Provider is Jira](../shared/pr-conventions.md#when-work-item-provider-is-jira).

## Link to Issue (Auto-Close)

GitLab automatically links MRs to issues via keywords in the MR description or commit messages:

```markdown
Closes #123
```

**Supported keywords**: `Closes`, `Fixes`, `Resolves` (case-insensitive).

For cross-project references:
```markdown
Closes mygroup/myproject#123
```

No separate API call is needed — GitLab handles linking and auto-closing natively.

## Capabilities

See `skills/providers/shared/capabilities.md` for the canonical list and declaration format.

| Capability | Status | Notes |
|------------|--------|-------|
| `pr.create` | ✅ | `glab mr create` |
| `pr.find_for_branch` | 🟡 | `glab mr list --source-branch <branch> --state opened --output json --per-page 1` — may return 404 on self-hosted instances; see Troubleshooting below |
| `pr.link_work_item` | 🟡 | Emulated — `Closes #IID` keyword in MR description auto-links and auto-closes the issue |
| `pr.set_draft` | ✅ | `--draft` flag (or `Draft:` title prefix) |

PR review-comment capabilities (`pr.list_review_comments`, `pr.reply_to_review_comment`)
are declared separately in [`pr-comments.md`](./pr-comments.md).

## Terminology

- **Type**: Merge Request (MR)
- **Source branch flag**: `--source-branch`
- **Target branch flag**: `--target-branch`
- **Branch prefix**: None (bare branch names)

## Provider-Specific Quirks

1. **No branch prefix**: Use bare branch names. Do NOT prepend `refs/heads/`.
2. **Auth required**: `glab auth status` must show an active session before MR creation.
   If not authenticated, prompt the user to run `glab auth login`.
3. **Auto-close via keywords**: `Closes #123` in MR description auto-closes the linked issue
   when the MR is merged.
4. **Remove source branch**: Always pass `--remove-source-branch` to auto-clean feature branches
   after merge, consistent with the MCP-based GitLab adapter.
5. **Draft MRs**: Use `--draft` flag or prefix title with `Draft:`. Remove when ready for review.
6. **Cross-project MRs**: Not natively supported — each MR must be within a single project.
   For multi-repo stories, create separate MRs per project and cross-reference them.
7. **Approvals**: GitLab built-in approval rules apply. The workflow's internal reviewer agent
   does not satisfy GitLab's merge request approval requirements.
8. **--repo flag**: If `glab` is run from inside the repo directory, `--repo` can be omitted
   and glab infers the project from the git remote. Use explicit `--repo` for clarity in
   automated workflow execution.

## Troubleshooting

### `glab mr list` returns 404

On self-hosted GitLab instances, `glab mr list --repo <group>/<project>` may
fail with a 404 if the CLI cannot resolve the project path. Use the REST API
fallback:

1. Resolve the numeric project ID:
   ```bash
   glab api "projects?search=<project-name>" | python3 -c \
     "import sys,json; [print(p['id'], p['path_with_namespace']) for p in json.load(sys.stdin)]"
   ```
2. List open MRs for the branch by project ID:
   ```bash
   glab api "projects/<id>/merge_requests?source_branch=<branch>&state=opened&per_page=1"
   ```
3. Use the returned `iid` as the MR identifier for subsequent operations.
