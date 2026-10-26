#!/usr/bin/env bash
# Imports Dawn installs into this repo and regenerates the Odin bindings.
#
# Usage: tools/update_dawn.sh [DAWN_INSTALL_DIR...]
#   Pass several installs to import both a static and a shared build, e.g.
#     tools/update_dawn.sh ~/dev/c++/dawn/build-metal-min-static/install ~/dev/c++/dawn/build-metal-min-shared/install
#   Defaults to the installs of tools/build-vulkan-min.sh (Linux) or tools/build-metal-min.sh (macOS).
#
# Copies include/dawn/{webgpu.h,dawn_version.h} to dawn/include/dawn/ (committed), the libraries found in
# lib/ (libwebgpu_dawn.a, .so or .dylib) to lib/<os>-<arch>/ (gitignored), then runs tools/gen.
# The installs must have the same webgpu.h: the bindings are generated once for all of them.
# Environment: ODIN (default: odin from PATH, else ~/dev/odin/Odin/odin)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ODIN="${ODIN:-$(command -v odin || echo "$HOME/dev/odin/Odin/odin")}"

case "$(uname -s)" in
    Linux)
        OS=linux
        DEFAULT_INSTALLS=("$HOME/dev/c++/dawn/build-vulkan-min/install")
        ;;
    Darwin)
        OS=macos
        DEFAULT_INSTALLS=("$HOME/dev/c++/dawn/build-metal-min-static/install" "$HOME/dev/c++/dawn/build-metal-min-shared/install")
        ;;
    *) echo "error: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64 | amd64)  ARCH=x86_64 ;;
    arm64 | aarch64) ARCH=arm64 ;;
    *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
LIB_DIR="$REPO/lib/$OS-$ARCH"

if [[ $# -gt 0 ]]; then
    INSTALLS=("$@")
else
    INSTALLS=("${DEFAULT_INSTALLS[@]}")
fi

LIBS=()
for install in "${INSTALLS[@]}"; do
    for f in include/dawn/webgpu.h include/dawn/dawn_version.h; do
        if [[ ! -f "$install/$f" ]]; then
            echo "error: $install/$f not found" >&2
            exit 1
        fi
    done
    if ! cmp -s "$install/include/dawn/webgpu.h" "${INSTALLS[0]}/include/dawn/webgpu.h"; then
        echo "error: $install and ${INSTALLS[0]} have different webgpu.h, they are not the same Dawn version" >&2
        exit 1
    fi
    found=0
    for lib in libwebgpu_dawn.a libwebgpu_dawn.so libwebgpu_dawn.dylib; do
        if [[ -f "$install/lib/$lib" ]]; then
            LIBS+=("$install/lib/$lib")
            found=1
        fi
    done
    if [[ $found == 0 ]]; then
        echo "error: no libwebgpu_dawn library in $install/lib" >&2
        exit 1
    fi
done

mkdir -p "$REPO/dawn/include/dawn" "$LIB_DIR"
cp "${INSTALLS[0]}/include/dawn/webgpu.h" "${INSTALLS[0]}/include/dawn/dawn_version.h" "$REPO/dawn/include/dawn/"
for lib in "${LIBS[@]}"; do
    cp "$lib" "$LIB_DIR/"
    echo "Copied $lib"
done

cd "$REPO"
"$ODIN" run tools/gen -out:tools/gen/gen.bin -- \
    dawn/include/dawn/webgpu.h webgpu/webgpu_generated.odin dawn/include/dawn/dawn_version.h
if [[ -f "$LIB_DIR/libwebgpu_dawn.a" ]]; then
    "$ODIN" check webgpu -no-entry-point
fi
if [[ -f "$LIB_DIR/libwebgpu_dawn.dylib" || -f "$LIB_DIR/libwebgpu_dawn.so" ]]; then
    "$ODIN" check webgpu -no-entry-point -define:DAWN_SHARED=true
fi

echo "Updated to $(grep -E '^// Dawn version' webgpu/webgpu_generated.odin)"
