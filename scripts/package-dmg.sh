#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CollabDock"
VERSION="${VERSION:-0.2.0}"
OUT_DIR="${ROOT_DIR}/build"
APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"
DMG_PATH="${OUT_DIR}/${APP_NAME}-${VERSION}.dmg"
STAGING_DIR="${OUT_DIR}/dmg-staging"

if [[ ! -d "${APP_BUNDLE}" ]]; then
  "${ROOT_DIR}/scripts/package-app.sh"
fi

echo "[CollabDock] Staging DMG contents..."
rm -rf "${STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "[CollabDock] Creating compressed DMG at ${DMG_PATH}..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${STAGING_DIR}"

SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
echo "[CollabDock] DMG ready: ${DMG_PATH}"
echo "[CollabDock] SHA256:    ${SHA256}"
