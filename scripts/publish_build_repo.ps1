# Push the app sources into the public build repository.
#
# GitHub Actions bills macOS runners at ten times the normal rate, and a
# private repository whose included-minutes allowance is spent refuses to start
# any job at all. A public repository is not billed that way, so the build runs
# from a mirror that contains only what the build needs.
#
# The mirror is deliberately not a fork and keeps no history: the reference
# material under reference/ is somebody else's application bundle and does not
# belong in a public repository, and a single snapshot commit means nothing
# stale survives in it.
#
# Usage: powershell -File scripts/publish_build_repo.ps1
[CmdletBinding()]
param(
    [string]$Remote = "https://github.com/Yukiruoqwq/pocketvm-build.git",
    [string]$Worktree = "",
    [string]$Branch = "main"
)

# Native commands report through their exit code. Letting PowerShell turn their
# stderr into a terminating error makes an empty mirror look like a hard
# failure, and an empty mirror is exactly how this repository starts.
$ErrorActionPreference = "Continue"

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Worktree) { $Worktree = Join-Path (Split-Path -Parent $RepoRoot) "pocketvm-build" }

# Everything the build reads, and nothing else.
$Include = @("Sources", "web", "scripts", "project.yml", ".github", "LICENSE", "NOTICE.md", "README.md")

if (-not (Test-Path (Join-Path $Worktree ".git"))) {
    Write-Host "Cloning $Remote into $Worktree"
    git clone --quiet $Remote $Worktree
}

Push-Location $Worktree
try {
    # The snapshot is not authored by whoever happens to run this, and the
    # mirror is force-pushed anyway, so the identity only has to exist.
    git config user.name "PocketVM build mirror"
    git config user.email "pocketvm@localhost"

    $remote = (git ls-remote --heads origin $Branch) 2>$null
    if ($remote) {
        git fetch --quiet origin $Branch
        git checkout --quiet -B $Branch "origin/$Branch"
        if ($LASTEXITCODE -ne 0) { throw "Could not check out $Branch from $Remote" }
    } else {
        git checkout --quiet -B $Branch
    }

    Get-ChildItem -Force | Where-Object { $_.Name -ne ".git" } | Remove-Item -Recurse -Force

    foreach ($item in $Include) {
        $source = Join-Path $RepoRoot $item
        if (-not (Test-Path $source)) { continue }
        $destination = Join-Path $Worktree $item
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -Recurse -Force $source $destination
    }

    git add -A
    $summary = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    git commit --quiet -m "Snapshot of the PocketVM app sources ($summary)"
    if ($LASTEXITCODE -ne 0) { throw "Nothing to publish, or the snapshot could not be committed" }
    git push --quiet --force origin $Branch
    if ($LASTEXITCODE -ne 0) { throw "Push to $Remote failed" }
    Write-Host "Published snapshot to $Remote ($Branch)"
} finally {
    Pop-Location
}
