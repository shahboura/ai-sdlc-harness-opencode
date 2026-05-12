# Hook scripts — fail policy

Every hook script declares whether it fails **closed** (block the tool call
when the parser can't make sense of input) or **open** (advise and exit 0).
The policy is stated in the script's header banner and re-summarised here so
the inventory is reviewable at a glance.

| Script | Event | Matcher | Policy | Purpose |
|--------|-------|---------|--------|---------|
| [`_hook-lib.sh`](_hook-lib.sh) | (sourced) | — | — | Shared primitives: python probe, payload reader, workspace detection, exit helpers. |
| [`_hook_field.py`](_hook_field.py) | (helper) | — | — | Extract a dotted-path field from a JSON payload file. Joins list-shaped `tool_response` text blocks. |
| [`_git_argparse.py`](_git_argparse.py) | (helper) | — | — | `shlex`-based parser for `git commit` invocations. Handles `-C`, `-c`, env-var prefixes, chained commands, multi-`-m`, `--message=`, `-F`, `--amend`, heredoc bodies via `$(cat <<TAG ... TAG)`. |
| [`_validate_commit_msg.py`](_validate_commit_msg.py) | (helper) | — | fail-closed | Validates the reconstructed commit message against the harness convention. |
| [`_bash_write_guard.py`](_bash_write_guard.py) | (helper) | — | fail-closed | Inspects Bash commands for writes to `ai/`, sensitive files, or role-forbidden paths. |
| [`validate-commit-msg.sh`](validate-commit-msg.sh) | `PreToolUse` | `Bash` | **fail-closed** | Block `git commit` invocations whose message doesn't match `#<STORY> #<TASK>: …` (with TDD / test-harden / autosquash exceptions). If the parser can't reconstruct the message, the commit is refused. |
| [`bash-write-guard.sh`](bash-write-guard.sh) | `PreToolUse` | `Bash` | **fail-closed** | Block Bash-driven writes to harness-owned (`ai/**`) or sensitive paths; enforce read-only on reviewer (when subagent identity is in the payload). |
| [`sensitive-file-guard.sh`](sensitive-file-guard.sh) | `PreToolUse` | `Write\|Edit` | fail-closed | Block `Write`/`Edit` on `*.env`/`*.pem`/etc. (paired with `bash-write-guard.sh` for the Bash side). |
| [`tracker-transition-guard.sh`](tracker-transition-guard.sh) | `PreToolUse` | `Edit` | fail-closed | Reject illegal task-tracker status transitions. |
| [`tracker-metrics-guard.sh`](tracker-metrics-guard.sh) | `PreToolUse` | `Edit` | **fail-open (advisory)** | Warn on malformed metric dates without blocking. |
| [`squash-merge-verify.sh`](squash-merge-verify.sh) | `PostToolUse` | `Bash` | **fail-open (advisory)** | Surface conflicts after a squash-merge attempt. |
| [`tracker-update-reminder.sh`](tracker-update-reminder.sh) | `PostToolUse` | `Agent` | **fail-open (advisory)** | Remind the orchestrator to update the tracker after a subagent verdict. |
| [`agent-status-check.sh`](agent-status-check.sh) | `SubagentStop` | _empty_ | fail-open (advisory) | Verify subagent ended with a `📋 AGENT STATUS` block. |
| [`tester-activation-guard.sh`](tester-activation-guard.sh) | `SubagentStart` | `tester` | **fail-closed** | Reject tester spawns when no failing tests are due. |
| [`stop-failure-recovery.sh`](stop-failure-recovery.sh) | `UserPromptSubmit` | _empty_ | fail-open (advisory) | Surface recovery instructions when an API stop-failure marker is present. |

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
