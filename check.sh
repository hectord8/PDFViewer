    #!/bin/bash
#
# Lints the Swift sources and runs the unit tests.
#
#   ./check.sh            lint (advisory) and run tests
#   ./check.sh --strict   fail on any lint warning
#   ./check.sh --fix      rewrite sources with swift-format, then run tests
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES="$ROOT/PDFViewer/Sources"
CONFIG="$ROOT/.swift-format"
MODE="${1:-}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

command -v swift >/dev/null || { echo "error: swift not found. Run: xcode-select --install" >&2; exit 1; }
[[ -d "$SOURCES" ]] || { echo "error: sources not found at $SOURCES" >&2; exit 1; }

case "$MODE" in
  "")
    say "Linting (advisory)"
    swift format lint --recursive --configuration "$CONFIG" "$SOURCES"
    ;;
  --strict)
    say "Linting (strict)"
    swift format lint --strict --recursive --configuration "$CONFIG" "$SOURCES"
    ;;
  --fix)
    say "Formatting sources"
    swift format format --in-place --recursive --configuration "$CONFIG" "$SOURCES"
    ;;
  *)
    echo "usage: ./check.sh [--strict|--fix]" >&2
    exit 2
    ;;
esac

say "Running tests"
# Build outside the project tree: iCloud-synced folders stamp FinderInfo on the
# test bundle, which makes codesign reject it as detritus.
swift test --package-path "$ROOT" --scratch-path "${SWIFT_TEST_SCRATCH:-/tmp/PDFViewer-swift-test}"
