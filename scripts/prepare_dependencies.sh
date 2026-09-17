#!/bin/bash
# Turn a dependency sysroot into the two directories the app embeds:
#   Dependencies/Frameworks/  dynamic libraries as framework bundles
#   Dependencies/qemu/        firmware blobs handed to QEMU with -L
#
# The dependency build already rewrites every install name to
# @rpath/<name>.framework/<name> and lays the frameworks out under
# <sysroot>/Frameworks, so this only has to copy.
set -euo pipefail

SYSROOT="${1:?usage: prepare_dependencies.sh <sysroot-dir>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HERE/Dependencies"

if [ ! -d "$SYSROOT" ]; then
    echo "error: sysroot not found: $SYSROOT" >&2
    exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"

if [ -d "$SYSROOT/Frameworks" ]; then
    cp -a "$SYSROOT/Frameworks" "$DEST/Frameworks"
fi

# QEMU looks its firmware up through -L, so the blobs are shipped as-is.
for candidate in "$SYSROOT/share/qemu" "$SYSROOT/qemu"; do
    if [ -d "$candidate" ]; then
        cp -a "$candidate" "$DEST/qemu"
        break
    fi
done

if [ ! -d "$DEST/qemu" ]; then
    echo "error: no firmware directory found under $SYSROOT" >&2
    exit 1
fi

for required in \
    "Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu" \
    "qemu/edk2-aarch64-code.fd"
do
    if [ ! -e "$DEST/$required" ]; then
        echo "error: expected artifact missing: $required" >&2
        exit 1
    fi
done

echo "Frameworks: $(ls -1 "$DEST/Frameworks" | wc -l)"
echo "Firmware:   $(ls -1 "$DEST/qemu" | wc -l) file(s)"
du -sh "$DEST"
