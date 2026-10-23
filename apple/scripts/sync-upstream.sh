#!/usr/bin/env bash
# Merge upstream FigCraft (storytold/figcraft) into this fork, then run the bridge gate.
# Merge, never rebase. Only apple/, FORK.md and .github/workflows/apple-*.yml are ours, so conflicts are rare.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/storytold/figcraft.git
git fetch upstream
git merge --no-edit upstream/main
export PATH="$HOME/.cargo/bin:$PATH"
(cd apple/bridge && cargo test && cargo clippy --all-targets -- -D warnings)
echo "Merged upstream/main; bridge gate green. Rebuild the app: apple/scripts/build-xcframework.sh --sim-only --debug"
