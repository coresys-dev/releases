<#
.SYNOPSIS
    Cuts a draft GitHub release for a single app from files staged in ARTIFACTS\<AppId>\,
    including a generated latest.json for the app's auto-updater.

.DESCRIPTION
    - Reads the app's metadata from manifest.json (name, tag prefix).
    - Reads build output from ARTIFACTS\<AppId>\<platform>\<Version>\, where
      <platform> is "win" and/or "mac". Both are optional, but at least one
      must contain files.
    - Uploads every file found as release assets (all platforms in one release).
    - Generates a latest.json asset describing the version, release notes and,
      per platform, the download URL/size of each asset, for the launcher's
      update checker.
    - Tags the release "<AppId>-v<Version>" (e.g. core-v1.4.2) so multiple apps
      can share this one repo without colliding.
    - ALWAYS creates the release as a draft so it can be checked manually
      before being published.

.PARAMETER AppId
    App id as listed in manifest.json (e.g. "core", "sldr"). Omit to list
    available app ids and exit.

.PARAMETER Version
    Semantic version to release, e.g. "1.4.2" or "1.4.2-beta.1" (no leading "v").

.PARAMETER Notes
    Release notes / changelog text. Overrides -NotesFile if both are given.

.PARAMETER NotesFile
    Path to a file containing release notes.

.PARAMETER MinLauncherVersion
    Minimum launcher version (semver) allowed to install this release. Written
    into latest.json as "minLauncherVersion". If omitted, falls back to the
    repo-wide "minLauncherVersion" in manifest.json (if set).

.PARAMETER DryRun
    Show what would be uploaded/created without calling gh or touching GitHub.

.EXAMPLE
    # Reads ARTIFACTS\core\win\1.4.2\... and/or ARTIFACTS\core\mac\1.4.2\...
    .\scripts\release.ps1 -AppId core -Version 1.4.2 -Notes "Fix crash on export"

.EXAMPLE
    .\scripts\release.ps1 -AppId sldr -Version 0.9.0 -NotesFile ARTIFACTS\sldr\CHANGELOG.md -DryRun
#>

[CmdletBinding()]
param(
    [string]$AppId,
    [string]$Version,
    [string]$Notes,
    [string]$NotesFile,
    [string]$MinLauncherVersion,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ManifestPath = Join-Path $RepoRoot "manifest.json"

# Load .env (e.g. GITHUB_TOKEN=...) if present, without overriding real env vars.
# gh picks up GITHUB_TOKEN/GH_TOKEN from the environment automatically.
$EnvFilePath = Join-Path $RepoRoot ".env"
if (Test-Path $EnvFilePath) {
    foreach ($line in Get-Content $EnvFilePath) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $eq = $trimmed.IndexOf("=")
        if ($eq -lt 1) { continue }
        $key = $trimmed.Substring(0, $eq).Trim()
        $value = $trimmed.Substring($eq + 1).Trim().Trim('"').Trim("'")
        if (-not (Test-Path "Env:$key")) {
            Set-Item -Path "Env:$key" -Value $value
        }
    }
}

function Get-Manifest {
    if (-not (Test-Path $ManifestPath)) {
        throw "manifest.json not found at $ManifestPath"
    }
    Get-Content $ManifestPath -Raw | ConvertFrom-Json
}

function Show-AvailableApps {
    param($Manifest)
    Write-Host "Usage: .\scripts\release.ps1 -AppId <id> -Version <x.y.z> [-Notes '...' | -NotesFile <path>] [-DryRun]"
    Write-Host ""
    Write-Host "Available app ids (from manifest.json):"
    foreach ($a in $Manifest.apps) {
        Write-Host ("  - {0,-10} {1}" -f $a.id, $a.name)
    }
    $artifactsRoot = Join-Path $RepoRoot "ARTIFACTS"
    if (Test-Path $artifactsRoot) {
        $staged = Get-ChildItem $artifactsRoot -Directory -ErrorAction SilentlyContinue
        if ($staged) {
            Write-Host ""
            Write-Host "Staged in ARTIFACTS\ (app > platform > versions with files):"
            foreach ($d in $staged) {
                Write-Host ("  - {0}" -f $d.Name)
                foreach ($platformKey in $PlatformFolderMap.Keys) {
                    $platformDir = Join-Path $d.FullName $platformKey
                    if (-not (Test-Path $platformDir)) { continue }
                    $versions = Get-ChildItem $platformDir -Directory -ErrorAction SilentlyContinue | Where-Object {
                        (Get-ChildItem $_.FullName -File -Recurse -ErrorAction SilentlyContinue).Count -gt 0
                    }
                    if ($versions) {
                        $versionList = ($versions | ForEach-Object { $_.Name }) -join ", "
                        Write-Host ("      {0}: {1}" -f $platformKey, $versionList)
                    }
                }
            }
        }
    }
}

# Maps ARTIFACTS platform subfolder names to the platform keys used in latest.json.
$PlatformFolderMap = [ordered]@{
    win = "windows"
    mac = "macos"
}

$manifest = Get-Manifest

if (-not $AppId) {
    Show-AvailableApps -Manifest $manifest
    exit 0
}

$app = $manifest.apps | Where-Object { $_.id -eq $AppId }
if (-not $app) {
    Write-Error "App id '$AppId' not found in manifest.json."
    Show-AvailableApps -Manifest $manifest
    exit 1
}

if (-not $Version) {
    throw "-Version is required, e.g. -Version 1.4.2"
}
if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') {
    throw "Version '$Version' is not a valid semantic version (expected x.y.z or x.y.z-suffix)."
}

$RepoSlug = $manifest.repo
if (-not $RepoSlug) {
    try {
        $RepoSlug = (gh repo view --json nameWithOwner -q ".nameWithOwner" 2>$null)
    } catch {}
}
if (-not $RepoSlug) {
    throw "Could not determine 'owner/repo'. Set 'repo' in manifest.json or run inside a repo with a GitHub remote."
}

$TagPrefix = $app.releaseTagPrefix
if (-not $TagPrefix) { $TagPrefix = "$AppId-v" }
$Tag = "$TagPrefix$Version"
$Title = "$($app.name) $Version"

$ArtifactsDir = Join-Path $RepoRoot "ARTIFACTS\$AppId"
if (-not (Test-Path $ArtifactsDir)) {
    throw "No artifacts folder found at $ArtifactsDir. Drop the build output for '$AppId' there first."
}

# Discover per-platform build output: ARTIFACTS\<AppId>\<win|mac>\<Version>\...
$PlatformFiles = [ordered]@{}
foreach ($platformKey in $PlatformFolderMap.Keys) {
    $versionDir = Join-Path $ArtifactsDir "$platformKey\$Version"
    if (-not (Test-Path $versionDir)) { continue }
    $files = Get-ChildItem $versionDir -File -Recurse | Where-Object { $_.Name -ne "latest.json" }
    if ($files -and $files.Count -gt 0) {
        $PlatformFiles[$platformKey] = $files
    }
}

if ($PlatformFiles.Count -eq 0) {
    throw "No build output found for '$AppId' $Version. Expected files under ARTIFACTS\$AppId\win\$Version\ and/or ARTIFACTS\$AppId\mac\$Version\."
}

$AssetFiles = @()
foreach ($platformKey in $PlatformFiles.Keys) { $AssetFiles += $PlatformFiles[$platformKey] }

$DuplicateNames = $AssetFiles | Group-Object Name | Where-Object { $_.Count -gt 1 }
if ($DuplicateNames) {
    $names = ($DuplicateNames | ForEach-Object { $_.Name }) -join ", "
    throw "Duplicate asset file name(s) across platforms: $names. Release assets must have unique names; rename the platform builds (e.g. include -win/-mac in the filename)."
}

# Resolve release notes: -Notes > -NotesFile > default placeholder.
$NotesText = $Notes
if (-not $NotesText -and $NotesFile) {
    $NotesFilePath = $NotesFile
    if (-not (Test-Path $NotesFilePath)) {
        $NotesFilePath = Join-Path $RepoRoot $NotesFile
    }
    if (-not (Test-Path $NotesFilePath)) {
        throw "Notes file not found: $NotesFile"
    }
    $NotesText = Get-Content $NotesFilePath -Raw
}
if (-not $NotesText) {
    $NotesText = "$($app.name) $Version."
}

# Refuse to clobber an existing release/tag.
if (-not $DryRun) {
    $existing = gh release view $Tag --repo $RepoSlug 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing) {
        throw "A release for tag '$Tag' already exists. Bump -Version or delete the existing draft first."
    }
}

$PubDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$DownloadBase = "https://github.com/$RepoSlug/releases/download/$Tag"

$PlatformEntries = [ordered]@{}
foreach ($platformKey in $PlatformFiles.Keys) {
    $platformName = $PlatformFolderMap[$platformKey]
    $assetEntries = @()
    foreach ($f in $PlatformFiles[$platformKey]) {
        $assetEntries += [ordered]@{
            name = $f.Name
            url  = "$DownloadBase/$($f.Name)"
            size = $f.Length
        }
    }
    $PlatformEntries[$platformName] = [ordered]@{ assets = $assetEntries }
}

# Minimum launcher version for this release: -MinLauncherVersion wins,
# otherwise fall back to the repo-wide floor in manifest.json (if any).
$MinLauncher = $MinLauncherVersion
if (-not $MinLauncher) { $MinLauncher = $manifest.minLauncherVersion }
if ($MinLauncher -and $MinLauncher -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') {
    throw "MinLauncherVersion '$MinLauncher' is not a valid semantic version."
}

$LatestJson = [ordered]@{
    id        = $AppId
    name      = $app.name
    version   = $Version
    notes     = $NotesText
    pub_date  = $PubDate
}
if ($MinLauncher) { $LatestJson.minLauncherVersion = $MinLauncher }
$LatestJson.platforms = $PlatformEntries

$LatestJsonPath = Join-Path ([System.IO.Path]::GetTempPath()) "latest-$AppId-$Version.json"
$LatestJson | ConvertTo-Json -Depth 6 | Set-Content -Path $LatestJsonPath -Encoding utf8

Write-Host ""
Write-Host "=== Release plan ===" -ForegroundColor Cyan
Write-Host "Repo:     $RepoSlug"
Write-Host "App:      $($app.name) ($AppId)"
Write-Host "Tag:      $Tag"
Write-Host "Title:    $Title"
Write-Host "Draft:    yes (manual publish required)"
Write-Host "Assets:"
foreach ($platformKey in $PlatformFiles.Keys) {
    Write-Host ("  [{0}]" -f $PlatformFolderMap[$platformKey])
    foreach ($f in $PlatformFiles[$platformKey]) { Write-Host ("    - {0} ({1:N0} bytes)" -f $f.Name, $f.Length) }
}
Write-Host "  - latest.json (generated)"
Write-Host ""

if ($DryRun) {
    Write-Host "DryRun: no release created. Generated latest.json preview:" -ForegroundColor Yellow
    Get-Content $LatestJsonPath
    exit 0
}

$GhArgs = @(
    "release", "create", $Tag
    "--repo", $RepoSlug
    "--title", $Title
    "--notes", $NotesText
    "--draft"
)
$GhArgs += ($AssetFiles | ForEach-Object { $_.FullName })
$GhArgs += $LatestJsonPath

gh @GhArgs
if ($LASTEXITCODE -ne 0) {
    throw "gh release create failed (exit code $LASTEXITCODE)."
}

Write-Host ""
Write-Host "Draft release '$Tag' created. Review it on GitHub, then publish manually." -ForegroundColor Green
