# Step: apply-fixes (developer shape, mode `fixup`)

Requires the ⟨select-comments⟩ token — a `select` gate (see `analyze-comments.md`):
its decision is a LIST of the comment IDs the human picked, read from
`state.gates["select-comments"].decision` (`npx @shahboura/harness show`).

1. Spawn `developer` with `harness-mode: fixup` + the SELECTED comments only
   (look up each id's text from `<run>/reports/comments-round-<n>.md`).
   Same rules as `fixup-task.md` (fixup commits, autosquash, locked tests).
2. `npx @shahboura/harness merge-task --autosquash
   --base <default-branch> --repo <repo> --run <run>` — this REWRITES the
   branch's history (fixups folded in), so the remote copy is now stale
   regardless of whether the branch itself moved. Push it:
   `npx @shahboura/harness push --repo <repo> --branch <feature-branch>
   --force-with-lease --run <run>`. If the base moved upstream too,
   `npx @shahboura/harness sync-branch --onto <default-branch>
   --repo <repo> --run <run>` FIRST (rebase), then the push.
   Record the declared artifact: `npx @shahboura/harness artifact
   --name fix-commits --value "<comment-ids fixed> @ <new HEAD sha>" --run <run>`.
3. `npx @shahboura/harness publish-mirror --repo <repo> --run <run>`.
   From here the cursor has two
   legal moves (`show` + the manifest tell you which): reenter `analyze-comments`
   (declared repeatable edge — more comments arrived) or proceed to `reconcile`
   (declared `returns_to` edge — done addressing comments, PR merged).
