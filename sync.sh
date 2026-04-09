#!/bin/bash
# One-shot: pull latest, import to Bear, export from Bear, push
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Bear Notes Sync ==="
echo ""
echo "--- Importing from GitHub → Bear ---"
"$SCRIPT_DIR/bear-sync.sh" import
echo ""
echo "--- Exporting from Bear → GitHub ---"
"$SCRIPT_DIR/bear-sync.sh" export
echo ""
echo "=== Sync complete ==="
