# Step: fetch (orchestrator-owned, fully mechanical)

Already executed by `bin/harness fetch` at startup — it fetched the work item via
the configured provider, normalized it to `<run>/work-item.json`, resolved
`change_type`, ran the ex-ante quick classifier, and bootstrapped `state.yaml`
with a seeded task.

## MCP-transport providers (ado-mcp / jira / zoho)

A script can't call an MCP tool, so `bin/harness fetch
--id` **refuses** for these, naming the tool + args to invoke (that refusal is
the instruction). Run step-one in the orchestrator instead:

1. Invoke the mapped `work_item.fetch` tool (`bin/harness
   provider --op work_item.fetch --id <id>` prints the exact tool + args;
   `{project}` from `provider.ado_project`). Capture its raw JSON result.
2. Pipe that raw result into the same bootstrap the CLI path runs:

   ```
   printf '%s' '<raw-json>' | bin/harness fetch --from-raw
   ```

   `--from-raw` runs the identical normalize → classify → bootstrap, writing
   `work-item.json` and `state.yaml`. On success note `run`, `mode`.

## Advance

Nothing further to do here. Advance:

```
bin/harness cursor --to <next-per-manifest> --run <run>
```

(`intake` in full mode, `preflight` in quick.)
