# Azure CLI scripts

**Safe release:** the CLI entry point exits before calling Azure CLI. Examples below are retained reference material.

Bash scripts around `az`. Requires `az login` first.

- Files are `verb-noun.sh`, executable, with a usage comment at the top.
- Start every script with `set -euo pipefail`.
- Use `--output table` for humans, `--output json --query '...'` (JMESPath) for pipelines.
