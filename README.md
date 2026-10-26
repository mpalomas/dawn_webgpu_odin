# dawn_webgpu_odin

Odin bindings for [Dawn](https://dawn.googlesource.com/dawn), Google's WebGPU implementation, linked
statically or as a shared library.

Odin's `vendor:wgpu` targets wgpu-native, whose `webgpu.h` differs from Dawn's: Dawn has its own
extensions, sTypes, features and enum values. These bindings are generated from the `webgpu.h` of the Dawn
build you link against, so they always match it.

Supported: Linux (Vulkan backend, Wayland or X11 surfaces) and macOS (Metal backend).

## Layout

| Path | |
|---|---|
| `webgpu/` | Package `webgpu`. `webgpu_generated.odin` is generated, `webgpu.odin` is hand-written. |
| `glfwglue/` | `GetSurface(instance, window)`: a surface for a `vendor:glfw` window (Wayland or X11 on Linux, a CAMetalLayer on macOS). |
| `tools/gen/` | The generator, `webgpu.h` → Odin, with its tests. |
| `tools/build-vulkan-min.sh` | Builds Dawn for Linux. Copy it to the Dawn checkout's root first. |
| `tools/build-metal-min.sh` | Builds Dawn for macOS, static or shared. Copy it to the Dawn checkout's root first. |
| `tools/update_dawn.sh` | Imports Dawn installs and regenerates the bindings. |
| `dawn/include/dawn/` | Snapshot of the Dawn headers the bindings were generated from. |
| `lib/<os>-<arch>/` | `libwebgpu_dawn.a`, `.so` or `.dylib`, copied by `update_dawn.sh` (`lib/linux-x86_64/`, `lib/macos-arm64/`...). Not committed. |
| `examples/` | `triangle` (rotating triangle) and `cube` (rotating textured cube). `shared/` holds their common setup (not an example itself). |

`webgpu.h` is generated from Dawn's `dawn.json` and has no platform-specific declarations, so one header
snapshot and one generated file serve every platform, provided each platform's Dawn is built from the same
Dawn version. `update_dawn.sh` refuses installs whose `webgpu.h` differ, and a header change shows up in
`git diff` after an import.

## Setup

Build and install Dawn as a monolithic library. The build scripts do size-optimized builds with a single
backend. They use their own location as the Dawn source directory, so copy them to the root of your Dawn
checkout and run them from there.

Linux (static, Vulkan only):

```sh
cp tools/build-vulkan-min.sh ~/dev/c++/dawn/
~/dev/c++/dawn/build-vulkan-min.sh all   # configure, build (Release, -Os), install
tools/update_dawn.sh ~/dev/c++/dawn/build-vulkan-min/install
```

macOS (Metal only, static and/or shared, each in its own build directory):

```sh
cp tools/build-metal-min.sh ~/dev/c++/dawn/
~/dev/c++/dawn/build-metal-min.sh all static   # build-metal-min-static/install/lib/libwebgpu_dawn.a
~/dev/c++/dawn/build-metal-min.sh all shared   # build-metal-min-shared/install/lib/libwebgpu_dawn.dylib
tools/update_dawn.sh ~/dev/c++/dawn/build-metal-min-static/install ~/dev/c++/dawn/build-metal-min-shared/install
```

`update_dawn.sh` takes any number of installs and copies the libraries each one has to `lib/<os>-<arch>/`.
It copies the headers, regenerates `webgpu/webgpu_generated.odin`, and checks the package. Do the same
after updating Dawn, then commit the new header and generated file.

## Examples

Linux:

```sh
odin run examples/triangle -extra-linker-flags:"-Wl,--gc-sections"
odin run examples/cube -extra-linker-flags:"-Wl,--gc-sections"
```

macOS:

```sh
odin run examples/triangle -extra-linker-flags:"-Wl,-dead_strip"
odin run examples/cube -extra-linker-flags:"-Wl,-dead_strip"
```

Space pauses the animation, Esc quits. `--seconds=N` closes the window after N seconds, `--x11` forces
GLFW onto X11 on Linux (needs a Dawn built with `DAWN_USE_X11=ON`; the min build has it off).

`-Wl,--gc-sections` (Linux) and `-Wl,-dead_strip` (macOS) let the linker drop unused Dawn functions.
Built with `-o:size`, each example is about 8.3 MB on Linux (5.7 MB once stripped), and 7.7 MB on macOS
with the static library (4.5 MB stripped).

### Shared library

`-define:DAWN_SHARED=true` links `libwebgpu_dawn.dylib` (macOS) or `libwebgpu_dawn.so` (Linux) instead of
the static library. The program then needs the library at runtime. Odin sets the rpath to the executable's
directory, so either copy the library next to the executable, or add an rpath to `lib/<os>-<arch>/`. From
the repo root, with the executable in its example's directory:

```sh
odin run examples/cube -define:DAWN_SHARED=true -out:examples/cube/cube.bin \
    -extra-linker-flags:"-Wl,-rpath,@loader_path/../../lib/macos-arm64"
```

On Linux, use `$ORIGIN` instead of `@loader_path`, quoted against the shell.

## Using the bindings

From another project, add this repo as a collection:

```sh
odin build . -collection:dawn=/path/to/dawn_webgpu_odin
```

```odin
import wgpu "dawn:webgpu"
import glue "dawn:glfwglue"
```

`-define:DAWN_LIB=<path>` links another Dawn library, static or shared (set `DAWN_SHARED` to match). The
path is relative to `webgpu/`: Odin rejects absolute paths in `foreign import`.

### Distributing binaries

On macOS, Dawn uses the system's libc++ and frameworks, so a statically linked program only needs
`libglfw` (for the glue and examples). A shared build also needs `libwebgpu_dawn.dylib`, found through the
rpath. Set `MACOSX_DEPLOYMENT_TARGET` when building Dawn (and pass `-minimum-os-version` to Odin) to support
macOS versions older than the build machine's.

On Linux, Dawn is C++ and needs the C++ runtime, libstdc++. By default it is linked dynamically, so the
program requires a `libstdc++.so.6` at least as recent as the one it was built with (`GLIBCXX_3.4.35` with
GCC 16), and fails to start on older distributions. `-define:DAWN_STATIC_CXX=true` links `libstdc++.a`
instead (about +0.9 MB), which removes that requirement. It applies to the static Dawn library only.

glibc stays dynamic, and the program requires a glibc at least as recent as the build machine's. To
support older distributions, build Dawn and the program on the oldest one you target (e.g. in a container).
The target also needs `libglfw.so.3` (for the glue and examples) and a Vulkan driver.

### Conventions

The bindings follow `vendor:wgpu`:

- The `WGPU`/`wgpu` prefixes are dropped: `wgpuDeviceCreateBuffer` is `wgpu.DeviceCreateBuffer`.
- Handles are `distinct rawptr`. Enum members starting with a digit get `_`: `._2D`.
- Bitflags are bit sets: `usage = {.Uniform, .CopyDst}` (`BufferUsageFlags`). Multi-bit values are
  constants: `ColorWriteMaskFlags_All`.
- Pointer + count pairs use multi-pointers: `entryCount = len(entries), entries = &entries[0]`.
- Extension structs start with `using chain: ChainedStruct`, so `nextInChain = &source` works.
- Trailing nullable pointer parameters default to `nil`: `wgpu.TextureCreateView(texture)`.
- Dawn's `WGPU_*_INIT` macros are constants with the same defaults: `wgpu.TEXTURE_DESCRIPTOR_INIT`,
  `wgpu.RENDER_PIPELINE_DESCRIPTOR_INIT`... Start from them when a struct has non-zero defaults
  (mip level counts, depth slices, write masks, limits).
- A function named like a type gets a `_` suffix: `wgpu.SharedFenceExportInfo_`.

### Strings

`StringView` is an Odin `string`, which has the same layout. Pass Odin strings directly (`label = "foo"`).

Dawn tells an empty string (`{nil, 0}`) apart from an absent one (`{nil, STRLEN}`, the C default). An
empty Odin string is the former. For optional names that default when absent, such as shader entry points,
either set them or pass `wgpu.STRING_VIEW_NULL()`; the `_INIT` constants leave them empty. Read strings
coming from Dawn with `wgpu.string_from_view`, which handles null-terminated views.

## Tests

```sh
odin test tools/gen
```

Tests each construct of the generator, and checks that `webgpu/webgpu_generated.odin` matches the
committed header.
