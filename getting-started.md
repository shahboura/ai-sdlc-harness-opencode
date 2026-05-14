# Getting Started

This is the 10-minute path from "I cloned the repo" to "the harness is implementing my first user story." For the full spec and the reasoning behind every constraint, read [`CLAUDE.md`](CLAUDE.md). For the comprehensive reference, see [`README.md`](README.md).

## What you're about to do

Install the plugin, run a one-time workspace setup that scans your local repos and writes context files, then kick off `/dev-workflow` against a real work item. The harness will pause at four human gates along the way — those are where you make decisions, not the agents.

## Before you start

You need:

- **Claude Code** installed ([claude.ai/code](https://claude.ai/code))
- **Git** on your PATH
- **Python 3** on your PATH (the guard hooks use it — `python3 --version` should print something)
- **Your target repos already cloned locally**, each on its default branch and up to date. The harness does not clone them for you.
- **Optional**: an MCP server or CLI for your work-item / git provider (ADO, Jira, GitHub, GitLab, Zoho). If you have nothing set up, pick `local-markdown` during `/init-workspace` and you'll be running in under a minute.

## Install

Three commands inside Claude Code:

```
/plugin marketplace add MostAshraf/ai-sdlc-harness
/plugin install ai-sdlc-harness@ai-sdlc-harness
/reload-plugins
```

After the reload, `/init-workspace`, `/story-workflow`, and `/dev-workflow` are available as slash commands.

## Step 1 — Initialize the workspace (one time)

> **Important: run `/init-workspace` from an empty folder.**
> Create a dedicated folder somewhere on your machine (e.g. `~/ai-sdlc-workspace/`) and `cd` into it before starting Claude Code. That folder becomes your *harness workspace* — it's where `.claude/context/` gets written and where every later `/dev-workflow` run is invoked from. Your actual application repos live elsewhere on disk and get referenced by path during the next step.
>
> Do **not** run `/init-workspace` inside one of your application repos. The harness workspace and your code repos are separate things on purpose: it keeps the generated context files out of your project's git history and lets one workspace coordinate work across multiple repos.

```
/init-workspace
```

This is interactive. You'll be asked to:

1. **Pick a work-item provider** — where your stories live. ADO, Jira, GitHub, GitLab, Zoho, or `local-markdown` (a folder of `.md` files, no external system needed).
2. **Pick a git provider** — where your code and PRs live. ADO, GitHub, GitLab, or one of the CLI options (`gh-cli`, `glab-cli`) that skip the MCP setup.
3. **Point at your local repos** — the harness will scan each one, detect language and toolchain, and ask you to confirm anything ambiguous. This is the only step that takes real time; expect 2-5 minutes per repo on first run.
4. **Approve a Bash permissions proposal** — the harness lists exactly which build/test/lint commands it needs to run per repo, you approve, and that list becomes the allowlist for every agent.

Everything generated lives under `.claude/context/` and is git-ignored. Each developer generates their own.

If you only want to try the harness without wiring up a real provider, pick `local-markdown` and point it at any folder. You'll be able to create a story as a markdown file and run the full workflow against it.

## Step 2 — Run your first workflow

Pick a real work item (or write a quick markdown story if you're on `local-markdown`) and run:

```
/dev-workflow <Work-Item-ID>
```

The harness will go through seven phases. Four of them stop and wait for you:

- **Gate 1 (after planning)** — the Planner proposes one or more implementation approaches and a test outline. You pick one. Nothing is coded until you do.
- **Gate 2 (after the TDD loop)** — every task has been written (tests first by the Tester, then code by the Developer, then reviewed by the Reviewer). You see the full implementation and approve it before test hardening begins.
- **Gate 3 (before PR creation)** — the Reviewer does a holistic pre-PR pass against the original plan and conventions, returns a structured report, and you approve the PR.
- **Gate 4 (on-demand, after PR comments arrive)** — only runs if you invoke `/dev-workflow review-response <story-id>`. The Reviewer classifies each PR comment as VALID / INVALID / PARTIAL, and you pick which to address.

Between gates, the agents run on their own. You can walk away. The orchestrator updates the task tracker on disk after every status change so you can check progress at any time.

## What to expect while it runs

- **Sequential within each repo, parallel across repos.** If your story touches three repos, you'll see three parallel lanes. Within each lane, tasks finish one at a time.
- **Two commits per task** — `test:` from the Tester, then `impl:` from the Developer. They get squash-merged once the Reviewer approves.
- **The tracker file is uncommitted** until Phase 6. That's intentional — it keeps your PR history clean.
- **One PR per repo**, all linked to the same work item.

## When things go sideways

The most common issues on a first run:

- **Worktree creation fails on Windows** (`could not lock config file`). The Developer reports this and the orchestrator re-runs without worktree isolation. No action needed from you.
- **A build/test command isn't in the allowlist.** The hook will block it with a clear message. Run `/init-workspace --refresh-permissions` to re-propose the allowlist.
- **The Reviewer flags issues you disagree with.** Push back in the gate response — the orchestrator will route your feedback to the right agent.
- **A task gets stuck in a review-fix loop.** Two rounds of "changes requested" usually means the plan was wrong, not the code. Reject at the gate and ask the Planner to revisit.

## Where to read next

- **[`CLAUDE.md`](CLAUDE.md)** — the workflow spec. Phases, ownership rules, status transitions, and the non-negotiable rules every agent obeys. Read this before you start customizing anything.
- **[`README.md`](README.md)** — comprehensive reference. Branch / commit conventions, hook details, project structure, extension points.
- **`agents/`** — one folder per agent (`planner`, `tester`, `developer`, `reviewer`). The agent's behavior is the markdown file you see there. Edit at your own risk; the workflow rules in `CLAUDE.md` constrain what each agent is allowed to do.
- **`skills/`** — the slash-command entry points and their internals. `dev-workflow`, `story-workflow`, `init-workspace`, and the per-provider adapters under `skills/providers/`.

## A sanity check before your first real run

Try a tiny throwaway story first. Something like "add a `/health` endpoint that returns 200" against a scratch repo. You'll see all four gates fire, the TDD loop run, and a PR get created — in maybe 10-15 minutes of agent time. That's the fastest way to build intuition for what each gate is actually asking you.
