# Session host provisioning order

What `New-AvdSessionHost.ps1` does, in order, and why each step has to come after the
one before it. Each step is one function in the `AvdBuild` module. If you ever rewrite this in Bicep, Terraform, or a web app, the order
is the part that carries over.

| # | Step | Depends on | Why it is here and not earlier or later |
| - | ---- | ---------- | --------------------------------------- |
| 1 | Resolve gallery image version | nothing | Fail fast. If the image does not exist there is no point creating a NIC. Resolving `latest` yourself (instead of letting Azure do it) means the output records the exact version, which a later reimage can pin to. |
| 2 | NIC | subnet | The VM config needs a NIC ID. Created separately (not inline with the VM) so it can be reused on reimage, which keeps the private IP. |
| 3 | VM from image, `Windows_Client` license | 1, 2 | Everything after this runs inside the VM. `LicenseType = Windows_Client` is the Azure Hybrid Benefit flag for Windows multi-session; without it you are billed for an OS license you already have through M365. Trusted Launch and the system-assigned identity (for Entra join) can only be set at creation. |
| 4 | Domain join extension | 3 | The AVD agent registers the host under its domain identity. Join first so the host registers with the right name and so users can authenticate to it. The AD extension reboots the VM. |
| 5 | AVD agent via DSC extension | 4, registration token | Installs the agent and boot loader, then registers the host with the pool using the token. Azure runs extensions on a VM serially, so this waits for the join reboot automatically. Needs a token that has not expired, which is why the token is an input and not something this script generates. |
| 6 | FSLogix registry via Run Command | 3 (and 4 for share access) | Could technically run any time after the VM exists. It is after the agent so that if the agent install fails you have not spent time on config that will be thrown away with the VM. Run Command is the generic post-build hook; anything else that must happen on the host goes in `modules/AvdBuild/hostconfig/` and runs the same way. |
| 7 | Wait for `Available` | 5 | DSC succeeding means the agent installed, not that it finished registering. `Available` is the only status that means a user could connect right now. Nothing downstream (adding to a scaling plan, removing drain) should happen before this. |

## What is deliberately not here

- **Generating the registration token.** One token per pool, and generating one
  invalidates the previous one. The token is an input so that building ten hosts in a
  loop uses the same token. `New-AvdHostPool.ps1` or `Get-AvdRegistrationToken` supplies it.
- **Creating the subnet, gallery, or profile share.** Those are shared infrastructure
  that outlives any one host. They belong in Bicep under `infra/`.
- **Autoscale.** Native scaling plans. Attach the host pool to one separately.
- **Entra Kerberos for Azure Files.** Entra-only joined hosts need the storage account
  configured for it before FSLogix can mount the share. That is storage-side setup.

## Where a build usually fails

| Symptom | Usually means |
| ------- | ------------- |
| Step 3 fails with a security type error | Gallery image is not Gen2 / Trusted Launch capable. Pass `-SecurityType Standard`. |
| Step 4 fails with "account already exists" | AD computer object exists and the join account cannot reset it. Delete the object or use an account with rights over it. |
| Step 5 fails with "parameter cannot be found that matches parameter name 'aadJoin'" | The DSC package at `-DscArtifactsUrl` is an old build. The default now points at Microsoft's current package in the Azure/RDS-Templates repo. |
| Step 5 fails fast otherwise | Token expired, or the DSC artifacts URL is dead. Regenerate with `Get-AvdRegistrationToken -Force` or update `-DscArtifactsUrl`. |
| Step 5 failed once and the VM exists | Run `Repair-AvdSessionHost.ps1` (console option R). It removes the failed extension, reinstalls the agent, reapplies FSLogix, and waits for Available. |
| Step 7 shows `Unavailable` with DomainJoinedCheck and DomainTrustCheck failed on an Entra-joined host, AADJoinedHealthCheck passed | Check `dsregcmd /status` on the host. If `AzureAdJoined : NO`, the join failed even though the extension reported success. The usual cause is a leftover Entra device record with the same name from a deleted VM (`error_hostname_duplicate` in the handler log). The build now removes stale records before joining, deletes the record when a VM is deleted, restarts after the join, and verifies with dsregcmd. `Repair-AvdSessionHost.ps1 -RejoinEntra` fixes an existing host. |
| Step 7 times out with status `Unavailable`, other checks failing | Agent installed but cannot reach the AVD control plane. Check outbound 443 to the AVD service URLs from the subnet. |
| Step 7 times out, host never appears | Token was for a different pool, or the join failed and the agent registered under an unexpected name. |
