# dawn_webgpu_odin

Odin bindings for [Dawn](https://dawn.googlesource.com/dawn), Google's WebGPU implementation, linked
statically or as a shared library. Supported: Linux (Vulkan, Wayland or X11) and macOS (Metal).

The bindings are generated from the `webgpu.h` of the Dawn build you link against, so Dawn's extensions,
features and enum values always match. Otherwise they mirror Odin's `vendor:wgpu` (wgpu-native): same
layout, names and wrappers, so code using the core API builds against either
([Switching to vendor:wgpu](#switching-to-vendorwgpu)).

## Layout

| Path | |
|---|---|
| `wgpu/` | Package `wgpu`: `wgpu_generated.odin` (generated), `wgpu.odin` (library selection, wrappers). |
| `wgpu/glfwglue/` | `GetSurface(instance, window)` for a `vendor:glfw` window. |
| `tools/gen/` | The generator, `webgpu.h` → Odin, with its tests. |
| `tools/build-{vulkan,metal}-min.sh` | Build Dawn for Linux or macOS. Run from the Dawn checkout's root. |
| `tools/update_dawn.sh` | Imports Dawn installs and regenerates the bindings. |
| `tools/dawn_for_chrome.sh` | Finds the Dawn commit of a Chrome release, and checks it out. |
| `tools/compare_vendor_wgpu.py` | Lists the differences with `vendor:wgpu`. |
| `dawn/include/dawn/` | The Dawn headers the bindings were generated from. |
| `lib/<os>-<arch>/` | The Dawn libraries, copied by `update_dawn.sh`. Not committed. |
| `examples/` | `triangle` and `cube`, with their common setup in `shared/`. |

## Setup

Dawn has no releases: Chrome's are the reference. `dawn_for_chrome.sh` finds the Dawn commit of a Chrome
version, milestone or channel through Gitiles, and with `--fetch` makes a shallow checkout of it (`--deps`
adds Dawn's dependencies, about 1.3 GB in all). `--env` prints `KEY=VALUE` lines for CI:

```sh
tools/dawn_for_chrome.sh 156.0.8078.48          # or 156, or stable/beta/dev/canary
tools/dawn_for_chrome.sh --fetch ~/dev/c++/dawn --deps stable
```

The build scripts make size-optimized, single-backend, monolithic Dawn builds. Copy them to your Dawn
checkout's root and run them from there:

```sh
# Linux (static)
cp tools/build-vulkan-min.sh ~/dev/c++/dawn/ && ~/dev/c++/dawn/build-vulkan-min.sh all
tools/update_dawn.sh ~/dev/c++/dawn/build-vulkan-min/install

# macOS (static and/or shared)
cp tools/build-metal-min.sh ~/dev/c++/dawn/
~/dev/c++/dawn/build-metal-min.sh all static
~/dev/c++/dawn/build-metal-min.sh all shared
tools/update_dawn.sh ~/dev/c++/dawn/build-metal-min-static/install ~/dev/c++/dawn/build-metal-min-shared/install
```

`update_dawn.sh` copies the libraries to `lib/<os>-<arch>/` and the headers to `dawn/include/dawn/`,
regenerates the bindings and checks them. Rerun it after updating Dawn and commit the header and generated
file. `webgpu.h` has no platform-specific declarations, so one generated file serves every platform built
from the same Dawn version; the script refuses installs whose `webgpu.h` differ.

## Examples

The examples import `gpu:wgpu`; the `gpu` collection picks the bindings.

```sh
odin run examples/cube -collection:gpu=. -extra-linker-flags:"-Wl,-dead_strip"     # macOS
odin run examples/cube -collection:gpu=. -extra-linker-flags:"-Wl,--gc-sections"   # Linux
odin run examples/cube -collection:gpu=$(odin root)/vendor -define:DAWN=false      # vendor:wgpu
```

The linker flags drop unused Dawn code: with `-o:size`, an example is about 7.7 MB on macOS and 8.3 MB on
Linux (4.5 and 5.7 MB stripped). `-define:DAWN=false` skips the Dawn-only adapter details; `vendor:wgpu`
needs its library in `vendor/wgpu/lib/` (see its `doc.odin`).

Space pauses, Esc quits. `--seconds=N` closes the window after N seconds. `--x11` forces X11 on Linux
(needs a Dawn built with `DAWN_USE_X11=ON`, off in the min build).

## Using the bindings

```sh
odin build . -collection:dawn=/path/to/dawn_webgpu_odin
```

```odin
import "dawn:wgpu"
import glue "dawn:wgpu/glfwglue"
```

Build options:

- `-define:DAWN_SHARED=true` links the shared library. The program finds it through the rpath, which Odin
  sets to the executable's directory: copy the library there, or add one with e.g.
  `-extra-linker-flags:"-Wl,-rpath,@loader_path/../../lib/macos-arm64"` (`$ORIGIN` on Linux).
- `-define:DAWN_LIB=<path>` links another Dawn library, relative to `wgpu/` (`foreign import` rejects
  absolute paths). Set `DAWN_SHARED` to match.
- `-define:DAWN_STATIC_CXX=true` (Linux, static library) links `libstdc++.a` (+0.9 MB), so the program
  runs on distributions with an older `libstdc++.so` than the build machine.

Distributing: on macOS, a static build only needs `libglfw`. Set `MACOSX_DEPLOYMENT_TARGET` when building
Dawn and pass `-minimum-os-version` to Odin to support older macOS versions. On Linux, the program needs a
glibc at least as recent as the build machine's (build on the oldest distribution you target), `libglfw.so.3`
and a Vulkan driver.

### Conventions

As in `vendor:wgpu`:

- Prefixes are dropped: `wgpuDeviceCreateBuffer` is `wgpu.DeviceCreateBuffer`. Enum members starting
  with a digit get `_` (`._2D`). A function named like a type gets a `_` suffix (`SharedFenceExportInfo_`).
- Bitflags are bit sets: `usage = {.Uniform, .CopyDst}`. Multi-bit values are constants
  (`ColorWriteMaskFlags_All`).
- Pointer + count pairs use multi-pointers: `entryCount = len(entries), entries = &entries[0]`.
- Extension structs start with `using chain: ChainedStruct`. Trailing nullable parameters default to `nil`.
- Some functions have Odin wrappers taking slices and returning values: `QueueSubmit(queue, {commands})`,
  `texture := SurfaceGetCurrentTexture(surface)`, `caps, status := SurfaceGetCapabilities(surface,
  adapter)`... The C function is `Raw<Name>`, e.g. `RawAdapterGetInfo(adapter, &info)` to chain structs.
  The list is `RAW_FUNCTIONS` in `tools/gen/emit.odin`.

Dawn only: the `WGPU_*_INIT` macros are constants (`wgpu.TEXTURE_DESCRIPTOR_INIT`...), to start from when
a struct has non-zero defaults.

`StringView` is an Odin `string`: pass strings directly (`label = "foo"`). Dawn tells an empty string
(`{nil, 0}`, what `""` is) apart from an absent one (`{nil, STRLEN}`). For optional names such as shader
entry points, set them or pass `wgpu.STRING_VIEW_NULL()`. Read Dawn's strings with
`wgpu.string_from_view`, which handles null-terminated views.

## Switching to vendor:wgpu

Both packages are a `wgpu` directory with the glue in `wgpu/glfwglue`, so a collection picks the backend:

```odin
import "gpu:wgpu"
import glue "gpu:wgpu/glfwglue"
```

```sh
odin build . -collection:gpu=/path/to/dawn_webgpu_odin   # Dawn
odin build . -collection:gpu=$(odin root)/vendor          # wgpu-native
```

Names, struct layouts, enum values, callbacks and wrappers are the same. To build against both:

- No `_INIT` constants. Set the non-zero defaults: `mipLevelCount = 1, sampleCount = 1` (textures),
  `writeMask = ColorWriteMaskFlags_All` (color targets), `depthSlice = DEPTH_SLICE_UNDEFINED` (color
  attachments), `multisample = {count = 1, mask = 0xFFFFFFFF}` (pipelines), `lodMaxClamp = 32,
  maxAnisotropy = 1` (samplers), stencil masks `0xFFFFFFFF` and `compare = .Always` (depth stencil states).
- No `InstanceWaitAny`, which wgpu-native doesn't implement: use `.AllowProcessEvents` callbacks and
  `InstanceProcessEvents` (see `examples/shared`).
- No `string_from_view`/`STRING_VIEW_NULL`. `vendor:wgpu` misspells `AllowSpontaneous` as
  `AllowSpontaneos`, and its `SurfaceGetCurrentTextureStatus` has an extra `Occluded`.
- Put extensions under a `when` on a `#config` passed with the collection, like the examples' `DAWN`.

`tools/compare_vendor_wgpu.py [--vendor DIR]` lists the differences, worth rerunning after a Dawn or Odin
update.

## Tests

```sh
odin test tools/gen
```

Tests the generator, and checks that `wgpu/wgpu_generated.odin` matches the committed header.
