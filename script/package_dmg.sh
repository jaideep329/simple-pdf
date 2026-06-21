#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/app_config.sh"

DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/$DISPLAY_NAME-$VERSION.dmg"

APP_BUNDLE="$("$SCRIPT_DIR/build_app_bundle.sh" release)"

codesign --verify --deep --strict "$APP_BUNDLE"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_BUNDLE" "$STAGING_DIR/$DISPLAY_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
diskutil image create from \
  --format UDZO \
  --volumeName "$DISPLAY_NAME" \
  "$STAGING_DIR" \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"
rm -rf "$STAGING_DIR"

echo "$DMG_PATH"
