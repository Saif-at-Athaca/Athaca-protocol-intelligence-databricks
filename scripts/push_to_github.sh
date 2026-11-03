#!/usr/bin/env bash
# Create empty repo at github.com/Athaca/protocol-intelligence-databricks (web UI or gh), then:
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REMOTE="${1:-git@github.com:Saif-at-Athaca/Athaca-protocol-intelligence-databricks.git}"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE"
else
  git remote add origin "$REMOTE"
fi
git push -u origin main
echo "Pushed to $REMOTE"
