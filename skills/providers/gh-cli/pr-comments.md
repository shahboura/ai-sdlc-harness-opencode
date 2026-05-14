# GitHub CLI PR Review Comments Adapter

Provider adapter for **listing and replying to PR review comments** on GitHub via the
`gh` CLI. Used during Phase 7 (`/dev-workflow review-response`) when
`provider-config.md` specifies `Git Provider: gh-cli`.

This adapter is the CLI-only sibling of `skills/providers/github/pr-comments.md` — same
canonical primitives, same `gh api graphql` and `gh api .../replies` paths, no MCP
fallback section.

## Operations

| Capability | Primitive | Path |
|------------|-----------|------|
| `pr.find_for_branch` | `gh pr list` | CLI |
| `pr.list_review_comments` | `gh api graphql` (reviewThreads) | CLI / REST GraphQL |
| `pr.reply_to_review_comment` | `gh api .../pulls/{pr}/comments/{id}/replies` | CLI / REST |

## Prerequisites

```bash
gh --version          # gh CLI present
gh auth status        # authenticated session
```

If `gh auth status` fails, prompt the user to run `gh auth login` before continuing.

## Find Open PR for a Feature Branch (`pr.find_for_branch`)

```bash
gh pr list \
  --repo <owner>/<repo> \
  --head <feature-branch> \
  --state open \
  --json number,url,headRefName,isDraft \
  --limit 1
```

Empty array `[]` means no open PR for the branch.

## List Unresolved Review Threads (`pr.list_review_comments`)

REST does not expose thread resolution state. GraphQL `reviewThreads` is the only path
to `isResolved`.

```bash
gh api graphql \
  -F owner=<owner> -F repo=<repo> -F pr=<pr-number> \
  -f query='
    query($owner:String!, $repo:String!, $pr:Int!) {
      repository(owner:$owner, name:$repo) {
        pullRequest(number:$pr) {
          reviewThreads(first:100) {
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              comments(first:50) {
                nodes {
                  databaseId
                  author { login }
                  body
                  createdAt
                  position
                  originalPosition
                }
              }
            }
          }
        }
      }
    }'
```

Filter to `isResolved == false`. Skip bot-only threads (see Bot Comment Filter below).
For each retained thread, capture:

- `thread_id` ← `id` (GraphQL node ID — internal state only)
- `comment_id` ← `comments.nodes[0].databaseId` (REST integer ID — used for replies)
- `file` ← `path` (or `null` for general PR comments)
- `line` ← `line` (fall back to `originalPosition` if `line` is `null` because the
  line moved)
- `author` ← `comments.nodes[0].author.login`
- `body` ← `comments.nodes[0].body`

### Top-Level PR Comments (general)

Non-inline PR conversation comments live on the `issue_comments` endpoint:

```bash
gh api repos/<owner>/<repo>/issues/<pr-number>/comments --paginate \
  --jq '.[] | select(.user.type != "Bot") |
        {id, author: .user.login, body, created_at}'
```

Treat each as a single-message thread with `file: "general"` and `line: null`.

## Reply to a Review Thread (`pr.reply_to_review_comment`)

For inline threads — REST `replies` endpoint, REST integer comment ID:

```bash
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  repos/<owner>/<repo>/pulls/<pr-number>/comments/<comment-id>/replies \
  -f body="Addressed in commit <sha>: <one-sentence summary>"
```

For top-level (`general`) comments — `gh pr comment`:

```bash
gh pr comment <pr-number> \
  --repo <owner>/<repo> \
  --body "Re #<original-comment-id>: addressed in commit <sha>: <summary>"
```

## Thread ID Persistence

The orchestrator stores the REST integer `databaseId` in the tracker's `Notes` column
as `thread_id=<value>`. For the top-level `general` case, store
`thread_id=general:<comment-id>` so Phase 9's reply routing picks the right endpoint.

## Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| `pr.find_for_branch` | ✅ | `gh pr list --head <branch> --state open` |
| `pr.list_review_comments` | ✅ | `gh api graphql` with `reviewThreads.isResolved` filter |
| `pr.reply_to_review_comment` | ✅ | REST `replies` endpoint for inline; `gh pr comment` for general |

## Bot Comment Filter

Skip threads where the only author is a bot. Known patterns:

```
*[bot]                  # GitHub Apps suffix (e.g. dependabot[bot])
dependabot
codecov
coderabbitai
github-actions
sonarcloud
```

## Provider-Specific Quirks

1. **GraphQL is the only path to `isResolved`** — REST review-comment listings don't
   expose thread state. Do not approximate with `in_reply_to_id` chains.
2. **`line` vs `originalPosition`** — when the file has been edited after a comment was
   posted, `line` may be `null`. Fall back to `originalPosition`.
3. **No thread-level reply for issue comments** — top-level PR comments only support
   further top-level comments. Route to `gh pr comment` rather than the `replies`
   endpoint.
4. **Outdated threads (`isOutdated: true`, `isResolved: false`)** — surface these but
   note in the Reviewer prompt that the referenced line may be stale.
