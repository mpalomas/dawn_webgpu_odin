<#
Minimal, size-oriented Dawn build for Windows: D3D12 backend only, monolithic lib, static or shared.

Usage: .\build-d3d12-min.ps1 <command> [static|shared]
  configure  Fresh configure (discards the existing CMake cache)
  build      Build Release, optimized for size
  install    Install into $env:INSTALL_DIR
  all        configure + build + install
  clean      Delete the build directory
The second argument picks lib\webgpu_dawn.lib (static, the default) or bin\webgpu_dawn.dll with its import
library lib\webgpu_dawn.lib (shared; tools\update_dawn.ps1 imports it as webgpu_dawn.dll.lib). Each has its
own build directory, so both can be built side by side.

Runs in a Visual Studio developer environment: when cl is not on the PATH, enters the one of the latest
Visual Studio with the C++ tools (found with vswhere).

Environment overrides:
  BUILD_DIR    (default: <dawn>\build-d3d12-min-<static|shared>)
  INSTALL_DIR  (default: $BUILD_DIR\install)
  JOBS         (default: number of CPUs)
  CC, CXX      (default: cl; clang-cl works too)
#>
param(
    [Parameter(Position = 0)] [string] $Command,
    [Parameter(Position = 1)] [ValidateSet('static', 'shared')] [string] $Linkage = 'static'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$SrcDir = $PSScriptRoot
$Monolithic = $Linkage.ToUpperInvariant()
$BuildDir = $env:BUILD_DIR ? $env:BUILD_DIR : (Join-Path $SrcDir "build-d3d12-min-$Linkage")
$InstallDir = $env:INSTALL_DIR ? $env:INSTALL_DIR : (Join-Path $BuildDir 'install')
$Jobs = $env:JOBS ? $env:JOBS : [Environment]::ProcessorCount

# Release, optimized for size (/O1 includes /Gy, a section per function). Not MinSizeRel: Dawn treats every
# build type but Release and RelWithDebInfo as a debug build, which enables its asserts and error injection.
# /Gw also gives each global variable its section, so that the final app's linker drops unused code and
# data (link.exe's /OPT:REF, its default without /DEBUG), and Dawn's link for the DLL. No /GL: the objects
# of the static library would then only link with the same compiler version.
$ReleaseFlags = '/O1 /Gw /DNDEBUG'

function Enter-DevShell {
    if (Get-Command cl -ErrorAction SilentlyContinue) {
        return
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        $vswhere = (Get-Command vswhere -ErrorAction SilentlyContinue)?.Source
    }
    if (-not $vswhere) {
        throw 'cl is not on the PATH and vswhere is not installed: run from a Visual Studio developer shell'
    }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) {
        throw 'no Visual Studio with the C++ tools (Microsoft.VisualStudio.Component.VC.Tools.x86.x64) found'
    }
    Write-Host "Entering the developer environment of $vs"
    Import-Module (Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -Arch amd64 -HostArch amd64 | Out-Null
}

function Invoke-Configure {
    Enter-DevShell
    $options = @(
        '-DCMAKE_BUILD_TYPE=Release'
        "-DCMAKE_C_FLAGS_RELEASE=$ReleaseFlags"
        "-DCMAKE_CXX_FLAGS_RELEASE=$ReleaseFlags"
        "-DCMAKE_C_COMPILER=$($env:CC ? $env:CC : 'cl')"
        "-DCMAKE_CXX_COMPILER=$($env:CXX ? $env:CXX : 'cl')"
        # The static C runtime (/MT), as Odin's default (libcmt) and vendor:glfw's glfw3_mt.lib. The DLL then
        # needs no Visual C++ redistributable either.
        '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded'
        # Abseil overrides CMAKE_MSVC_RUNTIME_LIBRARY, with the DLL runtime by default.
        '-DABSL_MSVC_STATIC_RUNTIME=ON'
        '-DCMAKE_SHARED_LINKER_FLAGS=/OPT:REF /OPT:ICF'
        "-DCMAKE_INSTALL_PREFIX=$InstallDir"
        '-DBUILD_SHARED_LIBS=OFF'
        "-DDAWN_BUILD_MONOLITHIC_LIBRARY=$Monolithic"
        '-DDAWN_ENABLE_INSTALL=ON'
        '-DDAWN_FETCH_DEPENDENCIES=OFF'

        # Backends: D3D12 only. Shaders compile with FXC, d3dcompiler_47.dll: Windows' own, from System32.
        # By default Dawn only loads the one next to the program (as Chrome ships the Windows SDK's, which
        # has fixes that the copy of older Windows 10 releases lacks), which programs would then have to ship.
        '-DDAWN_FORCE_SYSTEM_COMPONENT_LOAD=ON'
        '-DDAWN_ENABLE_D3D12=ON'
        '-DDAWN_ENABLE_D3D11=OFF'
        '-DDAWN_ENABLE_VULKAN=OFF'
        '-DDAWN_ENABLE_DESKTOP_GL=OFF'
        '-DDAWN_ENABLE_OPENGLES=OFF'
        '-DDAWN_ENABLE_METAL=OFF'
        '-DDAWN_ENABLE_NULL=OFF'
        '-DDAWN_ENABLE_WEBGPU_ON_WEBGPU=OFF'
        '-DDAWN_ENABLE_SWIFTSHADER=OFF'
        '-DDAWN_USE_BUILT_DXC=OFF'

        # Window systems: surfaces come from an HWND, no Windows UI (CoreWindow, SwapChainPanel)
        '-DDAWN_USE_WINDOWS_UI=OFF'
        '-DDAWN_USE_GLFW=OFF'

        # Debug / test features
        '-DDAWN_ENABLE_SPIRV_VALIDATION=OFF'
        '-DDAWN_ENABLE_ERROR_INJECTION=OFF'
        '-DDAWN_ALWAYS_ASSERT=OFF'
        '-DDAWN_BUILD_SAMPLES=OFF'
        '-DDAWN_BUILD_TESTS=OFF'
        '-DDAWN_BUILD_BENCHMARKS=OFF'
        '-DDAWN_BUILD_FUZZERS=OFF'
        '-DDAWN_BUILD_NODE_BINDINGS=OFF'
        '-DDAWN_BUILD_PROTOBUF=OFF'

        # Tint: WGSL in, HLSL out
        '-DTINT_BUILD_WGSL_READER=ON'
        '-DTINT_BUILD_HLSL_WRITER=ON'
        '-DTINT_BUILD_SPV_READER=OFF'
        '-DTINT_BUILD_SPV_WRITER=OFF'
        '-DTINT_BUILD_WGSL_WRITER=OFF'
        '-DTINT_BUILD_GLSL_WRITER=OFF'
        '-DTINT_BUILD_GLSL_VALIDATOR=OFF'
        '-DTINT_BUILD_MSL_WRITER=OFF'
        '-DTINT_BUILD_NULL_WRITER=OFF'
        '-DTINT_BUILD_IR_BINARY=OFF'
        '-DTINT_BUILD_CMD_TOOLS=OFF'
        '-DTINT_BUILD_TESTS=OFF'
        '-DTINT_BUILD_BENCHMARKS=OFF'
        '-DTINT_BUILD_FUZZERS=OFF'
        '-DTINT_ENABLE_IR_DUMPING=OFF'
        '-DTINT_ENABLE_IR_VALIDATION_ASSERTS=OFF'
    )
    cmake -S $SrcDir -B $BuildDir --fresh -G Ninja @options
}

function Invoke-Build {
    Enter-DevShell
    cmake --build $BuildDir --config Release -j $Jobs
}

function Invoke-Install {
    cmake --install $BuildDir --config Release
    Get-ChildItem (Join-Path $InstallDir 'lib\webgpu_dawn*'), (Join-Path $InstallDir 'bin\webgpu_dawn*') -ErrorAction SilentlyContinue |
        Format-Table Name, @{ n = 'MB'; e = { '{0:N1}' -f ($_.Length / 1MB) } }, FullName -AutoSize
}

switch ($Command) {
    'configure' { Invoke-Configure }
    'build' { Invoke-Build }
    'install' { Invoke-Install }
    'all' { Invoke-Configure; Invoke-Build; Invoke-Install }
    'clean' { if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir } }
    default {
        Write-Error "Usage: $PSCommandPath {configure|build|install|all|clean} [static|shared]" -ErrorAction Continue
        exit 1
    }
}
