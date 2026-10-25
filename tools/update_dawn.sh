#!/usr/bin/env bash
# Imports a Dawn install into this repo and regenerates the Odin bindings.
#
# Usage: tools/update_dawn.sh [DAWN_INSTALL_DIR]
#   DAWN_INSTALL_DIR defaults to ~/dev/c++/dawn/build-vulkan-min/install
#
# Copies include/dawn/{webgpu.h,dawn_version.h} to dawn/include/dawn/ (committed) and
# lib/libwebgpu_dawn.a to lib/linux-x86_64/ (gitignored), then runs tools/gen.
# Environment: ODIN (default: odin from PATH, else ~/dev/odin/Odin/odin)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAWN_INSTALL="${1:-$HOME/dev/c++/dawn/build-vulkan-min/install}"
ODIN="${ODIN:-$(command -v odin || echo "$HOME/dev/odin/Odin/odin")}"

for f in include/dawn/webgpu.h include/dawn/dawn_version.h lib/libwebgpu_dawn.a; do
    if [[ ! -f "$DAWN_INSTALL/$f" ]]; then
        echo "error: $DAWN_INSTALL/$f not found" >&2
        exit 1
    fi
done

mkdir -p "$REPO/dawn/include/dawn" "$REPO/lib/linux-x86_64"
cp "$DAWN_INSTALL/include/dawn/webgpu.h" "$DAWN_INSTALL/include/dawn/dawn_version.h" "$REPO/dawn/include/dawn/"
cp "$DAWN_INSTALL/lib/libwebgpu_dawn.a" "$REPO/lib/linux-x86_64/"

cd "$REPO"
"$ODIN" run tools/gen -out:tools/gen/gen.bin -- \
    dawn/include/dawn/webgpu.h webgpu/webgpu_generated.odin dawn/include/dawn/dawn_version.h
"$ODIN" check webgpu -no-entry-point

echo "Updated to $(grep -E '^// Dawn version' webgpu/webgpu_generated.odin)"
