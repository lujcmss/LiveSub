#!/bin/zsh
# Run the unit tests (see scripts/sdk.sh for why the SDK is pinned).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sdk.sh
swift test "$@"
