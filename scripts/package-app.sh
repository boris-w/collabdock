#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CollabDock"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
UNIVERSAL="${UNIVERSAL:-0}"
OUT_DIR="${ROOT_DIR}/build"
APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

cd "${ROOT_DIR}"

if [[ ! -f "${ROOT_DIR}/Resources/AppIcon.icns" \
   || "${ROOT_DIR}/Resources/AppIconMaster.png" -nt "${ROOT_DIR}/Resources/AppIcon.icns" \
   || "${ROOT_DIR}/scripts/generate-icon.swift" -nt "${ROOT_DIR}/Resources/AppIcon.icns" ]]; then
  echo "[CollabDock] Generating AppIcon.icns..."
  swift "${ROOT_DIR}/scripts/generate-icon.swift" "${ROOT_DIR}/Resources/AppIcon.icns" "${ROOT_DIR}/Resources/AppIconMaster.png"
fi

if [[ "${UNIVERSAL}" == "1" ]]; then
  # Build each architecture with SwiftPM's native build system and merge with lipo.
  # `swift build --arch arm64 --arch x86_64` switches to the Xcode build system, which compiles
  # String Catalogs with symbol generation and rejects keys such as "%@"; it would also ship a
  # differently built app than the one CI tests.
  echo "[CollabDock] Building arm64 and x86_64 separately (${BUILD_CONFIG})..."
  swift build -c "${BUILD_CONFIG}" --arch arm64
  ARM_BIN_DIR="$(swift build -c "${BUILD_CONFIG}" --arch arm64 --show-bin-path)"
  swift build -c "${BUILD_CONFIG}" --arch x86_64
  X86_BIN_DIR="$(swift build -c "${BUILD_CONFIG}" --arch x86_64 --show-bin-path)"

  BIN_DIR="${OUT_DIR}/universal-bin"
  rm -rf "${BIN_DIR}"
  mkdir -p "${BIN_DIR}"
  echo "[CollabDock] Merging into a Universal Binary with lipo..."
  lipo -create "${ARM_BIN_DIR}/${APP_NAME}" "${X86_BIN_DIR}/${APP_NAME}" -output "${BIN_DIR}/${APP_NAME}"
  # Resource bundles are architecture-independent
  for bundle in "${ARM_BIN_DIR}"/*.bundle; do
    if [[ -d "${bundle}" ]]; then
      cp -R "${bundle}" "${BIN_DIR}/"
    fi
  done
else
  echo "[CollabDock] Building Swift package (${BUILD_CONFIG})..."
  swift build -c "${BUILD_CONFIG}"
  BIN_DIR="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)"
fi

BIN_PATH="${BIN_DIR}/${APP_NAME}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Error: executable not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "[CollabDock] Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [[ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]]; then
  cp "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

# Bundle SwiftPM resource bundles (compiled String Catalogs) inside Contents/Resources
for bundle in "${BIN_DIR}"/*.bundle; do
  if [[ -d "${bundle}" ]]; then
    cp -R "${bundle}" "${APP_BUNDLE}/Contents/Resources/"
  fi
done

# Declare app-level localization directories alongside CFBundleLocalizations
mkdir -p "${APP_BUNDLE}/Contents/Resources/en.lproj" "${APP_BUNDLE}/Contents/Resources/zh-Hans.lproj"

if [[ "${SIGN_IDENTITY}" == "-" ]]; then
  echo "[CollabDock] Applying ad-hoc code signature..."
  codesign --force --deep --sign - "${APP_BUNDLE}"
else
  echo "[CollabDock] Signing with identity: ${SIGN_IDENTITY}..."
  codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
fi

echo "[CollabDock] Done: ${APP_BUNDLE}"
