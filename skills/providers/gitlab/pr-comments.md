# GitLab MR Review Comments Adapter

Provider adapter for **listing and replying to Merge Request review comments** on
GitLab via the gitlab.com (or self-hosted) REST API. Used during Phase 7
(`/dev-workflow review-response`) when `provider-config.md` specifies
`Git Provider: gitlab`.

GitLab structures inline review comments as **discussions** (threads) under an MR,
each containing one or more notes. The canonical Phase 7 path is REST via `curl`
(portable, no `glab` CLI dependency). MCP tools wrapping these endpoints may exist —
noted as a 🟡 alternative; verify against your harness install before relying.

## Operations

| Capability | Primitive | Path |
|------------|-----------|------|
| `pr.find_for_branch` | REST `GET /projects/<id>/merge_requests?source_branch=...&state=opened` | curl |
| `pr.list_review_comments` | REST `GET /projects/<id>/merge_requests/<iid>/discussions` | curl |
| `pr.reply_to_review_comment` | REST `POST /projects/<id>/merge_requests/<iid>/discussions/<id>/notes` | curl |

## Prerequisites

```bash
echo "$GITLAB_TOKEN" | head -c 4    # confirm PAT env var is set
curl --version                      # curl present
```

The PAT must include the **api** scope (read + write on merge requests). Pass it on
every request as the `PRIVATE-TOKEN` header:

```bash
AUTH=(-H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
HOST=https://gitlab.com              # or https://gitlab.<your-host>
PROJECT_ID=<numeric-id-or-url-encoded-path>
```

If the PAT is unset or rotated, requests return HTTP 401 — surface through
`pr-creator`'s auth-failure copy in `merge-requests.md` Prerequisites.

## Find Open MR for a Feature Branch (`pr.find_for_branch`)

```bash
curl -sS "${AUTH[@]}" \
  "${HOST}/api/v4/projects/${PROJECT_ID}/merge_requests?\
source_branch=<feature-branch>&state=opened&per_page=1"
```

Empty JSON array `[]` means no open MR. Parse the first element to capture `iid`
(project-scoped) and `web_url`. **Do not** use the global `id`.

## List Discussions (`pr.list_review_comments`)

```bash
curl -sS "${AUTH[@]}" \
  "${HOST}/api/v4/projects/${PROJECT_ID}/merge_requests/${MR_IID}/discussions?per_page=100"
```

The response is an array of discussions. Each has:

- `id` — discussion (thread) ID, a hex string
- `individual_note: false` for review threads, `true` for floating MR notes
- `notes[]` — each with `id`, `author.username`, `body`, `created_at`, `system`,
  `resolvable`, `resolved`, `position.new_path`, `position.new_line`

**Filter rules:**

- Skip discussions where every note has `system: true`.
- Skip discussions whose only non-system author is a bot (see below).
- For each remaining discussion, check the `notes[0].resolved` (and the
  discussion-level `resolved` if present in older GitLab versions). Skip resolved
  threads — Phase 7 processes unresolved.

For each retained discussion, capture:

- `thread_id` ← discussion `id` (hex string)
- `note_id` ← `notes[0].id` (for state tracking only)
- `file` ← `notes[0].position.new_path` (or `null` for floating MR notes)
- `line` ← `notes[0].position.new_line`
- `author` ← `notes[0].author.username`
- `body` ← `notes[0].body`

## Reply to a Discussion (`pr.reply_to_review_comment`)

```bash
curl -sS "${AUTH[@]}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"body":"Addressed in commit <sha>: <one-sentence summary>"}' \
  "${HOST}/api/v4/projects/${PROJECT_ID}/merge_requests/${MR_IID}/discussions/${THREAD_ID}/notes"
```

For a floating MR note (no thread), reply as a standalone MR note:

```bash
curl -sS "${AUTH[@]}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"body":"Re #<original-note-id>: addressed in commit <sha>: <summary>"}' \
  "${HOST}/api/v4/projects/${PROJECT_ID}/merge_requests/${MR_IID}/notes"
```

## Thread ID Persistence

The orchestrator stores the discussion `id` (hex string) in the tracker's `Notes`
column as `thread_id=<hex>`. For floating MR notes, store
`thread_id=general:<note-id>` so Phase 9 routes to the `/notes` endpoint instead of
`/discussions/<id>/notes`.

## Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| `pr.find_for_branch` | ✅ | REST `GET /merge_requests?source_branch=...&state=opened` |
| `pr.list_review_comments` | ✅ | REST `/discussions`; `notes[0].resolved` carries thread state |
| `pr.reply_to_review_comment` | ✅ | REST `/discussions/<id>/notes` (threads) or `/notes` (floating) |

If your harness's GitLab MCP server exposes thread listing / reply tools
(e.g. `mcp__gitlab__list_merge_request_discussions`,
`mcp__gitlab__create_merge_request_discussion_note`), prefer them — they wrap these
endpoints with the same auth. Mark as 🟡 (emulated/wrapped) unless the tool surface
is verified for your MCP server version.

## Bot Comment Filter

Skip discussions authored exclusively by:

```
gitlab-bot
project_<N>_bot              # project access tokens
ghost-user
codeclimate
sonarcloud
```

`system: true` notes are filtered separately.

## Provider-Specific Quirks

1. **`iid` vs `id`.** Use `iid` everywhere in the URL paths and reply endpoints. The
   global `id` is for cross-project queries only.
2. **Project ID can be numeric or URL-encoded.** `${PROJECT_ID}` accepts either
   `12345` (numeric) or `group%2Fsubgroup%2Fproject` (URL-encoded path). The URL form
   is more portable across mirrored projects.
3. **`resolved` on the first note, not the discussion** in current GitLab versions.
   For self-hosted GitLab < 13, the `resolved` field may live on the discussion
   object itself — check both.
4. **API host.** Self-hosted GitLab uses a per-installation host. Confirm `${HOST}` in
   your `provider-config.md` matches the actual host before relying on this adapter.
5. **Token scope.** `read_api` is enough for listing; replies require the full `api`
   scope. Insufficient scope returns HTTP 403 — surface via auth-failure copy.
