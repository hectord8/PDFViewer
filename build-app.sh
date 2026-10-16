#!/bin/bash
#
# Builds PDFViewer.app using only the Command Line Tools.
#
# You do NOT need Xcode, and you do NOT need to update macOS.
# Everything below ships with macOS or with the Command Line Tools.
#
#   ./build-app.sh              build into ./dist
#   ./build-app.sh --install    build, then install into /Applications
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="${BUILD_DIR:-$ROOT/dist}"
FINAL="$DIST/PDFViewer.app"
BUNDLE_ID="com.example.PDFViewer"
DEPLOYMENT_TARGET="14.0"

# Anything Xcode would pick up as "Last Upgrade Check" for our own records.
XCODE_VERSION="16.4"

say() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v xcrun >/dev/null || die "xcrun not found. Run: xcode-select --install"

SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
  die "No macOS SDK found. Run: xcode-select --install"
fi

say "SDK: $SDK ($(xcrun --sdk macosx --show-sdk-version))"

# --- 1. Clean ------------------------------------------------------------
# Compile and sign in a staging dir outside the project. If the project lives
# in an iCloud-synced folder (~/Documents often is), the file provider re-stamps
# com.apple.FinderInfo onto anything created there within milliseconds, and
# codesign rejects that as "detritus". Signing in /tmp avoids the race; the
# signed bundle is copied into place afterwards.
STAGE="$(mktemp -d)"
TMP="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$TMP"' EXIT

APP="$STAGE/PDFViewer.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# --- 2. Compile a universal binary --------------------------------------
# Both slices so the app still works if you move it to an Intel Mac.
say "Compiling (arm64 + x86_64, macOS $DEPLOYMENT_TARGET+)"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/PDFViewer/Sources" -name '*.swift' | sort)
[[ ${#SOURCES[@]} -gt 0 ]] || die "No Swift sources found under PDFViewer/Sources"

for ARCH in arm64 x86_64; do
  xcrun --sdk macosx swiftc \
    -sdk "$SDK" \
    -target "${ARCH}-apple-macosx${DEPLOYMENT_TARGET}" \
    -swift-version 5 \
    -O \
    -framework SwiftUI -framework PDFKit -framework AppKit -framework WebKit \
    -o "$TMP/PDFViewer-$ARCH" \
    "${SOURCES[@]}"
done

lipo -create -output "$CONTENTS/MacOS/PDFViewer" \
  "$TMP/PDFViewer-arm64" "$TMP/PDFViewer-x86_64"
lipo -info "$CONTENTS/MacOS/PDFViewer"

# --- 3. Resources --------------------------------------------------------
# actool only exists in the full Xcode, so the (currently empty) asset catalog
# is skipped. SwiftUI falls back to the system accent colour, which is fine.
if [[ -d "$ROOT/PDFViewer/Resources/Assets.xcassets" ]] \
   && xcrun --find actool >/dev/null 2>&1; then
  say "Compiling asset catalog"
  xcrun actool "$ROOT/PDFViewer/Resources/Assets.xcassets" \
    --compile "$CONTENTS/Resources" \
    --platform macosx \
    --minimum-deployment-target "$DEPLOYMENT_TARGET" \
    --output-format human-readable-text \
    2>&1 | sed 's/^/    /' || say "    (asset catalog skipped; using system defaults)"
else
  say "Skipping asset catalog (actool needs full Xcode; using system defaults)"
fi

# --- 4. Info.plist with build variables expanded ------------------------
say "Writing Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable PDFViewer" \
  "$ROOT/PDFViewer/Resources/Info.plist" >/dev/null 2>&1 || true
cp "$ROOT/PDFViewer/Resources/Info.plist" "$CONTENTS/Info.plist"

/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier $BUNDLE_ID" \
  -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" \
  "$CONTENTS/Info.plist" >/dev/null

# PkgInfo is required by some AppKit paths and by Finder.
printf 'APPL????' > "$CONTENTS/PkgInfo"

# --- 5. Sign (in staging) ------------------------------------------------
xattr -cr "$APP" 2>/dev/null || true

# Ad-hoc signature. Enough to run locally on this Mac, no Apple ID needed.
say "Signing (ad-hoc)"
codesign --force --sign - \
  --options runtime \
  --timestamp=none \
  "$APP" 2>&1 | sed 's/^/    /' || die "codesign failed"

codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# --- 6. Copy the signed bundle into place -------------------------------
mkdir -p "$DIST"
rm -rf "$FINAL"
cp -R "$APP" "$FINAL"
# Clear any FinderInfo the destination folder may have stamped; the signature
# is unaffected by extended attributes, so the app still verifies and runs.
xattr -cr "$FINAL" 2>/dev/null || true
touch "$FINAL"

say "Built: $FINAL"
du -sh "$FINAL" | sed 's/^/    /'

# --- 7. Optional install -------------------------------------------------
if [[ "${1:-}" == "--install" ]]; then
  if [[ -w /Applications || -e /Applications ]]; then
    say "Installing to /Applications"
    rm -rf "/Applications/PDFViewer.app"
    cp -R "$FINAL" /Applications/
    xattr -cr "/Applications/PDFViewer.app" 2>/dev/null || true
    say "Installed: /Applications/PDFViewer.app"
  else
    die "/Applications is not writable. Re-run without sudo, or copy it by hand."
  fi
fi

say "Done. Open it with: open \"$FINAL\""
