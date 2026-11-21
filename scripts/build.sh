#!/usr/bin/env bash
# Build Cyanide for iphoneos and package the resulting .app into a versioned IPA
# under build/, e.g. build/Cyanide-1.0.14.ipa, with a build/Cyanide.ipa
# symlink pointing at the latest build. With SDK=iphonesimulator, build the
# simulator .app and skip IPA packaging.
#
# Run as: ./scripts/build.sh
# Override defaults with env vars:
#   SCHEME, CONFIG (Debug|Release|VPhone Debug), SDK (iphoneos|iphonesimulator),
#   ARCHS, IPHONEOS_DEPLOYMENT_TARGET
#
# The version comes from CFBundleShortVersionString in the built Info.plist
# (= the MARKETING_VERSION build setting in the xcodeproj). Bump
# MARKETING_VERSION to ship a new version.
#
# Code signing is disabled — the IPA ships unsigned for sideload via
# AltStore / TrollStore / Sideloadly, which do their own signing.

set -euo pipefail

cd "$(dirname "$0")/.."

# Settings → What's New and the Home card read Cyanide/Changelog.plist. It is
# ignored because release.sh regenerates it for each release, so every build
# entry point generates it only when absent. Keeping this in the low-level
# script also covers CI, which may invoke scripts/build.sh directly.
if [ ! -f "$PWD/Cyanide/Changelog.plist" ]; then
    "$PWD/scripts/gen-changelog.sh" \
        || echo "==> changelog generation failed (continuing without it)"
fi

# Let the focused shell regression suite exercise resource handling without
# requiring Xcode; normal builds never set this variable.
if [ "${BUILD_DRY_RUN:-0}" = "1" ]; then
    echo "==> dry-run: changelog preparation complete; skipping xcodebuild"
    exit 0
fi

SCHEME="${SCHEME:-Cyanide}"
if [ "$SCHEME" = "CyanideVPhone" ]; then
    CONFIG="${CONFIG:-VPhone Debug}"
    if [ "$CONFIG" != "VPhone Debug" ]; then
        echo "error: CyanideVPhone must use CONFIG='VPhone Debug'" >&2
        exit 1
    fi
else
    CONFIG="${CONFIG:-Debug}"
    if [ "$CONFIG" = "VPhone Debug" ]; then
        echo "error: CONFIG='VPhone Debug' is only for SCHEME=CyanideVPhone" >&2
        exit 1
    fi
fi
SDK="${SDK:-iphoneos}"
PROJECT="Cyanide.xcodeproj"
DERIVED="$PWD/build/DerivedData"
case "$SDK" in
    iphoneos*) SDK_PLATFORM="iphoneos" ;;
    iphonesimulator*) SDK_PLATFORM="iphonesimulator" ;;
    *)
        echo "error: unsupported SDK '$SDK' (expected iphoneos* or iphonesimulator*)" >&2
        exit 1
        ;;
esac
PRODUCT_DIR="$DERIVED/Build/Products/${CONFIG}-${SDK_PLATFORM}"
APP_NAME="Cyanide.app"
if [ "$SCHEME" = "CyanideVPhone" ]; then
    IPA_PREFIX="CyanideVPhone"
else
    IPA_PREFIX="Cyanide"
fi
IPA_LATEST="$PWD/build/${IPA_PREFIX}.ipa"
XCODEBUILD_EXTRA=()
DESTINATION=( -destination "generic/platform=iOS" )

if [ "$SDK_PLATFORM" = "iphonesimulator" ]; then
    DESTINATION=( -destination "generic/platform=iOS Simulator" )
    XCODEBUILD_EXTRA+=(ONLY_ACTIVE_ARCH=YES)
    if [ -z "${ARCHS:-}" ]; then
        XCODEBUILD_EXTRA+=(ARCHS=arm64)
    fi
fi
if [ -n "${ARCHS:-}" ]; then
    XCODEBUILD_EXTRA+=("ARCHS=$ARCHS")
fi
if [ -n "${IPHONEOS_DEPLOYMENT_TARGET:-}" ]; then
    XCODEBUILD_EXTRA+=("IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET")
fi
# Extra preprocessor defines for experimental/test builds, e.g.
#   CY_EXTRA_DEFS="CY_TEST_ROBUST_RC_WAIT=1" ./build.sh
# Off by default, so normal builds are unchanged.
if [ -n "${CY_EXTRA_DEFS:-}" ]; then
    XCODEBUILD_EXTRA+=("GCC_PREPROCESSOR_DEFINITIONS=\$(inherited) $CY_EXTRA_DEFS")
fi

mkdir -p build

echo "==> xcodebuild ($SCHEME / $CONFIG / $SDK)"
XCODEBUILD_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -sdk "$SDK"
    -configuration "$CONFIG"
    "${DESTINATION[@]}"
    -derivedDataPath "$DERIVED"
    CODE_SIGNING_ALLOWED=NO
    ${XCODEBUILD_EXTRA[@]+"${XCODEBUILD_EXTRA[@]}"}
    build
)
# One build, piped through xcbeautify when it is installed. The earlier
# "pretty build || plain build" form also ran the whole build a second time
# whenever the first one failed for a real reason (a compile error), doubling
# the wait for the error message. pipefail (set above) keeps xcodebuild's own
# exit status.
if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "${XCODEBUILD_ARGS[@]}" | xcbeautify --quiet
else
    xcodebuild "${XCODEBUILD_ARGS[@]}"
fi

APP_PATH="$PRODUCT_DIR/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "error: $APP_PATH not found after build" >&2
    exit 1
fi

if [ "$SDK_PLATFORM" = "iphonesimulator" ]; then
    echo "==> simulator app $APP_PATH"
    exit 0
fi

if [ "$SCHEME" = "CyanideVPhone" ]; then
    VPHONE_BRIDGE_SRC="$PWD/vphone-assets/vphone_springboard_bridge.dylib"
    VPHONE_BRIDGE_SOURCE="$PWD/vphone-assets/vphone_springboard_bridge.m"
    VPHONE_BRIDGE_DST="$APP_PATH/vphone_springboard_bridge.dylib"
    if [ -f "$VPHONE_BRIDGE_SOURCE" ]; then
        echo "==> building vphone SpringBoard bridge"
        VPHONE_BRIDGE_BUILD="$PWD/build/vphone-bridge"
        VPHONE_BRIDGE_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
        mkdir -p "$VPHONE_BRIDGE_BUILD"
        xcrun --sdk iphoneos clang -arch arm64 \
            -isysroot "$VPHONE_BRIDGE_SDK" \
            -miphoneos-version-min=15.0 \
            -dynamiclib \
            "$VPHONE_BRIDGE_SOURCE" \
            -framework Foundation -framework CoreFoundation -lobjc \
            -install_name @rpath/vphone_springboard_bridge.dylib \
            -o "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64.dylib"
        xcrun --sdk iphoneos clang -arch arm64e \
            -isysroot "$VPHONE_BRIDGE_SDK" \
            -miphoneos-version-min=15.0 \
            -dynamiclib \
            "$VPHONE_BRIDGE_SOURCE" \
            -framework Foundation -framework CoreFoundation -lobjc \
            -install_name @rpath/vphone_springboard_bridge.dylib \
            -o "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64e.dylib"
        lipo -create \
            "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64.dylib" \
            "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64e.dylib" \
            -output "$VPHONE_BRIDGE_SRC"
    fi
    if [ ! -f "$VPHONE_BRIDGE_SRC" ]; then
        echo "error: missing vphone bridge dylib: $VPHONE_BRIDGE_SRC" >&2
        exit 1
    fi
    echo "==> bundling vphone SpringBoard bridge"
    ditto "$VPHONE_BRIDGE_SRC" "$VPHONE_BRIDGE_DST"
    chmod 0755 "$VPHONE_BRIDGE_DST"
    # The bridge is loaded into SpringBoard by TweakLoader. Keep it fat
    # arm64/arm64e and ad-hoc sign it with no entitlements; app/helper
    # entitlements make SpringBoard/AMFI reject the dylib on vphone.
    ldid -S "$VPHONE_BRIDGE_DST"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Info.plist" 2>/dev/null || true)
if [ -z "$VERSION" ]; then
    echo "error: could not read CFBundleShortVersionString from $APP_PATH/Info.plist" >&2
    exit 1
fi

IPA_OUT="$PWD/build/${IPA_PREFIX}-${VERSION}.ipa"
IPA_BASENAME="$(basename "$IPA_OUT")"
LATEST_BASENAME="$(basename "$IPA_LATEST")"

echo "==> packaging $IPA_OUT (version $VERSION)"
STAGE="$(mktemp -d -t cyanide-ipa)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP_PATH" "$STAGE/Payload/"
# Never ship kernel panic dumps or chain logs. Xcode 16's synchronized folder
# group sweeps any loose resource under Cyanide/ into the bundle, and folder
# exceptions do not reliably exclude a subdirectory -- so a crashes/ folder of
# panic .ips (which carry device kernel addresses) keeps ending up in the .app.
# Strip them from the staged Payload unconditionally, whatever their source.
SCRUBBED="$(find "$STAGE/Payload" -type f \( -name '*.ips' -o -name 'chain-*.log' \) -print -delete | wc -l | tr -d ' ')"
if [ "$SCRUBBED" != "0" ]; then
    echo "==> scrubbed $SCRUBBED panic/log file(s) from the bundle before packaging"
fi
rm -f "$IPA_OUT"
( cd "$STAGE" && zip -qry "$IPA_OUT" Payload )

# Keep an unversioned symlink so tooling / README references that expect the
# legacy path still resolve to the latest build.
rm -f "$IPA_LATEST"
( cd "$PWD/build" && ln -s "$IPA_BASENAME" "$LATEST_BASENAME" )

SIZE=$(du -h "$IPA_OUT" | cut -f1)
echo "==> wrote $IPA_OUT ($SIZE)"
echo "==> symlink $IPA_LATEST -> $IPA_BASENAME"

if [ "$SCHEME" = "CyanideVPhone" ]; then
    ARM64_IPA_OUT="$PWD/build/CyanideVPhone-vphone-arm64.ipa"
    ARM64_STAGE="$(mktemp -d -t cyanide-vphone-arm64)"
    trap 'rm -rf "$STAGE" "${ARM64_STAGE:-}"' EXIT
    mkdir -p "$ARM64_STAGE/Payload"
    ditto "$APP_PATH" "$ARM64_STAGE/Payload/Cyanide.app"
    lipo "$ARM64_STAGE/Payload/Cyanide.app/Cyanide" -thin arm64 \
        -output "$ARM64_STAGE/Payload/Cyanide.app/Cyanide.arm64"
    mv "$ARM64_STAGE/Payload/Cyanide.app/Cyanide.arm64" \
        "$ARM64_STAGE/Payload/Cyanide.app/Cyanide"
    chmod +x "$ARM64_STAGE/Payload/Cyanide.app/Cyanide"
    ldid -S"$PWD/scripts/vphone_app.entitlements" \
        "$ARM64_STAGE/Payload/Cyanide.app/Cyanide"
    rm -f "$ARM64_IPA_OUT"
    ( cd "$ARM64_STAGE" && zip -qry "$ARM64_IPA_OUT" Payload )
    ARM64_SIZE=$(du -h "$ARM64_IPA_OUT" | cut -f1)
    echo "==> wrote $ARM64_IPA_OUT ($ARM64_SIZE)"
fi
