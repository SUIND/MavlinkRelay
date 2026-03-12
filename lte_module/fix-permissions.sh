#!/usr/bin/env bash
# fix-permissions.sh — restore executable bits on all LTE module shell scripts
# Run this after any git clone/pull on systems where core.fileMode=false
# Usage: bash fix-permissions.sh

set -e
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

chmod +x install.sh uninstall.sh
chmod +x scripts/*.sh
chmod +x tests/unit/run_all.sh tests/unit/test_*.sh
chmod +x tests/integration/*.sh

echo "Done — executable bits set on all shell scripts."
