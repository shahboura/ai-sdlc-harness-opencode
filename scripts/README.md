# Hook scripts — fail policy

Every hook script declares whether it fails **closed** (block the tool call
when the parser can't make sense of input) or **open** (advise and exit 0).
The policy is stated in the script's header banner and re-summarised here so
the inventory is reviewable at a glance.

| Script | Event | Matcher | Policy | Purpose |
|--------|-------|---------|--------|---------|
| [`_hook-lib.sh`](_hook-lib.sh) | (sourced) | — | — | Shared primitives: source-time python probe, payload reader, workspace detection, exit helpers. |
| [`_hook_field.py`](_hook_field.py) | (helper) | — | — | Extract a dotted-path field from a JSON payload file. Joins list-shaped `tool_response` text blocks. |
| [`_git_argparse.py`](_git_argparse.py) | (helper) | — | — | `shlex`-based parser for `git commit` invocations. Handles `-C`, `-c`, env-var prefixes, chained commands, multi-`-m`, `--message=`, `-F`, `--amend`, `--fixup`/`--squash`, heredoc bodies. |
| [`_sensitive_patterns.py`](_sensitive_patterns.py) | (helper) | — | — | Single source of truth for the sensitive-file deny-list used by both write-side and Bash-side guards. |
| [`_validate_commit_msg.py`](_validate_commit_msg.py) | (helper) | — | fail-closed | Validates the reconstructed commit message against the harness convention. |
| [`_bash_write_guard.py`](_bash_write_guard.py) | (helper) | — | mixed | fail-closed on recognized writes, fail-open on unparseable Bash. |
| [`_sensitive_file_guard.py`](_sensitive_file_guard.py) | (helper) | — | fail-closed | Pattern-matches Write/Edit/MultiEdit/NotebookEdit targets against the shared deny-list. |
| [`_tracker_transition_guard.py`](_tracker_transition_guard.py) | (helper) | — | fail-closed | Applies the edit in-memory to the on-disk tracker, diffs task-row statuses by ID, validates every transition. |
| [`_tracker_update_reminder.py`](_tracker_update_reminder.py) | (helper) | — | fail-open | Emits `hookSpecificOutput.additionalContext` when the tracker doesn't match the agent's verdict. |
| [`_agent_status_check.py`](_agent_status_check.py) | (helper) | — | mixed | fail-closed when response extractable; fail-open otherwise. |
| [`_squash_merge_verify.py`](_squash_merge_verify.py) | (helper) | — | fail-open | Detects squash-merge form, runs `git diff` to verify conflicts/staged changes. |
| [`validate-commit-msg.sh`](validate-commit-msg.sh) | `PreToolUse` | `Bash` | **fail-closed** | Block `git commit` invocations whose message doesn't match `#<STORY> #<TASK>: …` (with TDD / test-harden / autosquash exceptions). If the parser can't reconstruct the message, the commit is refused. |
| [`bash-write-guard.sh`](bash-write-guard.sh) | `PreToolUse` | `Bash` | **mixed** | Block Bash-driven writes to `ai/`, sensitive paths, or role-forbidden targets (when `agent_type` is in the payload). |
| [`sensitive-file-guard.sh`](sensitive-file-guard.sh) | `PreToolUse` | `Write\|Edit\|MultiEdit\|NotebookEdit` | **fail-closed** | Block writes/edits/notebook edits whose target matches the shared sensitive-file deny-list (`.env*`, `*.pem`, `id_rsa*`, `*.tfstate*`, `.netrc`, `.npmrc`, `credentials*`, `secrets.*`, etc.). Paired with `bash-write-guard.sh` for the Bash side. |
| [`tracker-transition-guard.sh`](tracker-transition-guard.sh) | `PreToolUse` | `Write\|Edit\|MultiEdit` | **fail-closed** | Apply the edit in-memory and validate every status transition by task ID. Multi-row edits validate every row, not just the first. Whole-file Writes covered. |
| [`tracker-metrics-guard.sh`](tracker-metrics-guard.sh) | `PreToolUse` | `Edit` | **fail-open (advisory)** | Warn on malformed metric dates without blocking. |
| [`squash-merge-verify.sh`](squash-merge-verify.sh) | `PostToolUse` | `Bash` | **fail-open (advisory)** | Surface conflicts and empty squash-merge results. Handles `git -C`, `cd && git`, `git -c`, env-var prefixes. |
| [`tracker-update-reminder.sh`](tracker-update-reminder.sh) | `PostToolUse` | `Agent` | **fail-open (advisory)** | Remind the orchestrator to update the tracker after a subagent verdict. List-shaped `tool_response` handled; tracker selected by story-ID filename match. |
| [`agent-status-check.sh`](agent-status-check.sh) | `SubagentStop` | _empty_ | **fail-closed** when response extractable | Verify subagent ended with a `📋 AGENT STATUS` block AND the block contains a non-empty `Outcome:` or `Verdict:`. |
| [`tester-activation-guard.sh`](tester-activation-guard.sh) | `SubagentStart` | `tester` | **fail-closed** | Reject tester spawns when no failing tests are due. |
| [`stop-failure-marker.sh`](stop-failure-marker.sh) | `StopFailure` | _empty_ | fail-open (advisory) | Drop a `.stop-failure` marker file under the workspace's `.claude/context/` (workspace walk-up — no cwd dependency). |
| [`stop-failure-recovery.sh`](stop-failure-recovery.sh) | `UserPromptSubmit` | _empty_ | fail-open (advisory) | On the first prompt after a `StopFailure`, delete the marker and emit recovery instructions. Walks up to find the workspace. |

## Adding a new hook

1. Pick a policy. Parsers fail closed; advisors fail open.
2. Source `_hook-lib.sh`:
   ```bash
   DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   . "$DIR/_hook-lib.sh"
   ```
3. Use `hook_init` to consume stdin, `hook_field` to extract payload fields,
   `hook_block` / `hook_advise` to exit. Don't roll your own JSON parsing.
4. Add a banner comment declaring `event`, `matcher`, `scope`, `blocking`,
   and `policy`. The harness uses these for the table above; keep them
   accurate.
5. Update this README's table.

## Workspace gate

Hooks check `hook_in_workspace` before doing anything. The marker is
`.claude/context/provider-config.md` somewhere up the directory tree from
cwd. Outside an initialised workspace, every hook short-circuits to exit 0.

## Subagent identity

`bash-write-guard.sh` reads `agent_type` from the payload — Claude Code's
documented PreToolUse field that is present only when the hook fires
inside a subagent call. The value may be namespaced
(`ai-sdlc-harness:reviewer:reviewer`); the guard normalises to the last
`:`/`/` segment before matching. Older/alternate field names
(`subagent_name`, `agent_name`, …) are accepted as a defensive fallback.
If no identity is detectable, identity-dependent rules are skipped — the
always-on rules (no writes to `ai/`, no writes to sensitive files) still
apply.

## Testing

Each script that handles payload parsing has tests under
[`../tests/hooks/`](../tests/hooks/). The test harness pipes canned JSON to
the script and asserts exit code + stderr. Run all tests:

```bash
./tests/hooks/run.sh
```
