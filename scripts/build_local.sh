#!/bin/bash
# Build PocketVM on a local macOS machine.
#
# Usage: build_local.sh [path-to-UTM.ipa]
#
# The optional IPA supplies the QEMU runtime. That IPA already contains every
# dependency compiled for iOS arm64, so app-level work does not need to rebuild
# them. Without it, pass a sysroot instead with POCKETVM_SYSROOT.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

UTM_IPA="${1:-}"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild not found; install Xcode first" >&2
    exit 1
fi

SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
echo "iOS SDK $SDK_VERSION"
case "$SDK_VERSION" in
    1[89]|2[0-9]) ;;
    *) echo "error: SDK 18 or newer required, found $SDK_VERSION" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- dependencies

if [ -n "${POCKETVM_SYSROOT:-}" ]; then
    echo "Using sysroot $POCKETVM_SYSROOT"
    if [ -d "$POCKETVM_SYSROOT/UTM.app" ]; then
        node scripts/slim_runtime.mjs "$POCKETVM_SYSROOT/UTM.app" "$HERE/Dependencies"
    else
        bash scripts/prepare_dependencies.sh "$POCKETVM_SYSROOT"
    fi
elif [ -n "$UTM_IPA" ]; then
    [ -f "$UTM_IPA" ] || { echo "error: no such IPA: $UTM_IPA" >&2; exit 1; }
    echo "Extracting QEMU runtime from $UTM_IPA"
    rm -rf build-extract
    mkdir -p build-extract
    unzip -q "$UTM_IPA" 'Payload/UTM.app/Frameworks/*' 'Payload/UTM.app/qemu/*' -d build-extract
    APP="build-extract/Payload/UTM.app"
    # UTM's IPA carries every architecture it can emulate, so the runtime is
    # reduced here rather than shipped whole.
    node scripts/slim_runtime.mjs "$PWD/$APP" "$PWD/Dependencies"
    test -f Dependencies/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu
    test -f Dependencies/qemu/edk2-aarch64-code.fd
else
    echo "error: pass a UTM IPA, or set POCKETVM_SYSROOT" >&2
    exit 1
fi

# ---------------------------------------------------------------------- build

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen missing; installing with Homebrew"
    brew install xcodegen
fi

xcodegen generate

xcodebuild -project PocketVM.xcodeproj -scheme PocketVM \
    -configuration Release -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -archivePath "$PWD/PocketVM.xcarchive" archive \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee app-build.log

# -------------------------------------------------------------------- package

APP="PocketVM.xcarchive/Products/Applications/PocketVM.app"
test -f "$APP/PocketVM"
test -f "$APP/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
test -f "$APP/qemu/edk2-aarch64-code.fd"
xcrun lipo "$APP/PocketVM" -verify_arch arm64

rm -rf package
mkdir -p package/Payload
ditto "$APP" package/Payload/PocketVM.app
(cd package && zip -qry ../PocketVM.ipa Payload)
unzip -tq PocketVM.ipa
shasum -a 256 PocketVM.ipa | tee SHA256SUMS
echo "Built $HERE/PocketVM.ipa"
