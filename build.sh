#!/bin/zsh
# =============================================================================
# Purchase Information Sync — build script
# =============================================================================
# Builds a Release copy of the app into ./dist and packages it as a .zip
# (and optionally a .dmg and/or an installer .pkg for Jamf / MDM deployment).
#
# Signing modes:
#   (default)          Ad-hoc signed — runs on this Mac / for internal testing.
#   --sign IDENTITY    Sign with a certificate, e.g. "Developer ID Application".
#                      Requires --team. Enables Hardened Runtime + timestamp.
#   --notarize PROFILE Notarize and staple using a notarytool keychain profile
#                      (create once with: xcrun notarytool store-credentials PROFILE).
#
# Usage:
#   ./build.sh
#   ./build.sh --dmg
#   ./build.sh --pkg
#   ./build.sh --sign "Developer ID Application" --team ABCDE12345 \
#              --installer-sign "Developer ID Installer" \
#              --notarize MyNotaryProfile --dmg --pkg
#
# Options:
#   --sign IDENTITY      Code signing identity (default: ad-hoc "-")
#   --team TEAM_ID       Apple Developer Team ID (required with --sign)
#   --bundle-id ID       Override the bundle identifier
#   --version X.Y.Z      Set the marketing version (CFBundleShortVersionString)
#   --build-number N     Set the build number (default: git commit count)
#   --notarize PROFILE   Notarize + staple with the given notarytool profile
#   --dmg                Also create a .dmg
#   --pkg                Also create an installer .pkg (installs to /Applications)
#   --installer-sign ID  Sign the .pkg, e.g. "Developer ID Installer"
#   --clean              Remove previous build output first
#   -h, --help           Show this help
# =============================================================================

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
info()  { echo "${GREEN}-> $*${NC}"; }
warn()  { echo "${YELLOW}WARN: $*${NC}" >&2; }
fail()  { echo "${RED}ERROR: $*${NC}" >&2; exit 1; }

# Submit a file for notarization and fail unless Apple accepts it.
# notarytool exits 0 even when the status is Invalid, so check the status itself.
notarize() {
    local file="$1" result sub_id sub_status
    result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" \
        || fail "Notarization submission failed for: $file"
    sub_id="$(plutil -extract id raw - <<< "$result" 2>/dev/null || true)"
    sub_status="$(plutil -extract status raw - <<< "$result" 2>/dev/null || true)"
    info "Notarization ${sub_id}: ${sub_status}"
    if [[ "$sub_status" != "Accepted" ]]; then
        [[ -n "$sub_id" ]] && xcrun notarytool log "$sub_id" --keychain-profile "$NOTARY_PROFILE" >&2
        fail "Notarization was not accepted (status: ${sub_status:-unknown})."
    fi
}

# ---------- Paths -------------------------------------------------------------
SCRIPT_DIR="${0:A:h}"
PROJECT="${SCRIPT_DIR}/Warranty Preload.xcodeproj"
SCHEME="Warranty Preload"
APP_NAME="Purchase Information Sync"
BUILD_DIR="${SCRIPT_DIR}/build"
DIST_DIR="${SCRIPT_DIR}/dist"
DERIVED_DATA="${BUILD_DIR}/DerivedData"

# ---------- Options -----------------------------------------------------------
SIGN_IDENTITY="-"
TEAM_ID=""
BUNDLE_ID=""
VERSION=""
BUILD_NUMBER=""
NOTARY_PROFILE=""
MAKE_DMG=false
MAKE_PKG=false
INSTALLER_SIGN=""
CLEAN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)         SIGN_IDENTITY="$2"; shift 2 ;;
        --team)         TEAM_ID="$2";       shift 2 ;;
        --bundle-id)    BUNDLE_ID="$2";     shift 2 ;;
        --version)      VERSION="$2";       shift 2 ;;
        --build-number) BUILD_NUMBER="$2";  shift 2 ;;
        --notarize)     NOTARY_PROFILE="$2"; shift 2 ;;
        --dmg)          MAKE_DMG=true;      shift ;;
        --pkg)          MAKE_PKG=true;      shift ;;
        --installer-sign) INSTALLER_SIGN="$2"; shift 2 ;;
        --clean)        CLEAN=true;         shift ;;
        -h|--help)      sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              fail "Unknown option: $1 (see --help)" ;;
    esac
done

# ---------- Validation --------------------------------------------------------
command -v xcodebuild >/dev/null || fail "xcodebuild not found — install Xcode."
[[ -d "$PROJECT" ]] || fail "Project not found: $PROJECT"

if [[ "$SIGN_IDENTITY" != "-" && -z "$TEAM_ID" ]]; then
    fail "--team is required when using --sign."
fi
if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" == "-" ]]; then
    fail "Notarization requires a Developer ID signature (--sign \"Developer ID Application\" --team …)."
fi

if [[ -n "$INSTALLER_SIGN" && "$MAKE_PKG" != true ]]; then
    fail "--installer-sign requires --pkg."
fi
if [[ "$MAKE_PKG" == true && -n "$NOTARY_PROFILE" && -z "$INSTALLER_SIGN" ]]; then
    fail "Notarizing the .pkg requires --installer-sign \"Developer ID Installer\"."
fi

if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$(git -C "$SCRIPT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
fi

# ---------- Clean -------------------------------------------------------------
if [[ "$CLEAN" == true ]]; then
    info "Cleaning previous build output…"
    rm -rf "$BUILD_DIR" "$DIST_DIR"
fi
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ---------- Build -------------------------------------------------------------
BUILD_SETTINGS=(
    "CURRENT_PROJECT_VERSION=${BUILD_NUMBER}"
)
[[ -n "$VERSION"   ]] && BUILD_SETTINGS+=("MARKETING_VERSION=${VERSION}")
[[ -n "$BUNDLE_ID" ]] && BUILD_SETTINGS+=("PRODUCT_BUNDLE_IDENTIFIER=${BUNDLE_ID}")

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    info "Signing: ad-hoc (local / internal use only)"
    BUILD_SETTINGS+=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=-"
        "DEVELOPMENT_TEAM="
    )
else
    info "Signing: ${SIGN_IDENTITY} (team ${TEAM_ID})"
    BUILD_SETTINGS+=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=${SIGN_IDENTITY}"
        "DEVELOPMENT_TEAM=${TEAM_ID}"
        "ENABLE_HARDENED_RUNTIME=YES"
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
        # Otherwise Xcode adds get-task-allow, which notarization rejects.
        # Turning injection off also drops the entitlements generated from
        # ENABLE_APP_SANDBOX etc., so supply them explicitly. Keep this file in
        # step with the target's sandbox capabilities.
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"
        "CODE_SIGN_ENTITLEMENTS=${SCRIPT_DIR}/PurchaseInformationSync.entitlements"
    )
fi

info "Building ${APP_NAME} (Release, build ${BUILD_NUMBER})…"
LOG_FILE="${BUILD_DIR}/xcodebuild.log"
if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$DERIVED_DATA" \
        "${BUILD_SETTINGS[@]}" \
        clean build > "$LOG_FILE" 2>&1; then
    grep -E "error:|\*\* BUILD FAILED" "$LOG_FILE" | head -20 >&2 || true
    fail "Build failed — full log: $LOG_FILE"
fi

BUILT_APP="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
[[ -d "$BUILT_APP" ]] || fail "Built app not found at: $BUILT_APP"

# ---------- Copy to dist ------------------------------------------------------
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${BUILT_APP}/Contents/Info.plist")"
DIST_APP="${DIST_DIR}/${APP_NAME}.app"
rm -rf "$DIST_APP"
ditto "$BUILT_APP" "$DIST_APP"
info "App: $DIST_APP (version ${APP_VERSION} build ${BUILD_NUMBER})"

# ---------- Verify signature --------------------------------------------------
codesign --verify --deep --strict "$DIST_APP" || fail "Code signature verification failed."
if codesign -d --entitlements - --xml "$DIST_APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
    info "Signature verified (App Sandbox enabled)"
elif [[ "$SIGN_IDENTITY" != "-" ]]; then
    fail "App Sandbox entitlement missing from the signed app — check PurchaseInformationSync.entitlements."
else
    warn "Signature verified, but App Sandbox entitlement not found."
fi

# ---------- Notarize ----------------------------------------------------------
BASE_NAME="${APP_NAME// /-}-${APP_VERSION}"
ZIP_PATH="${DIST_DIR}/${BASE_NAME}.zip"

if [[ -n "$NOTARY_PROFILE" ]]; then
    info "Submitting for notarization (profile: ${NOTARY_PROFILE})…"
    NOTARY_ZIP="${BUILD_DIR}/notarize.zip"
    rm -f "$NOTARY_ZIP"
    ditto -c -k --keepParent "$DIST_APP" "$NOTARY_ZIP"
    notarize "$NOTARY_ZIP"
    xcrun stapler staple "$DIST_APP" || fail "Stapling failed."
    rm -f "$NOTARY_ZIP"
    info "Notarized and stapled"
fi

# ---------- Package -----------------------------------------------------------
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$DIST_APP" "$ZIP_PATH"
info "Zip: $ZIP_PATH"

if [[ "$MAKE_DMG" == true ]]; then
    DMG_PATH="${DIST_DIR}/${BASE_NAME}.dmg"
    STAGING="${BUILD_DIR}/dmg"
    rm -rf "$STAGING" "$DMG_PATH"
    mkdir -p "$STAGING"
    ditto "$DIST_APP" "${STAGING}/${APP_NAME}.app"
    ln -s /Applications "${STAGING}/Applications"
    # `diskutil image` replaces the deprecated `hdiutil create` on newer macOS; fall back for older systems.
    dmg_ok=false
    if diskutil image create from -h >/dev/null 2>&1; then
        diskutil image create from --format UDZO --volumeName "$APP_NAME" "$STAGING" "$DMG_PATH" >/dev/null && dmg_ok=true
    else
        hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null && dmg_ok=true
    fi
    rm -rf "$STAGING"

    if [[ "$dmg_ok" == true ]]; then
        if [[ "$SIGN_IDENTITY" != "-" ]]; then
            codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
        fi
        if [[ -n "$NOTARY_PROFILE" ]]; then
            info "Notarizing DMG…"
            notarize "$DMG_PATH"
            xcrun stapler staple "$DMG_PATH" || fail "DMG stapling failed."
        fi
        info "DMG: $DMG_PATH"
    else
        # Not fatal: the .app and .zip are already built.
        warn "DMG creation failed (disk image service unavailable?). The .app and .zip are still in ${DIST_DIR}."
    fi
fi

if [[ "$MAKE_PKG" == true ]]; then
    BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${DIST_APP}/Contents/Info.plist")"
    PKG_PATH="${DIST_DIR}/${BASE_NAME}.pkg"
    PKG_ROOT="${BUILD_DIR}/pkgroot"
    COMPONENT_PLIST="${BUILD_DIR}/component.plist"
    COMPONENT_PKG="${BUILD_DIR}/component.pkg"
    rm -rf "$PKG_ROOT" "$PKG_PATH" "$COMPONENT_PKG" "$COMPONENT_PLIST"
    mkdir -p "${PKG_ROOT}/Applications"
    ditto "$DIST_APP" "${PKG_ROOT}/Applications/${APP_NAME}.app"

    # Stop Installer relocating the app to wherever another copy happens to live,
    # so it always lands in /Applications.
    pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST" >/dev/null
    # Newer pkgbuild omits the key, so delete-then-add works either way.
    /usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$COMPONENT_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$COMPONENT_PLIST"

    info "Building installer package…"
    pkgbuild \
        --root "$PKG_ROOT" \
        --component-plist "$COMPONENT_PLIST" \
        --identifier "${BUNDLE_IDENTIFIER}.pkg" \
        --version "$APP_VERSION" \
        --install-location "/" \
        "$COMPONENT_PKG" >/dev/null || fail "pkgbuild failed."

    # Wrap in a distribution (product) archive, which MDM
    # InstallEnterpriseApplication and notarization require.
    PRODUCT_ARGS=(--package "$COMPONENT_PKG")
    [[ -n "$INSTALLER_SIGN" ]] && PRODUCT_ARGS+=(--sign "$INSTALLER_SIGN" --timestamp)
    productbuild "${PRODUCT_ARGS[@]}" "$PKG_PATH" >/dev/null || fail "productbuild failed."
    rm -rf "$PKG_ROOT" "$COMPONENT_PKG" "$COMPONENT_PLIST"

    if [[ -n "$NOTARY_PROFILE" ]]; then
        info "Notarizing package…"
        notarize "$PKG_PATH"
        xcrun stapler staple "$PKG_PATH" || fail "Package stapling failed."
    fi
    info "PKG: $PKG_PATH"
    if [[ -z "$INSTALLER_SIGN" ]]; then
        warn "Package is unsigned. Use --installer-sign \"Developer ID Installer\" for MDM / Gatekeeper."
    fi
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    warn "Ad-hoc builds are blocked by Gatekeeper on other Macs. Use --sign/--notarize for distribution."
fi
info "Done."
