# Cloudwright contributor notes

Read README.md, then the component's README and relevant design notes before editing.

- `learn/` is the command builder. It must never execute generated commands. Preserve
  its read-only lookup guard and offline Contoso mode.
- `azure/` contains Azure and AVD administration. Preserve tenant/subscription checks
  and `-WhatIf` propagation into its modules.
- `m365/` contains Microsoft 365 administration. Preserve explicit tenant selection,
  the reviewed change plan, and its enforcement before writes.
- Keep component modules independent. The Cloudwright launcher selects an existing
  entry point; shared tenant-changing logic needs a deliberate design and tests.
- Use PowerShell 7 for the unified toolkit. Keep scripts thin and logic testable.
- Never commit credentials, tenant data, generated scripts, local settings, or logs.
  Examples must use fictional values. Scan staged changes for credential patterns,
  phone numbers, email addresses, and Discord IDs before committing.
- Public commits use `Cloudwright contributors <contributors@cloudwright.example>`
  for author and committer. Keep personal and organization identifiers out of source,
  examples, and commit metadata; use the hosting account only in distribution URLs.
  Do not merge private predecessor history into the public repository.
- Run the root tests and the affected component's existing checks. Do not connect to
  a tenant, deploy, or restart services as part of local verification.
- GitHub publication requires the repository owner's approval. Never force-push main.
