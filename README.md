# dawn_webgpu_odin

Odin bindings for [Dawn](https://dawn.googlesource.com/dawn), Google's WebGPU implementation, linked statically.

Odin's `vendor:wgpu` targets wgpu-native, whose `webgpu.h` differs from Dawn's: Dawn has its own
extensions, sTypes, features and enum values. These bindings are generated from the `webgpu.h` of the Dawn
build you link against, so they always match it.

Linux only for now (Vulkan backend, Wayland surfaces).

## Layout

| Path | |
|---|---|
| `webgpu/` | Package `webgpu`. `webgpu_generated.odin` is generated, `webgpu.odin` is hand-written. |
| `glfwglue/` | `GetSurface(instance, window)`: a surface for a `vendor:glfw` window (Wayland or X11). |
| `tools/gen/` | The generator, `webgpu.h` → Odin, with its tests. |
| `tools/update_dawn.sh` | Imports a Dawn install and regenerates the bindings. |
| `dawn/include/dawn/` | Snapshot of the Dawn headers the bindings were generated from. |
| `lib/linux-x86_64/` | `libwebgpu_dawn.a`, copied by `update_dawn.sh`. Not committed (about 50 MB). |
| `examples/` | `triangle` (rotating triangle) and `cube` (rotating textured cube). `app/` holds their shared setup. |

## Setup

Build and install Dawn as a static monolithic library, e.g. with `build-vulkan-min.sh` from the Dawn
checkout, then import it:

```sh
tools/update_dawn.sh ~/dev/c++/dawn/build-vulkan-min/install
```

This copies the header and the library, regenerates `webgpu/webgpu_generated.odin`, and checks the
package. Do the same after updating Dawn, then commit the new header and generated file.

## Examples

```sh
odin run examples/triangle -extra-linker-flags:"-Wl,--gc-sections"
odin run examples/cube -extra-linker-flags:"-Wl,--gc-sections"
```

Space pauses the animation, Esc quits. `--seconds=N` closes the window after N seconds, `--x11` forces
GLFW onto X11 (needs a Dawn built with `DAWN_USE_X11=ON`; the min build has it off).

`-Wl,--gc-sections` lets the linker drop unused Dawn functions (Dawn is built with `-ffunction-sections`).
Built with `-o:size`, each example is about 8.3 MB, 5.7 MB once stripped.

## Using the bindings

From another project, add this repo as a collection:

```sh
odin build . -collection:dawn=/path/to/dawn_webgpu_odin
```

```odin
import wgpu "dawn:webgpu"
import glue "dawn:glfwglue"
```

`-define:DAWN_LIB=<path>` links another `libwebgpu_dawn.a`.

### Distributing binaries

Dawn is C++ and needs the C++ runtime, libstdc++. By default it is linked dynamically, so the program
requires a `libstdc++.so.6` at least as recent as the one it was built with (`GLIBCXX_3.4.35` with GCC 16),
and fails to start on older distributions. `-define:DAWN_STATIC_CXX=true` links `libstdc++.a` instead
(about +0.9 MB), which removes that requirement.

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
