#!/usr/bin/env bash
# Build Cyanide for iphoneos and package the resulting .app into a versioned IPA
# under build/, e.g. build/Cyanide-1.0.14.ipa, with a build/Cyanide.ipa
# symlink pointing at the latest build. With SDK=iphonesimulator, build the
# simulator .app and skip IPA packaging.
#
# Run as: ./scripts/build.sh
# Override defaults with env vars:
#   SCHEME, CONFIG (Debug|Release|VPhone Debug), SDK (iphoneos|iphonesimulator)
#
# The version comes from CFBundleShortVersionString in the built Info.plist
# (= the MARKETING_VERSION build setting in the xcodeproj). Bump
# MARKETING_VERSION to ship a new version.
#
# The main binary and the bundled exploit dylib are ad-hoc signed WITH the
# platform entitlements embedded (see the iphoneos block below) so the IPA is
# TrollStore-ready out of the box. TrollStore preserves/grants platform-application
# + no-sandbox on install; plain sideloaders (AltStore/Sideloadly) cannot grant
# those and the kernel exploit will fail — Cyanide is TrollStore-only by design.

set -euo pipefail

cd "$(dirname "$0")/.."

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
PRODUCT_DIR="$DERIVED/Build/Products/${CONFIG}-${SDK}"
APP_NAME="Cyanide.app"
if [ "$SCHEME" = "CyanideVPhone" ]; then
    IPA_PREFIX="CyanideVPhone"
else
    IPA_PREFIX="Cyanide"
fi
IPA_LATEST="$PWD/build/${IPA_PREFIX}.ipa"
XCODEBUILD_EXTRA=()

if [ "$SDK" = "iphonesimulator" ]; then
    XCODEBUILD_EXTRA=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
fi

mkdir -p build

echo "==> xcodebuild ($SCHEME / $CONFIG / $SDK)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -sdk "$SDK" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    ${XCODEBUILD_EXTRA[@]+"${XCODEBUILD_EXTRA[@]}"} \
    build \
    | xcbeautify --quiet 2>/dev/null \
    || xcodebuild \
         -project "$PROJECT" \
         -scheme "$SCHEME" \
         -sdk "$SDK" \
         -configuration "$CONFIG" \
         -derivedDataPath "$DERIVED" \
         CODE_SIGNING_ALLOWED=NO \
         ${XCODEBUILD_EXTRA[@]+"${XCODEBUILD_EXTRA[@]}"} \
         build

APP_PATH="$PRODUCT_DIR/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "error: $APP_PATH not found after build" >&2
    exit 1
fi

# Cyanide's kernel exploit (KRW) needs platform-application + no-sandbox +
# task_for_pid-allow to perform privileged memory operations (mach_vm_allocate
# of the 1GB search mapping, RemoteCall shmem, etc.). These entitlements can
# ONLY be honoured by TrollStore's signing; free-dev sideloading (AltStore /
# Sideloadly) strips them and the exploit then fails with "no space available"
# during RemoteCall, which silently breaks PERSIST and App Downgrade.
#
# Embed the entitlement blob into the main binary with Apple codesign (NOT ldid
# — ldid 2.1.x on macOS 15 emits an empty LC_CODE_SIGNATURE superblob that iOS
# rejects at dlopen). TrollStore preserves/grants these on install; a plain
# sideloader will re-sign and (correctly) cannot grant platform-application, so
# the app stays TrollStore-only, which is its intended and only supported path.
if [ "$SDK" = "iphoneos" ]; then
    echo "==> embedding platform entitlements into $APP_NAME (TrollStore-ready)"
    codesign --force --sign - \
        --entitlements "$PWD/scripts/vphone_app.entitlements" \
        "$APP_PATH/Cyanide" \
        || echo "WARN: codesign of main binary failed; relying on the sideloader to apply entitlements"
    # Re-sign the bundled exploit dylib with the same entitlements so TrollStore
    # does not strip its loadable status.
    if [ -f "$APP_PATH/libxpf.dylib" ]; then
        codesign --force --sign - \
            --entitlements "$PWD/scripts/vphone_app.entitlements" \
            "$APP_PATH/libxpf.dylib" \
            || echo "WARN: codesign of libxpf.dylib failed"
    fi
fi

if [ "$SDK" = "iphonesimulator" ]; then
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
