<#
Downloads the prebuilt Dawn libraries that match the committed bindings into lib\<os>-<arch>\, from the
GitHub release named in dawn\release.env (written by .github\workflows\build-dawn.yml). The Windows version
of fetch_dawn_libs.sh.

Usage: tools\fetch_dawn_libs.ps1 [PLATFORM...]
  PLATFORM  windows-x86_64, linux-x86_64 or macos-arm64 (default: this machine's)

Checks the release's webgpu.h against dawn\include\dawn\webgpu.h and the downloads against the release's
SHA256SUMS. Uses gh when it is installed and logged in (required while the repository is private), else
Invoke-WebRequest.
Environment:
  DAWN_RELEASE_REPO  (default: mpalomas/dawn_webgpu_odin)
  DAWN_RELEASE_URL   Base URL of the release downloads, without gh (default: the repository's releases)
#>
param(
    [Parameter(ValueFromRemainingArguments)] [string[]] $Platforms
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
# Invoke-WebRequest's progress bar slows downloads down a lot.
$ProgressPreference = 'SilentlyContinue'

$Repo = Split-Path -Parent $PSScriptRoot
$Slug = $env:DAWN_RELEASE_REPO ? $env:DAWN_RELEASE_REPO : 'mpalomas/dawn_webgpu_odin'
$BaseUrl = $env:DAWN_RELEASE_URL ? $env:DAWN_RELEASE_URL : "https://github.com/$Slug/releases/download"
$Pin = Join-Path $Repo 'dawn\release.env'

if (-not (Test-Path $Pin)) {
    throw "no $Pin`: the committed bindings do not come from a release. Build Dawn and run tools\update_dawn.ps1"
}
$Tag = (Select-String -Path $Pin -Pattern '^RELEASE_TAG=(.+)$' -List)?.Matches[0].Groups[1].Value
if (-not $Tag) {
    throw "no RELEASE_TAG in $Pin"
}

if (-not $Platforms) {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'x86_64' }
        'Arm64' { 'arm64' }
        default { throw "unsupported architecture $_" }
    }
    $Platforms = @("$os-$arch")
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory $tmp | Out-Null
try {
    $files = @('webgpu.h', 'SHA256SUMS') + @($Platforms | ForEach-Object { "dawn-$_.tar.gz" })
    Write-Host "Downloading $($files -join ' ') from release $Tag of $Slug"
    $gh = -not $env:DAWN_RELEASE_URL -and (Get-Command gh -ErrorAction SilentlyContinue)
    if ($gh) {
        gh auth status *> $null
        $gh = $LASTEXITCODE -eq 0
    }
    if ($gh) {
        $patterns = $files | ForEach-Object { '--pattern', $_ }
        gh release download $Tag --repo $Slug --dir $tmp @patterns
    } else {
        foreach ($f in $files) {
            try {
                Invoke-WebRequest "$BaseUrl/$Tag/$f" -OutFile (Join-Path $tmp $f) -MaximumRetryCount 3
            } catch {
                throw "cannot download $f (a private repository needs gh, logged in): $_"
            }
        }
    }
    foreach ($f in $files) {
        if (-not (Test-Path (Join-Path $tmp $f))) {
            throw "release $Tag has no $f"
        }
    }

    # SHA256SUMS lines: <hash> <name>, or <hash> *<name> (binary mode).
    $sums = @{}
    foreach ($line in Get-Content (Join-Path $tmp 'SHA256SUMS')) {
        if ($line -match '^([0-9a-fA-F]{64}) [ *](.+)$') {
            $sums[$Matches[2]] = $Matches[1]
        }
    }
    foreach ($f in $files | Where-Object { $_ -ne 'SHA256SUMS' }) {
        if (-not $sums.ContainsKey($f)) {
            throw "$f is not in the release's SHA256SUMS"
        }
        if ((Get-FileHash -Algorithm SHA256 (Join-Path $tmp $f)).Hash -ne $sums[$f].ToUpperInvariant()) {
            throw "checksum mismatch for $f"
        }
    }

    # Line endings aside: the checkout's depend on Git's settings.
    $released = [IO.File]::ReadAllText((Join-Path $tmp 'webgpu.h')) -replace "`r`n", "`n"
    $committed = [IO.File]::ReadAllText((Join-Path $Repo 'dawn\include\dawn\webgpu.h')) -replace "`r`n", "`n"
    if ($released -cne $committed) {
        throw "dawn\include\dawn\webgpu.h differs from release $Tag's: the bindings were regenerated since. Build Dawn and run tools\update_dawn.ps1"
    }

    foreach ($platform in $Platforms) {
        # The archives hold lib/<platform>/<libraries>. tar is part of Windows 10 and later.
        tar -xzf (Join-Path $tmp "dawn-$platform.tar.gz") -C $Repo
        Write-Host "Extracted to lib\$platform\:"
        Get-ChildItem (Join-Path $Repo "lib\$platform") | Format-Table Name, Length -AutoSize
    }
} finally {
    Remove-Item -Recurse -Force $tmp
}
