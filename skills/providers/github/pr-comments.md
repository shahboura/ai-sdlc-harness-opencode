# GitHub PR Review Comments Adapter

Provider adapter for **listing and replying to PR review comments** on GitHub. Used during
Phase 7 (`/dev-workflow review-response`) when `provider-config.md` specifies
`Git Provider: github`.

Distinct from `pull-requests.md`, which covers PR creation. This file covers the read /
reply primitives needed to ingest reviewer feedback after a PR is open.

## Operations

| Capability | Primitive | Path |
|------------|-----------|------|
| `pr.find_for_branch` | `gh pr list` | CLI |
| `pr.list_review_comments` | `gh api graphql` (reviewThreads) | CLI / REST GraphQL |
| `pr.reply_to_review_comment` | `gh api .../pulls/{pr}/comments/{id}/replies` | CLI / REST |

The GitHub MCP server as currently configured in this harness does **not** expose
review-thread listing or replies — the `mcp__github__*` allow-list in
`agents/planner/index.md` and the github adapter's `pull-requests.md` only includes
write-side primitives (issue/PR-comment creation). The `gh` CLI is therefore the
canonical path for Phase 7. If a future MCP server release adds review-thread tools,
extend this adapter rather than the agent allow-lists directly.

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

**Returns:** JSON array. Empty array `[]` means no open PR exists for the branch.

**Example:**

```bash
gh pr list \
  --repo myorg/auth-service \
  --head backend/feature/123-add-notifications \
  --state open \
  --json number,url \
  --limit 1
# → [{"number":42,"url":"https://github.com/myorg/auth-service/pull/42"}]
```

Parse the first element to capture `number` and `url`.

## List Unresolved Review Threads (`pr.list_review_comments`)

GitHub's REST endpoint for PR review comments
(`GET /repos/{owner}/{repo}/pulls/{pr}/comments`) returns flat comments without
thread-level resolution state. Use GraphQL to get `isResolved` per thread.

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
                  path
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

**Filter client-side** to keep only threads where `isResolved == false`. Skip threads
authored exclusively by bots (check `author.login` for known bot suffixes —
`*[bot]`, `dependabot`, `codecov`, `coderabbitai`).

For each retained thread, capture:

- `thread_id` ← `id` (GraphQL node ID — used internally for state tracking only)
- `comment_id` ← `comments.nodes[0].databaseId` (REST integer ID — used for replies)
- `file` ← `path` (or `null` for general PR comments)
- `line` ← `line` (or `originalPosition` if `line` is `null` because the line moved)
- `author` ← `comments.nodes[0].author.login`
- `body` ← `comments.nodes[0].body`

The orchestrator's `[PC-<n>]` sequential ID is assigned across all repos in
`review-response.md` Step 2 — not derived from GitHub's IDs.

**Why `comments.nodes[0]`:** the first comment in a thread is the original review
remark. Subsequent nodes are replies. The Reviewer agent analyses the original
remark; replies are context the human can see by opening the PR.

### Top-Level PR Comments (general)

A PR can also receive non-inline "PR conversation" comments (the `issue_comments`
endpoint, not the `pulls/.../comments` endpoint). These do not appear in
`reviewThreads`. To capture them:

```bash
gh api repos/<owner>/<repo>/issues/<pr-number>/comments --paginate \
  --jq '.[] | select(.user.type != "Bot") |
        {id, author: .user.login, body, created_at}'
```

Treat each top-level comment as its own single-message thread with `file: "general"`
and `line: null`. There is no "resolved" concept for issue comments — surface them
all unless the orchestrator's filter excludes a known bot.

## Reply to a Review Thread (`pr.reply_to_review_comment`)

For inline review threads, reply via the `replies` endpoint using the **REST
integer comment ID** of any comment in the thread (typically the original):

```bash
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  repos/<owner>/<repo>/pulls/<pr-number>/comments/<comment-id>/replies \
  -f body="Addressed in commit <sha>: <one-sentence summary>"
```

For top-level PR comments (the `general` case), reply as a new conversation
comment — there is no threaded-reply endpoint for issue comments:

```bash
gh pr comment <pr-number> \
  --repo <owner>/<repo> \
  --body "Re #<original-comment-id>: addressed in commit <sha>: <summary>"
```

## Thread ID Persistence

The orchestrator stores the **REST comment ID** (the integer from `databaseId`) in
the tracker's `Notes` column as `thread_id=<value>` (per
`review-response.md` Step 7). On Phase 9 reply, the orchestrator reads this back
and passes it to the `replies` endpoint. Session memory is not used.

For the top-level `general` case, store `thread_id=general:<comment-id>` so the
Phase 9 reply path can route to `gh pr comment` instead of `replies`.

## Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| `pr.find_for_branch` | ✅ | `gh pr list --head` |
| `pr.list_review_comments` | ✅ | `gh api graphql` reviewThreads with `isResolved` filter |
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

Adapter callers should treat this list as a starting set and let the human
override at GATE #4 if a bot's comment is actually material.

## Provider-Specific Quirks

1. **GraphQL is the only path to `isResolved`.** REST review-comment listings do not
   expose thread resolution state. Do not approximate with `in_reply_to_id` chains —
   threads can be resolved with multiple unresolved replies still pending.
2. **`line` vs `originalPosition`.** When the file has been edited after the comment
   was posted, `line` may be `null`. Fall back to `originalPosition` so the comment
   still has a coordinate the Reviewer agent can locate via `git show`.
3. **No thread-level reply for issue comments.** Top-level PR comments do not support
   threaded replies — only further top-level comments. The adapter routes these to
   `gh pr comment` rather than the `replies` endpoint.
4. **Outdated threads are typically resolved.** If `isOutdated: true` and
   `isResolved: false`, the line the comment referenced no longer exists.
   Surface these but note in the Reviewer prompt that the location may be stale.
