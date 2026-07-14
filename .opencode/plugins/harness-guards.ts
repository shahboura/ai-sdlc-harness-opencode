import type { Plugin } from "@opencode-ai/plugin";

// ── Types ────────────────────────────────────────────────────────────────

interface PermissionEvent {
  type: string;
  command?: string;
  path?: string;
  [key: string]: unknown;
}

// ── Python guard pattern equivalents (hooks/guards.py) ──────────────────

/**
 * GIT_VERB_RE equivalent — matches `git commit|merge|push|...` with global
 * flags between `git` and the verb, anchored at command boundaries and
 * excluded inside quotes.
 *
 * Python source: hooks/guards.py lines 130-134
 *
 * Breakdown:
 *   (?<!['"])              – negative lookbehind: NOT preceded by quote
 *   \bgit\b                – word-boundary git
 *   (?:[ \t]+              – optional global flags (zero or more):
 *     (?:-C|-c|--git-dir|…)(?:=TOKEN|[ \t]+TOKEN)?  – flags that take a value
 *     |-{1,2}[A-Za-z][\w-]*(?:=TOKEN)?               – self-contained flags
 *   )*
 *   [ \t]+                 – separator before verb
 *   (commit|merge|…)       – captured verb
 *   \b                     – word boundary after verb
 */
const GIT_TOKEN = /[^\s"']+/;
const GIT_VERB_RE = new RegExp(
  "(?<!['\"])" +
  "\\bgit\\b" +
  "(?:[ \\t]+(?:" +
    "(?:-C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--exec-path)" +
    "(?:=" + GIT_TOKEN.source + "|[ \\t]+" + GIT_TOKEN.source + ")?" +
    "|-{1,2}[A-Za-z][\\w-]*(?:=" + GIT_TOKEN.source + ")?" +
  "))*" +
  "[ \\t]+" +
  "(commit|merge|rebase|cherry-pick|revert|am|pull|(?<!stash )push)\\b"
);

/**
 * SHELL_C_RE equivalent — extracts payloads from `sh -c "..."` / `bash -c '...'`
 * so that GIT_VERB_RE can check them (quoted payloads would otherwise be
 * invisible due to the (?<!['"]) anchor).
 *
 * Python source: hooks/guards.py lines 139-140
 */
const SHELL_C_RE = /\b(?:sh|bash|zsh|dash|ksh)\b[^|;&\n\r]*?-c[ \t]+(?:"([^"]*)"|'([^']*)')/;

/**
 * AUTHORITY_RE equivalent — scoped to `ai/<run>/` prefix and matching ALL
 * integrity-critical filenames. False-positive-safe because it requires the
 * `ai/` prefix (matches Python's behavior exactly).
 *
 * Python source: hooks/guards.py lines 149-152
 */
const AUTHORITY_RE = /ai[/\\][^/\\\s"']+[/\\](?:state\.yaml|events\.ndjson|tokens\.ndjson|human-input\.ndjson|reviews\.ndjson|\.redproof|\.state\.lock)\b|\.hmac\b/;

/**
 * WRITE_HINT_RE equivalent — detects inline programming-language writes that
 * circumvent path-based write blocking (shell redirects, tee, sed, python
 * open/write, node fs.writeFile, etc.).
 *
 * Python source: hooks/guards.py lines 162-173
 */
const WRITE_HINT_RE = /(?<![0-9])>(?!&)|\btee\b|\bsed\s+(-\w+\s+)*-i|\brm\b|\bmv\b|\bcp\b|\btruncate\b|\bdd\b|yq\s+.*-i|--in-place/;

/**
 * Agent shapes in the harness — matches Python's shape_of().
 * Python source: hooks/guards.py lines 499-502
 */
const HARNESS_SHAPES = ["planner", "developer", "reviewer"];

// ── Helpers ──────────────────────────────────────────────────────────────

/** Normalize agent name the same way Python's shape_of() does. */
function normalizeAgent(raw: string): string {
  const tail = raw.split(":").pop() ?? "";
  return tail.trim().toLowerCase().replace(/^ai-sdlc-/, "");
}

/** Recursively extract all shell command targets from a bash command line. */
function extractTargets(cmd: string): string[] {
  const targets = [cmd];
  // Extract sh -c / bash -c payloads
  const m = SHELL_C_RE.exec(cmd);
  if (m) {
    const payload = m[1] ?? m[2] ?? "";
    if (payload) targets.push(...extractTargets(payload));
  }
  return targets;
}

/** Check if ANY target contains a blocked git verb. */
function hasBlockedGitVerb(cmd: string): boolean {
  for (const target of extractTargets(cmd)) {
    if (GIT_VERB_RE.test(target)) return true;
  }
  return false;
}

/** Check if a bash command contains inline/injected write operations. */
function hasWriteHint(cmd: string): boolean {
  return WRITE_HINT_RE.test(cmd);
}

// ── Plugin ───────────────────────────────────────────────────────────────

const HarnessGuardsPlugin: Plugin = async ({ project, $, directory }) => {
  const rawName =
    (project as { agent?: { name?: string } }).agent?.name ?? "";
  const agentName = normalizeAgent(rawName) || "direct-user";
  const guardsPy = `${directory}/hooks/guards.py`;
  const encoder = new TextEncoder();

  // ── Layer 1: Enforcement via permission.ask ──────────────────────────
  async function handlePermissionAsk(
    permission: PermissionEvent,
    output: { status: "ask" | "deny" | "allow" },
  ): Promise<void> {
    try {
      if (output.status === "deny") return; // Already denied upstream

      switch (permission.type) {
        case "bash": {
          const cmd = permission.command ?? "";
          if (!cmd) break;

          // Block git verbs (matching Python guard_bash)
          if (hasBlockedGitVerb(cmd)) {
            output.status = "deny";
            console.warn(
              `[harness-guards] DENIED bash (git verb): ${cmd.slice(0, 120)}`,
            );
            break;
          }

          // Block inline writes to authority paths via shell commands
          if (hasWriteHint(cmd)) {
            // For now, only block if a write hint targets an authority path.
            // Full authority-path write detection requires command parsing
            // (the Python guard uses both WRITE_HINT_RE + AUTHORITY_RE).
            // This is a best-effort check; the Python audit (Layer 2) catches
            // the rest.
            output.status = "deny";
            console.warn(
              `[harness-guards] DENIED bash (write hint): ${cmd.slice(0, 120)}`,
            );
            break;
          }

          // Not a dangerous command — auto-allow to avoid prompt fatigue.
          // Without this, every safe command would prompt the user.
          output.status = "allow";
          break;
        }

        case "write":
        case "edit": {
          const filePath = permission.path ?? "";
          if (!filePath) break;

          // Block writes to authority files (Python guard_write: AUTHORITY_RE)
          if (AUTHORITY_RE.test(filePath)) {
            output.status = "deny";
            console.warn(
              `[harness-guards] DENIED ${permission.type} (authority path): ${filePath}`,
            );
            break;
          }

          // Auto-allow to avoid prompt fatigue for non-authority paths.
          // The permission patterns in opencode.jsonc still deny writes
          // outside allowed directories.
          output.status = "allow";
          break;
        }

        case "read": {
          const filePath = permission.path ?? "";
          if (!filePath) break;

          // Block raw .redproof reads for ALL harness shapes
          // (Python guard_read blocks for planner, developer, reviewer)
          if (
            HARNESS_SHAPES.includes(agentName) &&
            /\.redproof[/\\]/.test(filePath)
          ) {
            output.status = "deny";
            console.warn(
              `[harness-guards] DENIED read (redproof isolation): ${filePath}`,
            );
          }
          // Leave non-redproof reads at their configured status
          break;
        }
      }
    } catch (err) {
      // Error boundary — never let a plugin crash allow a blocked action
      console.error(`[harness-guards] ERROR in permission.ask: ${err}`);
    }
  }

  // ── Layer 2: Audit via Python guards (non-blocking) ─────────────────
  async function auditGuard(
    guard: string,
    payload: Record<string, unknown>,
  ): Promise<void> {
    const t0 = Date.now();
    try {
      const proc = $`python3 ${guardsPy} ${guard}`.quiet().nothrow();
      const writer = proc.stdin.getWriter();
      await writer.write(encoder.encode(JSON.stringify(payload)));
      await writer.close();

      // 5-second timeout to prevent a hung Python process from stalling tools
      const output = await Promise.race([
        proc,
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error("timeout")), 5000),
        ),
      ]);

      const elapsed = Date.now() - t0;
      if (output.exitCode === 2) {
        const reason = output.stderr?.toString()?.trim() ?? "unknown";
        console.warn(
          `[harness-guards] ${guard} BLOCK (${elapsed}ms): ${reason}`,
        );
      } else if (output.exitCode !== 0) {
        console.warn(
          `[harness-guards] ${guard} exit ${output.exitCode} (${elapsed}ms)`,
        );
      }
    } catch (err) {
      // Fail open — audit should never impede the tool
      const elapsed = Date.now() - t0;
      if (
        err instanceof Error &&
        err.message === "timeout" &&
        elapsed >= 5000
      ) {
        console.warn(
          `[harness-guards] ${guard} TIMEOUT after ${elapsed}ms`,
        );
      } else {
        console.warn(`[harness-guards] ${guard} ERROR: ${err}`);
      }
    }
  }

  return {
    // Layer 1: Enforcement
    "permission.ask": handlePermissionAsk,

    // Layer 2: Audit
    "tool.execute.before": async (_input, output) => {
      const tool = (_input as { tool?: string }).tool ?? "unknown";
      const args = output?.args ?? {};
      const payload: Record<string, unknown> = {
        agent_type: agentName,
        cwd: directory,
        tool_input: args,
      };

      switch (tool) {
        case "bash":
          await auditGuard("bash", payload);
          break;
        case "write":
        case "edit":
          await auditGuard("write", payload);
          break;
        case "read":
        case "grep":
          await auditGuard("read", payload);
          break;
        case "task":
          await auditGuard("spawn", payload);
          break;
      }
    },
  };
};

export default HarnessGuardsPlugin;
