#!/bin/bash
#
# Reads CHANGELOG.md for releases (used by .github/workflows/ci.yml and by hand).
#
#   Tools/changelog.sh version        top released version, e.g. 0.3.0
#   Tools/changelog.sh notes [ver]    that section's body (default: the top one), for release notes
#   Tools/changelog.sh next           the next minor after the latest v* tag (fetches tags), e.g. 0.4.0
#
# Sections are "## <major>.<minor>.<patch> — <date>" (newest first).
#
set -euo pipefail

FILE="$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md"
HEADING='^## [0-9]+\.[0-9]+\.[0-9]+'

top_version() {
  grep -E "$HEADING" "$FILE" | head -1 | sed -E 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

case "${1:-}" in
  version)
    top_version
    ;;
  notes)
    ver="${2:-$(top_version)}"
    awk -v ver="$ver" '
      /^## [0-9]+\.[0-9]+\.[0-9]+/ { if (on) exit; if (index($0, "## " ver) == 1) { on = 1; next } }
      on { print }
    ' "$FILE" | sed -e '/./,$!d'   # drop leading blank lines
    ;;
  next)
    git -C "$(dirname "$FILE")" fetch -q --tags 2>/dev/null || true
    last="$(git -C "$(dirname "$FILE")" tag --list 'v*' | sed 's/^v//' | sort -V | tail -1)"
    if [ -z "$last" ]; then top_version; exit 0; fi   # nothing released yet
    IFS=. read -r major minor _ <<< "$last"
    echo "$major.$((minor + 1)).0"
    ;;
  *)
    echo "usage: $0 version | notes [version] | next" >&2
    exit 2
    ;;
esac
