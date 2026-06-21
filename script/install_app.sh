#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/app_config.sh"

INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/$DISPLAY_NAME.app"
MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    diskutil eject "$MOUNT_POINT" >/dev/null || true
  fi
}
trap cleanup EXIT

echo "Building DMG..."
DMG_PATH="$("$SCRIPT_DIR/package_dmg.sh" | tail -n 1)"

echo "Quitting running app..."
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
sleep 1

echo "Mounting $DMG_PATH..."
ATTACH_OUTPUT="$(diskutil image attach --readOnly --nobrowse "$DMG_PATH")"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')"

if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
  echo "Could not find mounted DMG volume." >&2
  exit 1
fi

SOURCE_APP="$MOUNT_POINT/$DISPLAY_NAME.app"
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Could not find $DISPLAY_NAME.app in mounted DMG." >&2
  exit 1
fi

echo "Installing to $INSTALLED_APP..."
rm -rf "$INSTALLED_APP"
ditto "$SOURCE_APP" "$INSTALLED_APP"
xattr -dr com.apple.quarantine "$INSTALLED_APP" >/dev/null 2>&1 || true

codesign --verify --deep --strict "$INSTALLED_APP"

echo "Installed $INSTALLED_APP"
