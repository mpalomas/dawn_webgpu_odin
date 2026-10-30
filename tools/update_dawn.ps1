<#
Imports Dawn installs into this repo and regenerates the Odin bindings. The Windows version of
update_dawn.sh.

Usage: tools\update_dawn.ps1 [DAWN_INSTALL_DIR...]
  Pass several installs to import both a static and a shared build, e.g.
    tools\update_dawn.ps1 ~\dev\c++\dawn\build-d3d12-min-static\install ~\dev\c++\dawn\build-d3d12-min-shared\install
  Defaults to the installs of tools\build-d3d12-min.ps1 that exist, static and shared, in ~\dev\c++\dawn.

Copies include\dawn\{webgpu.h,dawn_version.h} to dawn\include\dawn\ (committed, with LF line endings; older
Dawns, such as Chrome release branches before M158, install no dawn_version.h), the libraries to
lib\windows-<arch>\ (gitignored), then runs tools\gen. A static install has lib\webgpu_dawn.lib, copied as is.
A shared one has bin\webgpu_dawn.dll and its import library lib\webgpu_dawn.lib, copied as webgpu_dawn.dll.lib
(as vendor:wgpu names wgpu-native's), since both are linked from the same directory. The installs must have the same webgpu.h: the bindings are generated once for all of them.
Environment: ODIN (default: odin from PATH)
#>
param(
    [Parameter(ValueFromRemainingArguments)] [string[]] $Installs
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Repo = Split-Path -Parent $PSScriptRoot
$Odin = $env:ODIN ? $env:ODIN : 'odin'

if (-not $IsWindows) {
    throw 'update_dawn.ps1 imports Windows builds: use tools/update_dawn.sh on Linux and macOS'
}
$Arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x86_64' }
    'Arm64' { 'arm64' }
    default { throw "unsupported architecture $_" }
}
$LibDir = Join-Path $Repo "lib\windows-$Arch"

if (-not $Installs) {
    $defaults = 'static', 'shared' | ForEach-Object { Join-Path $HOME "dev\c++\dawn\build-d3d12-min-$_\install" }
    $Installs = @($defaults | Where-Object { Test-Path $_ -PathType Container })
    if (-not $Installs) {
        throw "no Dawn install found in $($defaults -join ', '), pass the install directories"
    }
}
$Installs = @($Installs | ForEach-Object { (Resolve-Path $_).Path })

# Header comparisons ignore line endings, which depend on how the Dawn checkout was made.
function Read-LF([string] $Path) {
    [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
}

$header = Join-Path $Installs[0] 'include\dawn\webgpu.h'
$libs = @()
foreach ($install in $Installs) {
    $h = Join-Path $install 'include\dawn\webgpu.h'
    if (-not (Test-Path $h)) {
        throw "$h not found"
    }
    if ((Read-LF $h) -cne (Read-LF $header)) {
        throw "$install and $($Installs[0]) have different webgpu.h, they are not the same Dawn version"
    }
    $lib = Join-Path $install 'lib\webgpu_dawn.lib'
    $dll = Join-Path $install 'bin\webgpu_dawn.dll'
    if (-not (Test-Path $lib)) {
        throw "no $lib"
    }
    if (Test-Path $dll) {
        $libs += @{ From = $dll; Name = 'webgpu_dawn.dll' }, @{ From = $lib; Name = 'webgpu_dawn.dll.lib' }
    } else {
        $libs += @{ From = $lib; Name = 'webgpu_dawn.lib' }
    }
}

$includeDir = Join-Path $Repo 'dawn\include\dawn'
New-Item -ItemType Directory -Force $includeDir, $LibDir | Out-Null
[IO.File]::WriteAllText((Join-Path $includeDir 'webgpu.h'), (Read-LF $header))
$genArgs = @('dawn/include/dawn/webgpu.h', 'wgpu/wgpu_generated.odin')
$versionH = Join-Path $Installs[0] 'include\dawn\dawn_version.h'
if (Test-Path $versionH) {
    [IO.File]::WriteAllText((Join-Path $includeDir 'dawn_version.h'), (Read-LF $versionH))
    $genArgs += 'dawn/include/dawn/dawn_version.h'
} else {
    # Don't leave the header of another Dawn version behind.
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $includeDir 'dawn_version.h')
}
foreach ($lib in $libs) {
    Copy-Item $lib.From (Join-Path $LibDir $lib.Name)
    Write-Host "Copied $($lib.From) to lib\windows-$Arch\$($lib.Name)"
}

Push-Location $Repo
try {
    & $Odin run tools/gen -out:tools/gen/gen.exe -- @genArgs
    if (Test-Path (Join-Path $LibDir 'webgpu_dawn.lib')) {
        & $Odin check wgpu -no-entry-point
    }
    if (Test-Path (Join-Path $LibDir 'webgpu_dawn.dll.lib')) {
        & $Odin check wgpu -no-entry-point -define:DAWN_SHARED=true
    }
    $version = Select-String -Path wgpu/wgpu_generated.odin -Pattern '^// Dawn version' -List
    Write-Host "Updated to $($version ? $version.Line : 'a Dawn without dawn_version.h')"
} finally {
    Pop-Location
}
