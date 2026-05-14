---
name: story-intake
description: >
  Pull and analyse a User Story / Issue from the configured work item provider.
  Use when starting Phase 1 of the development workflow — ingesting requirements,
  parsing acceptance criteria, and surfacing clarifying questions before planning begins.
  Supports ADO, Jira, GitLab, GitHub, Zoho, and local-markdown via provider adapters.
allowed-tools: Bash, Read, Grep, mcp__azure-devops__*, mcp__jira__*, mcp__gitlab__*, mcp__github__*, mcp__zoho__*
argument-hint: "<Work-Item-ID> [project-name]"
---

# Story Intake (Provider-Agnostic)

## Purpose

Pull a User Story / Issue from the configured work item provider, parse its contents
thoroughly, and surface any ambiguities or missing information as clarifying questions
for the human user.

## Arguments

- **First argument** (required): The Work Item / Issue ID
  - ADO: integer (e.g., `123456`)
  - Jira: issue key (e.g., `PROJ-123`)
  - GitLab: issue IID (e.g., `123`)
  - GitHub: issue number (e.g., `123`)
  - Zoho: mail group task ID (e.g., `1234567890`)
  - local-markdown: file path to a `.md` story file
    (e.g., `./stories/auth-story.md`, absolute or relative to cwd)
- **Second argument** (optional): Project identifier. Provider-specific default from provider-config.md.
  Not applicable for `local-markdown` (the file path is fully qualifying).

Parse `$ARGUMENTS` to extract these values.

## Provider Resolution

1. **Read `.claude/context/provider-config.md`** to determine the active work item provider.
2. **Read the matching provider adapter** from `skills/providers/<provider>/work-items.md`.
3. Use the adapter's tool reference for all MCP calls in this skill.

If `provider-config.md` does not exist, inform the user:
> "Provider configuration not found. Please run `/init-workspace` first to select your
> work item and git providers."

## Steps

### 1. Fetch the Work Item

Use the **fetch work item** tool from the active provider adapter.

**ADO example:**
```
mcp__azure-devops__wit_get_work_item(id=$ID, project=$PROJECT, expand="relations")
```

**Jira example:**
```
mcp__jira__get_issue(issueIdOrKey=$ID, expand="renderedFields")
```

**GitLab example:**
```
mcp__gitlab__get_issue(projectId=$PROJECT, issueIid=$ID)
```

**GitHub example:**
```
mcp__github__get_issue(owner=$OWNER, repo=$REPO, issueNumber=$ID)
```

**local-markdown example:**
```
Read(file_path=$ID)   # $ID is the file path passed as the first argument
```

For `local-markdown`, the work item ID is the file path itself (e.g.,
`./stories/auth-story.md`). Validate the file exists before reading; if it
does not, stop and inform the user — do not create it. See
`skills/providers/local-markdown/work-items.md` for the full adapter,
including how H2 sections are mapped to story fields.

### 1b. Fetch Related Context (Comments + Parent)

After the main work item lands, pull two more pieces of context — both bounded so the
fetch cost stays predictable.

**Comments (always, when the adapter declares `work_item.list_comments: ✅`).**

Fetch the **last 20 comments** in chronological order (or all of them if there are
fewer). Skip if the adapter declares this capability as `❌` / unsupported (e.g.
local-markdown) — surface a one-line note in the requirements summary that comments
were not pulled.

Per-provider tools (canonical names from the adapters):

- ADO: `mcp__azure-devops__wit_list_work_item_comments(id=$ID, project=$PROJECT, top=20)`
- Jira: `mcp__jira__get_issue_comments(issueIdOrKey=$ID, limit=20)`
- GitLab: `mcp__gitlab__list_issue_notes(projectId=$PROJECT, issueIid=$ID, per_page=20)`
- GitHub: `mcp__github__list_issue_comments(owner=$OWNER, repo=$REPO, issueNumber=$ID, perPage=20)`
- local-markdown: no comments concept — skip.

Bot comments (system updates, build/test postings, CI summaries) should be filtered
out before display. The retained comments inform Step 3 (gap analysis) and are
referenced verbatim in Clarifications where they answer questions the description
left open.

**Parent (one level only, when the work item declares one).**

Inspect the work item's response for a parent reference:

- ADO: scan `relations[]` for `rel == "System.LinkTypes.Hierarchy-Reverse"` → fetch
  the parent work item by ID.
- Jira: read the `fields.parent` field (epic link or hierarchy parent) → fetch the
  parent via `mcp__jira__get_issue`.
- GitLab / GitHub: there is no native parent/child — skip unless the description
  contains a `tracked-by: #N` line, in which case fetch the referenced issue.
- local-markdown: no parent concept — skip.

If a parent is found, fetch **only its title and description** (one level deep —
do not recurse into the parent's parent). Hold both in context for Step 2's
"Linked Items" rendering and Step 3's gap analysis (parent context often resolves
ambiguity in the child's AC).

### 1c. Closed-State Guard

If the work item's State / Status maps to one of the closed/done/resolved family
(ADO `Closed` / `Resolved` / `Removed`; Jira `Done` / `Resolved` / `Cancelled`;
GitLab / GitHub `closed`; local-markdown — N/A), **stop and confirm with the human
before proceeding**:

```
## Closed Story Detected

Work item <ID> is in state `<state>` (closed/done/resolved). Continuing intake
will produce a Requirements Summary for a story that already shipped, which
usually indicates:
  - The wrong ID was passed.
  - You're intentionally re-opening or reviewing a past story.

Options:
  [1] Continue anyway — proceed to Step 2.
  [2] Stop — abort intake. (No artefacts will be written.)

Type 1 or 2.
```

On `[2]`, end the invocation with `Outcome: BLOCKED` and no requirements summary.

### 2. Extract and Display

Using the field mappings from the provider adapter, extract and present:
- Title
- Description (normalize to markdown regardless of source format)
- Acceptance Criteria (extract from dedicated field or parse from description body)
- State / Status
- Area / Project / Labels
- Iteration / Sprint / Milestone
- Linked Items (parent — from Step 1b — plus children, related, epics)
- Attachments (list filenames and types)
- Comments (from Step 1b — last 20 non-bot, chronological; or `(none / not supported)`
  if the adapter does not declare `work_item.list_comments`)

**Provider-specific extraction notes:**
- **ADO**: Description and AC are HTML → convert to markdown
- **Jira**: Description is ADF → use renderedFields for HTML → convert to markdown.
  AC may be a custom field — check provider-config.md for the field ID.
- **GitLab / GitHub**: Description is markdown. AC is typically embedded as a task list
  section in the description body — parse the `## Acceptance Criteria` section or
  equivalent pattern documented in provider-config.md.
- **local-markdown**: Description is markdown — no conversion needed. Title is the
  first H1; Description is the prose before the first H2; AC, Out of Scope, Open
  Questions, and Technical Notes come from their respective `## ...` sections.
  Unstructured files (no headings) are treated as description-only.

### 3. Analyse for Gaps

- Are all acceptance criteria testable and unambiguous?
- Are there undefined terms or business concepts that need clarification?
- Are there implicit dependencies on other systems or services?
- Are there missing error/edge case specifications?
- Is the scope clear — what is explicitly OUT of scope?

### 4. Clarify

If ANY gaps found, present numbered clarifying questions to the human user.
- Wait for answers before proceeding.
- Repeat until confident all requirements are clear.

### 5. Output Requirements Summary

The Acceptance Criteria block uses a **canonical schema** so downstream consumers
(`plan-generator` Step 0a counts ACs from this single shape; the Reviewer's spec
checks reference each AC by number) can parse the output regardless of which
provider it came from.

**Canonical AC format:**

```
### Acceptance Criteria (Validated)
1. <plain assertion — one sentence per AC>
   - Given: <precondition — only if the source supplied one>
   - When: <action — only if the source supplied one>
   - Then: <observable outcome — only if the source supplied one>
2. <plain assertion>
...
```

Rules for the AC list:

- **Numbered, starting at 1.** Each item is a single plain-language assertion
  ending in a period.
- **Given / When / Then sub-fields are optional** — emit them ONLY when the
  source AC was already structured that way (e.g. Jira issues using Gherkin,
  ADO criteria written in BDD form). Do not synthesise Given/When/Then from
  prose — that introduces interpretation the human did not authorise.
- **No nested lists, no AC-ID prefixes (`AC-1:`), no sub-bullets beyond
  Given/When/Then.** Plan-generator's parsing relies on the numbered shape.
- **No empty entries.** An AC that the human marked TBD during Step 4
  clarification must be either resolved or struck — do not pass an unresolved
  AC into the summary.

Full summary template:

```markdown
## Requirements Summary — $ID

**Title**: ...
**Story/Issue ID**: $ID
**Provider**: <ado | jira | gitlab | github | zoho | local-markdown>
**Parent**: <parent ID + title, or "(none)" if no parent was fetched in Step 1b>
**State**: <open | in-progress | closed-confirmed>   <!-- "closed-confirmed" only after the Step 1c override -->
**Sprint/Milestone**: ...

### Description
<normalised markdown description>

### Acceptance Criteria (Validated)
<numbered list per the canonical schema above>

### Clarifications Received
- Q1: ... → A1: ...

### Dependencies
- ...

### Out of Scope
- ...

### Comments Reviewed (Last <N>)
<one-line-per-comment summary; or "(adapter does not support comments)" if Step 1b skipped this>

### Ready for Planning: ✅ YES / ❌ NO (reason)

---
🤖 Generated with [Claude Code](https://claude.ai/claude-code)
```

## Rules

- **Never assume.** If something is unclear, ask.
- Do not proceed to planning until the summary shows "Ready for Planning: ✅ YES".
- This skill is read-only with respect to the codebase — it only reads provider data.
- Always read the provider adapter for exact tool names and parameter mappings before
  making any MCP calls.
