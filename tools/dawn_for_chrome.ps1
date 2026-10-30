<#
Finds the Dawn commit built into a Chrome release, and optionally checks it out. The PowerShell version of
dawn_for_chrome.sh, for Windows: needs only git, and Python with -Deps. Files are read through Gitiles,
nothing is cloned but the Dawn commit itself (-Fetch).

Usage: tools\dawn_for_chrome.ps1 [options] <chrome>
  <chrome>        A full version (156.0.8078.48), a milestone (156: its latest stable release), or a
                  channel (stable, beta, dev, canary: its latest release). Or a Dawn commit (40 hex
                  digits), to -Fetch it without looking anything up
  -Platform P     Platform for milestones and channels: Mac, Windows, Linux (default: this OS)
  -Fetch DIR      Check out the Dawn commit in DIR: a shallow clone if DIR is new or empty, else a fetch
                  into the existing Dawn repo there
  -Deps           With -Fetch, also fetch Dawn's third-party dependencies (tools\fetch_dawn_dependencies.py),
                  so that CMake can build with DAWN_FETCH_DEPENDENCIES=OFF
  -Env            Print KEY=VALUE lines only, e.g. to append to $env:GITHUB_OUTPUT or $env:GITHUB_ENV

The commit comes from chromiumdash, else from `dawn_revision` in Chromium's DEPS at the version's tag.
Chromium's release branch BBBB (the version's third number) has a Dawn branch chromium/BBBB, where later
fixes for the milestone are cherry-picked, so the script also reports how far the commit is from that
branch's tip.

-Env keys: CHROME_VERSION, DAWN_COMMIT, DAWN_COMMIT_DATE, DAWN_COMMIT_TITLE, DAWN_BRANCH, DAWN_BRANCH_TIP,
DAWN_BRANCH_AHEAD (commits on the branch after DAWN_COMMIT). The DAWN_BRANCH* values are empty when the
branch does not exist (canary and dev builds from main). The commit details and the branch are looked up
on a best-effort basis: they are empty, with a warning, when Gitiles cannot be reached.
#>
param(
    [Parameter(Position = 0)] [string] $Chrome,
    [ValidateSet('Mac', 'Windows', 'Linux')] [string] $Platform,
    [string] $Fetch,
    [switch] $Deps,
    [switch] $Env
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$ChromiumGitiles = 'https://chromium.googlesource.com/chromium/src'
$DawnGitiles = 'https://dawn.googlesource.com/dawn'
$Chromiumdash = 'https://chromiumdash.appspot.com'

if (-not $Chrome) {
    Get-Help $PSCommandPath -Detailed
    exit 2
}
if ($Deps -and -not $Fetch) {
    throw '-Deps needs -Fetch'
}
if ($Fetch) {
    $Fetch = [IO.Path]::GetFullPath($Fetch, (Get-Location).Path)
}

# Gitiles answers 429 or 503 under load: retried, with a backoff of up to a minute in all.
function Get-Text([string] $Url) {
    (Invoke-WebRequest $Url -MaximumRetryCount 6 -RetryIntervalSec 10).Content
}

# Gitiles JSON starts with a `)]}'` line, against XSSI.
function Get-GitilesJson([string] $Url) {
    ((Get-Text $Url) -replace '^\)\]\}''\r?\n', '') | ConvertFrom-Json -AsHashtable
}

# Progress goes to the host (stderr in CI logs), so that -Env output stays clean.
function Write-Status([string] $Message) {
    [Console]::Error.WriteLine($Message)
}

# Runs a script block up to 3 times, for network operations.
function Invoke-Retry([scriptblock] $Action) {
    foreach ($attempt in 1..3) {
        try {
            & $Action
            return
        } catch {
            if ($attempt -eq 3) {
                throw
            }
            Write-Status "Failed ($_), retrying in $($attempt * 20) s"
            Start-Sleep -Seconds ($attempt * 20)
        }
    }
}

# Python 3, avoiding the Microsoft Store's python3 alias of Windows, which only opens the Store.
function Get-Python {
    $python = Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1
    if (-not $python) {
        throw 'Python 3 is needed for -Deps (python3 or python on the PATH)'
    }
    $python.Source
}

# Checks out $Commit in $Fetch, with Dawn's dependencies if -Deps.
function Invoke-Checkout([string] $Commit) {
    if (-not (Test-Path $Fetch) -or -not (Get-ChildItem -Force $Fetch | Select-Object -First 1)) {
        Write-Status "Fetching Dawn $Commit into $Fetch (shallow)"
        New-Item -ItemType Directory -Force $Fetch | Out-Null
        git -C $Fetch init -q
        git -C $Fetch remote add origin $DawnGitiles
        Invoke-Retry { git -C $Fetch fetch -q --depth 1 origin $Commit }
    } else {
        $top = git -C $Fetch rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($top) -ne [IO.Path]::GetFullPath($Fetch).TrimEnd('\', '/')) {
            # In a directory inside another repository (this one, say), git would work on that repository.
            throw "$Fetch is not empty and not the root of a git repository"
        }
        git -C $Fetch cat-file -e "$Commit^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Status "Dawn $Commit is already in $Fetch"
        } else {
            Write-Status "Fetching Dawn $Commit into $Fetch"
            # Keep a full clone full: --depth would make it shallow.
            $depth = (git -C $Fetch rev-parse --is-shallow-repository) -eq 'true' ? @('--depth', '1') : @()
            Invoke-Retry { git -C $Fetch fetch -q @depth $DawnGitiles $Commit }
        }
    }
    git -C $Fetch -c advice.detachedHead=false checkout -q --detach $Commit
    Write-Status "Checked out $Commit in $Fetch"

    if ($Deps) {
        Invoke-DependencyFetch
    }
}

# The git repositories under $Dir, without looking inside them.
function Find-GitRepository([string] $Dir) {
    foreach ($sub in Get-ChildItem -Directory -Force $Dir) {
        if (Test-Path (Join-Path $sub.FullName '.git')) {
            $sub.FullName
        } elseif ($sub.Name -ne '.git') {
            Find-GitRepository $sub.FullName
        }
    }
}

# Runs Dawn's tools/fetch_dawn_dependencies.py. It ignores git's errors: a dependency whose fetch failed is
# left as a repository without a checkout, which a second run does not repair. Such repositories are
# emptied and fetched again, up to 3 times. (The script clones into the empty directory that Dawn's
# checkout has for each dependency, so the directory must stay.)
function Invoke-DependencyFetch {
    $python = Get-Python
    foreach ($attempt in 1..3) {
        Write-Status "Fetching Dawn's dependencies"
        & $python (Join-Path $Fetch 'tools\fetch_dawn_dependencies.py') --directory $Fetch | ForEach-Object { Write-Status $_ }
        $broken = @(Find-GitRepository (Join-Path $Fetch 'third_party') | Where-Object {
                git -C $_ rev-parse -q --verify HEAD *> $null
                $LASTEXITCODE -ne 0
            })
        $global:LASTEXITCODE = 0
        if (-not $broken) {
            return
        }
        Write-Status "Not checked out: $($broken -join ' ')"
        foreach ($repo in $broken) {
            Remove-Item -Recurse -Force $repo
            New-Item -ItemType Directory $repo | Out-Null
        }
        if ($attempt -lt 3) {
            Write-Status "Retrying in $($attempt * 20) s"
            Start-Sleep -Seconds ($attempt * 20)
        }
    }
    throw "cannot fetch Dawn's dependencies"
}

# A Dawn commit: nothing to look up.
if ($Chrome -match '^[0-9a-f]{40}$') {
    if ($Env) { "DAWN_COMMIT=$Chrome" } else { "Dawn commit: $Chrome" }
    if ($Fetch) { Invoke-Checkout $Chrome }
    exit 0
}

if (-not $Platform) {
    $Platform = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'Mac' } else { 'Linux' }
}

# Resolves a milestone or channel to its latest release, through chromiumdash.
function Get-LatestVersion([string] $Channel, [string] $Milestone) {
    $url = "$Chromiumdash/fetch_releases?channel=$Channel&platform=$Platform&num=1"
    if ($Milestone) {
        $url += "&milestone=$Milestone"
    }
    @(Invoke-RestMethod $url -MaximumRetryCount 6 -RetryIntervalSec 10)[0].version
}

$Version = switch -Regex ($Chrome) {
    '^\d+\.\d+\.\d+\.\d+$' { $Chrome; break }
    '^\d{1,3}$' { Get-LatestVersion Stable $Chrome; break }
    '^(stable|beta|dev|canary)$' { Get-LatestVersion ((Get-Culture).TextInfo.ToTitleCase($Chrome)); break }
    default { throw "expected a version (156.0.8078.48), a milestone (156), a channel (stable, beta, dev, canary) or a full Dawn commit, got '$Chrome'" }
}
if (-not $Version) {
    throw "no $Platform release found for '$Chrome'"
}

# The Dawn commit, from chromiumdash: {"hashes": {"dawn": "<sha>", ...}, ...}, or a 404.
$Commit = try { (Invoke-RestMethod "$Chromiumdash/fetch_version?version=$Version" -MaximumRetryCount 6 -RetryIntervalSec 10).hashes.dawn } catch { $null }
if ($Commit -notmatch '^[0-9a-f]{40}$') {
    # Else from DEPS at the version's tag, base64-encoded by ?format=TEXT.
    try {
        $depsFile = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Get-Text "$ChromiumGitiles/+/refs/tags/$Version/DEPS?format=TEXT")))
    } catch {
        throw "no Dawn commit for Chrome $Version`: chromiumdash does not list it, and Chromium's DEPS at tag $Version cannot be read ($_)"
    }
    if ($depsFile -notmatch "(?m)^\s*'dawn_revision':\s*'([0-9a-f]{40})'") {
        throw "no dawn_revision in DEPS at $Version"
    }
    $Commit = $Matches[1]
}

$CommitDate = ''
$CommitTitle = ''
try {
    $json = Get-GitilesJson "$DawnGitiles/+/$Commit`?format=JSON"
    $CommitDate = $json.committer.time
    $CommitTitle = ($json.message -split "`n")[0]
} catch {
    Write-Warning "cannot read the details of Dawn commit $Commit"
}

# The milestone's Dawn branch, missing for builds from main: Gitiles then answers {}.
$ChromeBranch = $Version.Split('.')[2]
$Branch = "chromium/$ChromeBranch"
$BranchKnown = $true
$BranchTip = ''
$Ahead = ''
try {
    $refs = Get-GitilesJson "$DawnGitiles/+refs/heads/$Branch`?format=JSON"
    $BranchTip = @($refs.Values)[0].value
} catch {
    Write-Warning "cannot look up the Dawn branch $Branch"
    $BranchKnown = $false
}
if (-not $BranchTip) {
    $Branch = ''
} elseif ($BranchTip -eq $Commit) {
    $Ahead = '0'
} else {
    try {
        $log = Get-GitilesJson "$DawnGitiles/+log/$Commit..$BranchTip`?format=JSON"
        # Gitiles pages logs; a "next" key means there are more.
        $Ahead = "$(@($log.log).Count)$($log.ContainsKey('next') ? '+' : '')"
    } catch {
        Write-Warning "cannot count the commits of $Branch after $Commit"
        $Ahead = '?'
    }
}

if ($Env) {
    "CHROME_VERSION=$Version"
    "DAWN_COMMIT=$Commit"
    "DAWN_COMMIT_DATE=$CommitDate"
    "DAWN_COMMIT_TITLE=$CommitTitle"
    "DAWN_BRANCH=$Branch"
    "DAWN_BRANCH_TIP=$BranchTip"
    "DAWN_BRANCH_AHEAD=$Ahead"
} else {
    "Chrome:      $Version"
    "Dawn commit: $Commit"
    if ("$CommitDate$CommitTitle") { "             $CommitDate  $CommitTitle" }
    "             $DawnGitiles/+/$Commit"
    if (-not $BranchKnown) {
        'Dawn branch: unknown (Gitiles cannot be reached)'
    } elseif (-not $Branch) {
        "Dawn branch: none (chromium/$ChromeBranch does not exist: a build from main)"
    } elseif ($Ahead -eq '0') {
        "Dawn branch: $Branch, at its tip"
    } else {
        "Dawn branch: $Branch, whose tip $BranchTip has $Ahead more commit(s)"
    }
}

if ($Fetch) { Invoke-Checkout $Commit }
