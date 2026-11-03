#!/usr/bin/env bash
# Lists VMs in the current subscription with power state and IPs.
# Usage: ./list-vms.sh [resource-group]

# ---- 1. Safety flags --------------------------------------------------------
#   WHAT   -e exit on error, -u error on unset variable, -o pipefail fail a pipe
#          if any stage fails.
#   WHY    Without these, bash keeps going after an az call fails and you get
#          half-finished work with a green exit code.
set -euo pipefail

# ---- 2. Input ---------------------------------------------------------------
#   WHAT   Optional first argument. "${1:-}" gives an empty string if not passed.
#   WHY    Plain "$1" would trip set -u when the argument is missing.
rg="${1:-}"

# ---- 3. Query ---------------------------------------------------------------
#   WHAT   --show-details adds power state and IPs (an extra call per VM).
#   WHY    Plain "az vm list" has no power state at all. Same gotcha as
#          Get-AzVM without -Status.
if [[ -n "$rg" ]]; then
  az vm list --resource-group "$rg" --show-details --output table
else
  az vm list --show-details --output table
fi
