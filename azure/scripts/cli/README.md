# Azure CLI scripts

Bash scripts around `az`. Requires `az login` first.

- Files are `verb-noun.sh`, executable, with a usage comment at the top.
- Start every script with `set -euo pipefail`.
- Use `--output table` for humans, `--output json --query '...'` (JMESPath) for pipelines.
