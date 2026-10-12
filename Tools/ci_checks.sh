#!/bin/bash
#
# Builds and runs the headless checks that need no sample photos (GitHub Actions runs this; see
# .github/workflows/ci.yml). The photo-based checks (develop, masks, zoom, export, previews, …) need
# the owner's sample files and stay local; see Tools/README.md.
#
# Usage:
#   Tools/ci_checks.sh [out-dir]      (default /private/tmp/claude-501/ci-checks)
#
# Exits non-zero if any check fails to build or fails.
#
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/private/tmp/claude-501/ci-checks}"
APP=sloproom
export HARNESS_OPT="${HARNESS_OPT:--Onone}"
mkdir -p "$OUT"
cd "$REPO" || exit 1

FAILED=()

# check <name> <run args (one string)> <extra .swift files…>
check() {
  local name="$1" args="$2"; shift 2
  echo "::group::$name"
  if Tools/harness.sh "$OUT/$name" "Tools/$name.swift" "$@"; then
    # shellcheck disable=SC2086
    if "$OUT/$name" $args; then echo "$name: PASS"; else FAILED+=("$name"); fi
  else
    echo "$name: BUILD FAILED"; FAILED+=("$name (build)")
  fi
  echo "::endgroup::"
}

check actions_check "$OUT/actions-run" \
  $APP/Actions/PhotoActionSpec.swift $APP/Actions/EditSections.swift $APP/Actions/BulkCrop.swift \
  $APP/Actions/Catalog+BulkEdits.swift $APP/Shortcuts/ShortcutModel.swift \
  $APP/Develop/Crop/CropMath.swift $APP/Develop/Crop/Catalog+CropPresets.swift

check folders_check "$OUT/folders-run" \
  $APP/App/FolderTree.swift $APP/Library/Sidebar/Catalog+FolderManagement.swift $APP/Library/Sidebar/FolderDragPayload.swift

HARNESS_NO_DEFAULT=1 check shortcuts_check "" \
  $APP/Shortcuts/ShortcutModel.swift $APP/Shortcuts/ShortcutStore.swift

# No RAW given: model, catalog, camera-make and sampling checks run; render checks skip.
check decode_check "$OUT/no-raw.RW2 $OUT/decode-run" \
  $APP/Actions/EditSections.swift

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "FAILED: ${FAILED[*]}"
  exit 1
fi
echo "ALL CI CHECKS PASS"
