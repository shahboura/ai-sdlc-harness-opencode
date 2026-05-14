# GitLab CLI MR Review Comments Adapter

Provider adapter for **listing and replying to Merge Request review comments** on
GitLab via the `glab` CLI. Used during Phase 7 (`/dev-workflow review-response`) when
`provider-config.md` specifies `Git Provider: glab-cli`.

GitLab structures inline review comments as **discussions** (threads) under an MR. Each
discussion has a `resolved` boolean and contains one or more notes. The CLI shells out to
the GitLab REST API via `glab api`.

## Operations

| Capability | Primitive | Path |
|------------|-----------|------|
| `pr.find_for_branch` | `glab mr list` | CLI |
| `pr.list_review_comments` | `glab api projects/.../merge_requests/<iid>/discussions` | CLI / REST |
| `pr.reply_to_review_comment` | `glab api projects/.../merge_requests/<iid>/discussions/<id>/notes` | CLI / REST |

## Prerequisites

```bash
glab --version          # glab CLI present
glab auth status        # authenticated session
```

If `glab auth status` fails, prompt the user to run `glab auth login` before continuing.

## Find Open MR for a Feature Branch (`pr.find_for_branch`)

```bash
glab mr list \
  --repo <group>/<project> \
  --source-branch <feature-branch> \
  --state opened \
  --output json \
  --per-page 1
```

Empty JSON array `[]` means no open MR for the branch. Parse the first element to
capture `iid` and `web_url`.

Note: GitLab uses `iid` (project-scoped) — NOT the global `id`. The CLI and REST
endpoints under `projects/<id>/merge_requests/<iid>` accept the IID.

## List Unresolved Discussions (`pr.list_review_comments`)

```bash
glab api "projects/<URL-encoded-group/project>/merge_requests/<iid>/discussions?per_page=100"
```

The `<group>/<project>` path must be URL-encoded (`/` → `%2F`). The CLI accepts the
raw form too — `glab api projects/:group/:project/...` — but `:fullpath` substitution
varies by CLI version; prefer explicit URL encoding for stability.

The response is an array of discussions. Each has:

- `id` — discussion (thread) ID, a hex string
- `individual_note: false` for review threads, `true` for floating MR notes
- `notes` — array of notes, each with `id`, `author.username`, `body`, `created_at`,
  `system: true|false`, `resolvable: true|false`, `resolved: true|false`,
  `position.new_path`, `position.new_line`

**Filter rules:**

- Skip discussions where every note has `system: true` (these are MR state changes
  posted by GitLab itself).
- Skip discussions where every retained note's `author.username` matches the bot
  filter (see below).
- For each remaining discussion, check the **first** note's `resolved` field. If the
  thread is resolved, skip — Phase 7 processes unresolved threads only.

For each retained discussion, capture:

- `thread_id` ← discussion `id` (hex string — REST path component for replies)
- `note_id` ← `notes[0].id` (used internally for state-tracking only)
- `file` ← `notes[0].position.new_path` (or `null` for floating MR notes)
- `line` ← `notes[0].position.new_line`
- `author` ← `notes[0].author.username`
- `body` ← `notes[0].body`

## Reply to a Discussion (`pr.reply_to_review_comment`)

```bash
glab api \
  --method POST \
  "projects/<URL-encoded-group/project>/merge_requests/<iid>/discussions/<thread-id>/notes" \
  --field "body=Addressed in commit <sha>: <one-sentence summary>"
```

For a floating MR note (no discussion thread — pure MR conversation), reply with a
new MR note:

```bash
glab mr note <iid> --repo <group>/<project> \
  --message "Re #<original-note-id>: addressed in commit <sha>: <summary>"
```

## Thread ID Persistence

The orchestrator stores the discussion `id` in the tracker's `Notes` column as
`thread_id=<hex>`. For floating MR notes, store `thread_id=general:<note-id>` so
Phase 9 routes to `glab mr note` instead of the `/discussions/.../notes` endpoint.

## Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| `pr.find_for_branch` | ✅ | `glab mr list --source-branch <branch> --state opened` |
| `pr.list_review_comments` | ✅ | REST `/discussions` endpoint via `glab api`; `resolved` flag native |
| `pr.reply_to_review_comment` | ✅ | REST `/discussions/<id>/notes` for threads; `glab mr note` for floating notes |

## Bot Comment Filter

Skip discussions authored exclusively by these usernames:

```
gitlab-bot
project_<N>_bot          # GitLab project access tokens
ghost-user
codeclimate
sonarcloud
```

`system: true` notes are filtered separately (MR state changes by GitLab itself).

## Provider-Specific Quirks

1. **`iid` vs `id`.** GitLab has two MR IDs: the global `id` and the project-scoped
   `iid`. URLs and REST paths use `iid`. The MCP adapter (when present) is consistent
   on this point.
2. **Discussion vs note.** A discussion is a thread; a note is a single message inside
   it. Reviews always create discussions; the first note carries the original review
   remark.
3. **Resolved flag on the discussion, not the note.** Don't filter on `notes[0].resolved`
   alone — older API versions only set `resolved` on the discussion object. Check both
   if the discussion-level field is absent.
4. **URL-encoding the project path.** `glab api projects/<group>/<project>/...` may
   work in some CLI versions but fail in others. Always URL-encode the path
   (`<group>%2F<project>`) for stability across versions.
