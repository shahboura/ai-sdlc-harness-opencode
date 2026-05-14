# Azure DevOps PR Review Comments Adapter

Provider adapter for **listing and replying to Pull Request review comments** on
Azure DevOps. Used during Phase 7 (`/dev-workflow review-response`) when
`provider-config.md` specifies `Git Provider: ado`.

ADO structures PR comments as **threads** under a Pull Request. Each thread has a
`status` (`active` / `fixed` / `wontFix` / `closed` / `pending` / `byDesign`) plus
zero or more `comments`. Phase 7 processes threads in `active` or `pending` status.

The canonical path is REST via `curl` (portable, no `az` CLI dependency). MCP tools
that wrap these endpoints may exist in some harness installations
(`mcp__azure-devops__repo_list_pull_request_threads`,
`mcp__azure-devops__repo_create_pull_request_thread_reply`); they're noted below as a
🟡 alternative — verify in your `provider-config.md` before relying on them.

## Operations

| Capability | Primitive | Path |
|------------|-----------|------|
| `pr.find_for_branch` | REST `GET /pullrequests?searchCriteria.sourceRefName=...` | curl |
| `pr.list_review_comments` | REST `GET /pullRequests/{prId}/threads` | curl |
| `pr.reply_to_review_comment` | REST `POST /pullRequests/{prId}/threads/{tid}/comments` | curl |

## Prerequisites

```bash
echo "$AZURE_DEVOPS_PAT" | head -c 4    # confirm the PAT env var is set
curl --version                          # curl present (universal on dev machines)
```

The PAT must include the **Code (read & write)** scope. Pass it on every request as
HTTP Basic auth with an empty username:

```bash
AUTH="-u :${AZURE_DEVOPS_PAT}"
ORG=<organization>     # e.g. "myorg"
PROJECT=<project>      # e.g. "engineering"
REPO=<repository>      # repository name or GUID
API=7.1
```

If the PAT is unset or rotated, the requests below return HTTP 401 — surface this
through `pr-creator`'s auth-failure copy in `pull-requests.md` Prerequisites.

## Find Open PR for a Feature Branch (`pr.find_for_branch`)

```bash
curl -sS $AUTH \
  "https://dev.azure.com/${ORG}/${PROJECT}/_apis/git/repositories/${REPO}/pullrequests?\
searchCriteria.sourceRefName=refs/heads/<feature-branch>&\
searchCriteria.status=active&api-version=${API}"
```

ADO requires the `refs/heads/` prefix on `sourceRefName`. Parse the response's
`value[]` array — empty means no open PR for the branch. Capture
`pullRequestId` and `_links.web.href` from the first element.

## List Active Threads (`pr.list_review_comments`)

```bash
curl -sS $AUTH \
  "https://dev.azure.com/${ORG}/${PROJECT}/_apis/git/repositories/${REPO}/pullRequests/${PR_ID}/threads?api-version=${API}"
```

Each thread in `value[]` has:

- `id` — thread ID (integer)
- `status` — one of `active`, `fixed`, `wontFix`, `closed`, `pending`, `byDesign`
- `threadContext.filePath` — file the thread is anchored to (`null` for general PR
  comments)
- `threadContext.rightFileStart.line` — the line in the target branch's version
- `comments[]` — comment objects with `id`, `author.displayName`, `content`,
  `commentType` (`text`, `codeChange`, `system`), `publishedDate`

**Filter rules:**

- Skip threads where `status` is **not** `active` or `pending` — Phase 7 processes
  open threads.
- Skip threads whose ONLY non-`system` author is a bot (see below).
- A thread with no non-`system` comments is automated noise — skip.

For each retained thread, capture:

- `thread_id` ← `id` (integer — used directly in the reply URL)
- `file` ← `threadContext.filePath` (or `null` for general)
- `line` ← `threadContext.rightFileStart.line` (or `null` for general)
- `author` ← first non-`system` comment's `author.displayName`
- `body` ← first non-`system` comment's `content`

## Reply to a Thread (`pr.reply_to_review_comment`)

```bash
curl -sS $AUTH \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"content":"Addressed in commit <sha>: <one-sentence summary>","commentType":"text","parentCommentId":<original-comment-id>}' \
  "https://dev.azure.com/${ORG}/${PROJECT}/_apis/git/repositories/${REPO}/pullRequests/${PR_ID}/threads/${THREAD_ID}/comments?api-version=${API}"
```

`parentCommentId` must reference an existing comment in the thread — passing the
original review comment's `id` keeps the reply correctly nested.

For general (file-less) threads, the same endpoint works — `threadContext` is `null`
on both sides and the reply just adds another comment to the thread.

## Thread ID Persistence

The orchestrator stores the thread `id` (integer) in the tracker's `Notes` column as
`thread_id=<integer>`. For general threads, store
`thread_id=general:<thread-id>` if you want Phase 9's reply text to differentiate;
ADO uses the same reply endpoint for both, so the `general:` prefix is purely
informational.

## Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| `pr.find_for_branch` | ✅ | REST `/pullrequests?searchCriteria.sourceRefName=...` (requires `refs/heads/` prefix) |
| `pr.list_review_comments` | ✅ | REST `/threads` with status filter (`active` / `pending`) |
| `pr.reply_to_review_comment` | ✅ | REST `/threads/{tid}/comments` with `parentCommentId` |

If your harness's ADO MCP server exposes `mcp__azure-devops__repo_list_pull_request_threads`
and a thread-reply tool, prefer them — they wrap the same endpoints with the same
auth. Mark those as 🟡 (emulated/wrapped) unless you've verified the tool surface in
your specific server version.

## Bot Comment Filter

Skip threads authored exclusively by these display-name patterns:

```
Microsoft.VisualStudio.Services.TFS
Azure DevOps
Project Collection Build Service
*Build Service*
*[bot]
```

`commentType: system` posts are filtered separately (state changes, build status).

## Provider-Specific Quirks

1. **`refs/heads/` prefix is mandatory.** ADO uses fully-qualified refs everywhere
   (PR source/target, thread context). Bare branch names return empty results.
2. **Thread status enum is wider than open/resolved.** Be explicit: `active` and
   `pending` are open; everything else is resolved/dismissed. `wontFix` and `byDesign`
   in particular are "resolved with rationale" — surface them only if the human is
   doing a retrospective.
3. **`api-version` query param is mandatory.** ADO REST returns HTTP 400 if it's
   missing. `7.1` is current at time of writing; `6.0` is also widely supported.
4. **PAT scopes.** "Code (read)" is enough for listing; replies require "Code (read &
   write)". Insufficient scope returns HTTP 403 with a clear message — surface it
   through the auth-failure copy.
5. **Comment IDs are thread-local sequence numbers**, not global. `parentCommentId` is
   the ID returned in the original comment object's `id` field — typically `1` for
   the first comment in a thread.
