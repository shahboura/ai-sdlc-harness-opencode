# Permissions Proposal (Step 3c)

After [language discovery](language-discovery.md) Phase 3 negotiate completes for **all repos**, `/init-workspace` proposes Bash permissions so the agents can run discovered commands without interactive prompts at runtime, AND auto-adds Read pre-approvals for the harness plugin files and every repo path so the orchestrator and agents can read trusted locations without per-file prompts.

The two flows share `.claude/settings.json` and the same idempotent JSON round-trip, but Read pre-approvals require **no human approval** — they cover paths the user has already authorised by configuring the workspace (the plugin they installed; the repos they registered in `repos-paths.md`).

## Procedure (Bash — interactive)

1. **Collate command heads.** For each repo, take the first whitespace-separated token of every command field: `restore_command`, `build_command`, `test_command`, `coverage_command`, `format_command`. Include wrapper scripts (`./mvnw`, `./gradlew`) as their own heads. For wrappers, use the bare wrapper name (e.g. `mvnw`, `gradlew`).

2. **Convert to `Bash(<cmd>:*)` format** and deduplicate across repos. Record which repos each command belongs to for the presentation.

3. **Present the proposal** to the user:

   ```
   I need to pre-approve these Bash commands so agents run them without
   prompting you during the workflow. Review and approve:

     [x] Bash(poetry:*)       — used for: build, test, coverage in AuthService
     [x] Bash(pytest:*)       — used for: test in AuthService
     [x] Bash(ruff:*)         — used for: format in AuthService
     [x] Bash(go:*)           — used for: build, test, format in PaymentGateway
     [x] Bash(./mvnw:*)       — used for: build, test in OrderService

   Type 'all' to approve, 'none' to skip (you'll be prompted at runtime),
   or a comma-separated list to approve specific commands.
   ```

4. **On approval, structured-edit `settings.json`:**
   - Read the JSON file.
   - Modify `permissions.allow` (an array): append each approved entry that is not already present. **Preserve all existing entries.** Do not rewrite the file as a string — round-trip through JSON parse/stringify.
   - Write the file back.

5. **Record the full proposed list** in `language-config.md:permissions_requested` for each repo (even if the user only approved a subset — the record reflects what was needed, not what was granted).

6. **Document the refresh flag.** Tell the user that `/init-workspace --refresh-permissions` re-proposes only Step 3c, without re-running language discovery.

7. **Session restart notice.** Tell the user:
   > "⚠️ I've updated `.claude/settings.json` with the new Bash permissions. Claude Code may not hot-reload permissions mid-session — please restart your session if you hit unexpected permission prompts during `/dev-workflow`."

## Fallback

If the user declines (`none`), they will hit interactive permission prompts at runtime. That's fine for foreground commands, but background agents can't prompt.

## Procedure (Read — automatic, no prompt)

<!-- Reason: agents and the orchestrator are constantly prompted to confirm reads on the plugin's own
     skill / command / context / agent files and on the source files inside the user's repos. Both
     locations are already trusted by virtue of installation / configuration — the plugin was installed
     by the user, and the repo paths were registered by the user in repos-paths.md. The prompts add
     friction without adding safety, so init-workspace auto-adds pre-approvals to settings.json. -->

Immediately after Step 3c.1 (Bash) completes, `/init-workspace` auto-adds two classes of `Read(...)` entries to `.claude/settings.json` without prompting. The paths are already trusted: the plugin is the user's chosen install, and the repos are paths the user registered.

### 1. Plugin file reads

Add this single entry (if not already present) to `permissions.allow`:

```
Read(~/.claude/plugins/**)
```

This covers the harness plugin wherever Claude Code installed it — under `cache/`, under `marketplaces/<name>/`, or any future install path Claude Code adds. Per the Claude Code permission grammar, `~` expands to the user's home directory; the trailing `/**` is recursive (gitignore semantics). `${CLAUDE_PLUGIN_ROOT}` is **not** expanded inside `permissions.allow`, so the literal `~/.claude/plugins/**` form is the durable spelling.

### 2. Repo file reads

For each `<repo-name>: <repo-path>` entry in `repos-paths.md`, add one entry to `permissions.allow`:

```
Read(//<repo-path>/**)
```

The `//` prefix is the Claude Code grammar for **filesystem-absolute** paths (a single leading `/` is interpreted as project-root-relative). The `repo-path` value in `repos-paths.md` is already an absolute path that starts with `/`, so the rendered allow entry is two consecutive slashes: e.g. for `AuthService: /Users/me/Work/AuthService` the entry is `Read(//Users/me/Work/AuthService/**)`.

Use the same JSON round-trip as Step 3c.1: read, append-if-absent into `permissions.allow`, preserve all existing entries, write.

### 3. Idempotency and refresh

- The auto-add path is **idempotent**. If a Read entry already exists with an identical string, it is skipped (no duplicate). This makes the auto-add safe on every `/init-workspace` invocation, including `--refresh-permissions`.
- The auto-add does NOT remove existing Read entries even when a repo is dropped from `repos-paths.md`. Stale entries are harmless (they pre-approve reads on paths that no longer exist) and removing them would conflict with the user's manual additions. If the user wants a clean slate they can edit `.claude/settings.json` directly.
- `--refresh-permissions` re-runs both Step 3c.1 (Bash, interactive) and Step 3c.2 (Read, automatic). New repos added to `repos-paths.md` since the last init pick up their `Read(//<path>/**)` entry.

### 4. Why not prompt for Read approvals?

Read on a path the user has already registered (their own plugin install; their own repo checkouts) is the lowest-risk tool operation in the harness's surface — it cannot modify state, cannot leak data to third parties, and cannot run code. Prompting adds workflow friction (background agents can't respond, foreground agents stall the loop) without giving the user a meaningful decision. The Bash proposal in Step 3c.1 prompts because each command head is a distinct execution-risk decision; Read approval on registered paths is not.

## Preflight Check

Phase 3 of `/dev-workflow` performs a preflight check that all required permissions (the `permissions_requested` list) are present in `settings.json` BEFORE launching any background agent lanes. Missing permissions cause a hard-fail with an actionable message ("run `/init-workspace --refresh-permissions` and restart your session"), not an interactive prompt — because background agents cannot prompt the user.
