# dawn_webgpu_odin

Odin bindings for [Dawn](https://dawn.googlesource.com/dawn), Google's WebGPU implementation, linked
statically or as a shared library. Supported: Linux (Vulkan, Wayland or X11), macOS (Metal) and Windows
(D3D12).

The bindings are generated from the `webgpu.h` of the Dawn build you link against, so Dawn's extensions,
features and enum values always match. Otherwise they mirror Odin's `vendor:wgpu` (wgpu-native): same
layout, names and wrappers, so code using the core API builds against either
([Switching to vendor:wgpu](#switching-to-vendorwgpu)).

## Layout

| Path | |
|---|---|
| `wgpu/` | The `wgpu` package (generated bindings, library selection, wrappers) and `glfwglue/`, the `vendor:glfw` surface helper. |
| `tools/` | The generator (`gen/`, `webgpu.h` → Odin) and the scripts that build, import and fetch Dawn. |
| `dawn/` | The Dawn headers the bindings were generated from, and `release.env`, the release whose libraries match. |
| `lib/` | The Dawn libraries per platform. Not committed. |
| `examples/` | `triangle` and `cube`, with their common setup in `shared/`. |

## Setup

The quick way: download the prebuilt libraries of the release pinned in `dawn/release.env`, built for Linux x86_64 (glibc 2.39+), macOS arm64 (13+) and Windows x86_64
(10+):

```sh
tools/fetch_dawn_libs.sh                 # this machine's platform, or e.g. linux-x86_64 macos-arm64
```

```powershell
tools\fetch_dawn_libs.ps1                # Windows (PowerShell 7), or e.g. windows-x86_64 linux-x86_64
```

They use `gh` if it is installed and logged in, else curl or `Invoke-WebRequest`.

### Building Dawn

Dawn has no releases: Chrome's are the reference. `dawn_for_chrome.sh` finds the Dawn commit of a Chrome
version, milestone or channel through Gitiles, and with `--fetch` makes a shallow checkout of it (`--deps`
adds Dawn's dependencies, about 1.3 GB in all). `--env` prints `KEY=VALUE` lines for CI:

```sh
tools/dawn_for_chrome.sh 156.0.8078.48          # or 156, or stable/beta/dev/canary
tools/dawn_for_chrome.sh --fetch ~/dev/c++/dawn --deps stable
```

On Windows, `dawn_for_chrome.ps1` does the same, with `-Fetch`, `-Deps`, `-Env` and `-Platform`. It needs
git and, for `-Deps`, Python (`python3`, or `python`: Windows' `python3` alias of the Microsoft Store is
skipped). Set `git config --global core.longpaths true`, Dawn's dependencies have long paths:

```powershell
tools\dawn_for_chrome.ps1 -Fetch ~\dev\c++\dawn -Deps stable
```

The build scripts make size-optimized, single-backend, monolithic Dawn builds. Copy them to your Dawn
checkout's root and run them from there:

```sh
cp tools/build-metal-min.sh ~/dev/c++/dawn/      # macOS; build-vulkan-min.sh on Linux
~/dev/c++/dawn/build-metal-min.sh all static     # and/or: all shared
tools/update_dawn.sh                             # imports ~/dev/c++/dawn/build-*-min-{static,shared}/install
```

```powershell
Copy-Item tools\build-d3d12-min.ps1 ~\dev\c++\dawn\   # Windows, PowerShell 7
~\dev\c++\dawn\build-d3d12-min.ps1 all static         # and/or: all shared
tools\update_dawn.ps1                                   # imports ~\dev\c++\dawn\build-d3d12-min-{static,shared}\install
```

The Windows build needs Visual Studio with the C++ tools, CMake and Ninja. It links the static C runtime
(`/MT`), so the DLL needs no Visual C++ redistributable.

`update_dawn.sh` (or `.ps1`) copies the libraries to `lib/<os>-<arch>/` and the headers to `dawn/include/dawn/`,
and regenerates the bindings. Rerun it after updating Dawn and commit the header and generated file. It
refuses installs whose `webgpu.h` differ, since one generated file serves every platform of a Dawn version.

## Examples

The examples import `gpu:wgpu`; the `gpu` collection picks the bindings.

```sh
odin run examples/cube -collection:gpu=. -extra-linker-flags:"-Wl,-dead_strip"     # macOS
odin run examples/cube -collection:gpu=. -extra-linker-flags:"-Wl,--gc-sections"   # Linux
odin run examples/cube -collection:gpu=.                                           # Windows
odin run examples/cube -collection:gpu=$(odin root)/vendor -define:DAWN=false      # vendor:wgpu
```

The linker flags drop unused Dawn code (link.exe does by default). `-define:DAWN=false` skips the Dawn-only
adapter details; `vendor:wgpu` needs its library in `vendor/wgpu/lib/` (see its `doc.odin`).

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
  `-extra-linker-flags:"-Wl,-rpath,@loader_path/../../lib/macos-arm64"` (`$ORIGIN` on Linux). On Windows,
  copy `webgpu_dawn.dll` next to the executable (or put it on the `PATH`).
- `-define:DAWN_LIB=<path>` links another Dawn library, relative to `wgpu/` (`foreign import` rejects
  absolute paths). Set `DAWN_SHARED` to match.
- `-define:DAWN_STATIC_CXX=true` (Linux, static library) links `libstdc++.a` (+0.9 MB), so the program
  runs on distributions with an older `libstdc++.so` than the build machine.

Distributing: on macOS, a static build only needs `libglfw`; set `MACOSX_DEPLOYMENT_TARGET` when building
Dawn and pass `-minimum-os-version` to Odin to support older versions. On Linux, the program needs a glibc
at least as recent as the build machine's, `libglfw.so.3` and a Vulkan driver. On Windows, a static build
is a single executable.

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

## License

The bindings, tools and examples are MIT-licensed ([LICENSE](LICENSE)). Dawn, its headers in `dawn/include/`
and the prebuilt libraries are under Dawn's own licenses, in [dawn/LICENSE](dawn/LICENSE) (BSD 3-Clause,
with Apache-2.0 for some parts). The library archives include that file.
