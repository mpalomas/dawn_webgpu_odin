#!/usr/bin/env bash
# Minimal, size-oriented Dawn build for macOS: Metal backend only, monolithic lib, static or shared.
#
# Usage: ./build-metal-min.sh <command> [static|shared]
#   configure  Fresh configure (discards the existing CMake cache)
#   build      Build Release, optimized for size
#   install    Install into $INSTALL_DIR
#   all        configure + build + install
#   clean      Delete the build directory
# The second argument picks libwebgpu_dawn.a (static, the default) or libwebgpu_dawn.dylib (shared).
# Each has its own build directory, so both can be built side by side.
#
# Environment overrides:
#   BUILD_DIR                 (default: <dawn>/build-metal-min-<static|shared>)
#   INSTALL_DIR               (default: $BUILD_DIR/install)
#   JOBS                      (default: number of CPUs)
#   MACOSX_DEPLOYMENT_TARGET  Oldest macOS to support (default: the SDK's version), read by CMake

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINKAGE="${2:-static}"
case "$LINKAGE" in
    static) MONOLITHIC=STATIC ;;
    shared) MONOLITHIC=SHARED ;;
    *)
        echo "error: expected static or shared, got '$LINKAGE'" >&2
        exit 1
        ;;
esac
BUILD_DIR="${BUILD_DIR:-$SRC_DIR/build-metal-min-$LINKAGE}"
INSTALL_DIR="${INSTALL_DIR:-$BUILD_DIR/install}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# Release, optimized for size. Not MinSizeRel: Dawn treats every build type but Release and RelWithDebInfo
# as a debug build, which enables its asserts and error injection.
# No -ffunction-sections: Mach-O objects are already split per symbol, so the final app's linker drops
# unused functions with -Wl,-dead_strip (the flags were tried and left the sizes unchanged). The dylib is
# dead-stripped when it is linked.
RELEASE_FLAGS="-Os -DNDEBUG"

configure() {
    cmake -S "$SRC_DIR" -B "$BUILD_DIR" --fresh -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS_RELEASE="$RELEASE_FLAGS" \
        -DCMAKE_CXX_FLAGS_RELEASE="$RELEASE_FLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-dead_strip" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DBUILD_SHARED_LIBS=OFF \
        -DDAWN_BUILD_MONOLITHIC_LIBRARY="$MONOLITHIC" \
        -DDAWN_ENABLE_INSTALL=ON \
        -DDAWN_FETCH_DEPENDENCIES=OFF \
        \
        `# Backends: Metal only` \
        -DDAWN_ENABLE_METAL=ON \
        -DDAWN_ENABLE_VULKAN=OFF \
        -DDAWN_ENABLE_DESKTOP_GL=OFF \
        -DDAWN_ENABLE_OPENGLES=OFF \
        -DDAWN_ENABLE_D3D11=OFF \
        -DDAWN_ENABLE_D3D12=OFF \
        -DDAWN_ENABLE_NULL=OFF \
        -DDAWN_ENABLE_WEBGPU_ON_WEBGPU=OFF \
        -DDAWN_ENABLE_SWIFTSHADER=OFF \
        \
        `# Window systems: surfaces come from a CAMetalLayer, Dawn's GLFW utils are not needed` \
        -DDAWN_USE_WAYLAND=OFF \
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
        `# Tint: WGSL in, MSL out` \
        -DTINT_BUILD_WGSL_READER=ON \
        -DTINT_BUILD_MSL_WRITER=ON \
        -DTINT_BUILD_SPV_READER=OFF \
        -DTINT_BUILD_SPV_WRITER=OFF \
        -DTINT_BUILD_WGSL_WRITER=OFF \
        -DTINT_BUILD_GLSL_WRITER=OFF \
        -DTINT_BUILD_GLSL_VALIDATOR=OFF \
        -DTINT_BUILD_HLSL_WRITER=OFF \
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
    cmake --build "$BUILD_DIR" --config Release -j "$JOBS"
}

install() {
    cmake --install "$BUILD_DIR" --config Release
    ls -lh "$INSTALL_DIR"/lib/libwebgpu_dawn.*
}

case "${1:-}" in
    configure) configure ;;
    build)     build ;;
    install)   install ;;
    all)       configure; build; install ;;
    clean)     rm -rf "$BUILD_DIR" ;;
    *)
        echo "Usage: $0 {configure|build|install|all|clean} [static|shared]" >&2
        exit 1
        ;;
esac
