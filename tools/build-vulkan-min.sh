#!/usr/bin/env bash
# Minimal, size-oriented Dawn build: Vulkan backend only, static monolithic lib.
#
# Usage: ./build-vulkan-min.sh <command>
#   configure  Fresh configure (discards the existing CMake cache)
#   build      Build MinSizeRel
#   install    Install into $INSTALL_DIR
#   all        configure + build + install
#   clean      Delete the build directory
#
# Environment overrides:
#   BUILD_DIR    (default: <dawn>/build-vulkan-min)
#   INSTALL_DIR  (default: $BUILD_DIR/install)
#   JOBS         (default: number of CPUs)

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SRC_DIR/build-vulkan-min}"
INSTALL_DIR="${INSTALL_DIR:-$BUILD_DIR/install}"
JOBS="${JOBS:-$(nproc)}"

# Let the linker of the final app drop unused functions with -Wl,--gc-sections.
SIZE_FLAGS="-ffunction-sections -fdata-sections"

configure() {
    cmake -S "$SRC_DIR" -B "$BUILD_DIR" --fresh -G Ninja \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_C_FLAGS="$SIZE_FLAGS" \
        -DCMAKE_CXX_FLAGS="$SIZE_FLAGS" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DBUILD_SHARED_LIBS=OFF \
        -DDAWN_BUILD_MONOLITHIC_LIBRARY=STATIC \
        -DDAWN_ENABLE_INSTALL=ON \
        -DDAWN_FETCH_DEPENDENCIES=OFF \
        \
        `# Backends: Vulkan only` \
        -DDAWN_ENABLE_VULKAN=ON \
        -DDAWN_ENABLE_DESKTOP_GL=OFF \
        -DDAWN_ENABLE_OPENGLES=OFF \
        -DDAWN_ENABLE_D3D11=OFF \
        -DDAWN_ENABLE_D3D12=OFF \
        -DDAWN_ENABLE_METAL=OFF \
        -DDAWN_ENABLE_NULL=OFF \
        -DDAWN_ENABLE_WEBGPU_ON_WEBGPU=OFF \
        -DDAWN_ENABLE_SWIFTSHADER=OFF \
        \
        `# Window systems` \
        -DDAWN_USE_WAYLAND=ON \
        -DDAWN_USE_X11=OFF \
        -DDAWN_USE_GLFW=OFF \
        \
        `# Debug / test features` \
        -DDAWN_ENABLE_SPIRV_VALIDATION=OFF \
        -DDAWN_ENABLE_ERROR_INJECTION=OFF \
        -DDAWN_ALWAYS_ASSERT=OFF \
        -DDAWN_BUILD_SAMPLES=OFF \
        -DDAWN_BUILD_TESTS=OFF \
        -DDAWN_BUILD_BENCHMARKS=OFF \
        -DDAWN_BUILD_FUZZERS=OFF \
        -DDAWN_BUILD_NODE_BINDINGS=OFF \
        -DDAWN_BUILD_PROTOBUF=OFF \
        \
        `# Tint: WGSL in, SPIR-V out` \
        -DTINT_BUILD_WGSL_READER=ON \
        -DTINT_BUILD_SPV_WRITER=ON \
        -DTINT_BUILD_SPV_READER=OFF \
        -DTINT_BUILD_WGSL_WRITER=ON \
        -DTINT_BUILD_GLSL_WRITER=OFF \
        -DTINT_BUILD_GLSL_VALIDATOR=OFF \
        -DTINT_BUILD_HLSL_WRITER=OFF \
        -DTINT_BUILD_MSL_WRITER=OFF \
        -DTINT_BUILD_NULL_WRITER=OFF \
        -DTINT_BUILD_IR_BINARY=OFF \
        -DTINT_BUILD_CMD_TOOLS=OFF \
        -DTINT_BUILD_TESTS=OFF \
        -DTINT_BUILD_BENCHMARKS=OFF \
        -DTINT_BUILD_FUZZERS=OFF \
        -DTINT_ENABLE_IR_DUMPING=OFF \
        -DTINT_ENABLE_IR_VALIDATION_ASSERTS=OFF
}

build() {
    cmake --build "$BUILD_DIR" --config MinSizeRel -j "$JOBS"
}

install() {
    cmake --install "$BUILD_DIR" --config MinSizeRel
    ls -lh "$INSTALL_DIR"/lib/*.a
}

case "${1:-}" in
    configure) configure ;;
    build)     build ;;
    install)   install ;;
    all)       configure; build; install ;;
    clean)     rm -rf "$BUILD_DIR" ;;
    *)
        echo "Usage: $0 {configure|build|install|all|clean}" >&2
        exit 1
        ;;
esac
