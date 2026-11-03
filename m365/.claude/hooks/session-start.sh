#!/bin/bash
# SessionStart hook for Claude Code cloud sessions.
#   WHAT   Installs PowerShell 7, Pester and PSScriptAnalyzer so the same checks
#          .github/workflows/validate.yml runs (lint + tests) can run in the session.
#   WHY    Cloud containers start without pwsh; without it nothing in this repo can be
#          linted or tested.
#   GOTCHA Versions are pinned to ones verified against this repo. The pwsh tarball is
#          checked against Microsoft's published SHA-256 before it is unpacked.
#          Idempotent: anything already installed is left alone.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PWSH_VERSION="7.4.6"
PWSH_SHA256="6f6015203c47806c5cc444c19d8ed019695e610fbd948154264bf9ca8e157561"
PESTER_VERSION="6.2.0"
PSSA_VERSION="1.25.0"
PWSH_DIR="/opt/microsoft/powershell/7"
MODULE_DIR="${HOME}/.local/share/powershell/Modules"

# The session proxy's CA bundle, when present, so pwsh's HTTPS calls verify.
if [ -f /root/.ccr/ca-bundle.crt ]; then
  export SSL_CERT_FILE=/root/.ccr/ca-bundle.crt
fi

# 1. PowerShell 7
if [ ! -x "${PWSH_DIR}/pwsh" ] || [ "$("${PWSH_DIR}/pwsh" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')" != "${PWSH_VERSION}" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  curl -fsSL --retry 4 -o "${tmp}/pwsh.tar.gz" \
    "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz"
  echo "${PWSH_SHA256}  ${tmp}/pwsh.tar.gz" | sha256sum -c --quiet -
  rm -rf "${PWSH_DIR}"
  mkdir -p "${PWSH_DIR}"
  tar -xzf "${tmp}/pwsh.tar.gz" -C "${PWSH_DIR}"
  chmod +x "${PWSH_DIR}/pwsh"
fi
ln -sf "${PWSH_DIR}/pwsh" /usr/local/bin/pwsh

# 2. Pester and PSScriptAnalyzer (Save-Module: Install-Module is unreliable non-interactively here)
mkdir -p "${MODULE_DIR}"
pwsh -NoLogo -NoProfile -NonInteractive -Command "
  \$ErrorActionPreference = 'Stop'
  \$want = @{ Pester = '${PESTER_VERSION}'; PSScriptAnalyzer = '${PSSA_VERSION}' }
  foreach (\$name in \$want.Keys) {
    if (-not (Get-Module -ListAvailable -Name \$name | Where-Object { \$_.Version -eq [version]\$want[\$name] })) {
      Save-Module -Name \$name -RequiredVersion \$want[\$name] -Path '${MODULE_DIR}' -Repository PSGallery
    }
  }
"

echo "pwsh $(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'), Pester ${PESTER_VERSION}, PSScriptAnalyzer ${PSSA_VERSION} ready."
