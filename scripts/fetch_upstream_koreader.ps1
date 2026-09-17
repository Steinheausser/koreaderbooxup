<#
.SYNOPSIS
    Fetches the latest official KOReader Android ARM64 APK (or accepts a local APK)
    and extracts its assets and native libraries into the android-launcher workspace.

.PARAMETER ApkPath
    Optional path to a local KOReader APK file. If omitted, downloads the latest release from GitHub.

.EXAMPLE
    .\scripts\fetch_upstream_koreader.ps1
    .\scripts\fetch_upstream_koreader.ps1 -ApkPath "C:\Downloads\koreader-android-arm64-v2026.08.apk"
#>

param(
    [string]$ApkPath = ""
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LauncherDir = Join-Path $Root "android-launcher"
$AssetsDir = Join-Path $LauncherDir "assets"
$LibsDir = Join-Path $LauncherDir "app\libs"
$TempDir = Join-Path $Root "temp_apk_extract"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "KOReader Upstream Asset & Library Ingestion" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($ApkPath) -or -not (Test-Path $ApkPath)) {
    # Check if a previously downloaded APK exists in Root
    $ExistingApk = Get-ChildItem -Path $Root -Filter "koreader-android-arm64-*.apk" | Select-Object -First 1
    if ($ExistingApk) {
        $ApkPath = $ExistingApk.FullName
        Write-Host "[*] Found existing local APK: $($ExistingApk.Name)" -ForegroundColor Green
    } else {
        Write-Host "[*] Querying GitHub for latest official KOReader Android ARM64 release..." -ForegroundColor Yellow
        $ApiUrl = "https://api.github.com/repos/koreader/koreader/releases/latest"
        $Headers = @{ "User-Agent" = "KOReader-Boox-Ingestor" }
        
        try {
            $Release = Invoke-RestMethod -Uri $ApiUrl -Headers $Headers
            $Asset = $Release.assets | Where-Object { $_.name -like "koreader-android-arm64-*.apk" } | Select-Object -First 1
            
            if (-not $Asset) {
                throw "Could not find koreader-android-arm64-*.apk in latest release assets."
            }

            $ApkPath = Join-Path $Root $Asset.name
            Write-Host "[*] Downloading $($Asset.name) ($([math]::Round($Asset.size / 1MB, 2)) MB)..." -ForegroundColor Green
            Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ApkPath
        } catch {
            Write-Error "Failed to fetch release from GitHub: $_"
            exit 1
        }
    }
} else {
    Write-Host "[*] Using provided APK: $ApkPath" -ForegroundColor Green
}

# Cleanup previous temp extraction
if (Test-Path $TempDir) {
    Remove-Item -Recurse -Force $TempDir
}
New-Item -ItemType Directory -Path $TempDir | Out-Null

Write-Host "[*] Extracting APK archive..." -ForegroundColor Yellow
$TempZip = Join-Path $Root "temp_extract.zip"
Copy-Item -Path $ApkPath -Destination $TempZip -Force
Expand-Archive -Path $TempZip -DestinationPath $TempDir -Force
Remove-Item -Force $TempZip

# 1. Populate Assets
Write-Host "[*] Updating launcher assets..." -ForegroundColor Yellow
if (-not (Test-Path $AssetsDir)) {
    New-Item -ItemType Directory -Path $AssetsDir | Out-Null
}

if (Test-Path "$TempDir\assets") {
    Copy-Item -Recurse -Force "$TempDir\assets\*" $AssetsDir
}

# 2. Bundle the Boox Pen Plugin into assets/plugins
$PluginSrc = Join-Path $Root "plugins\boox_pen.koplugin"
$PluginDst = Join-Path $AssetsDir "plugins\boox_pen.koplugin"
Write-Host "[*] Bundling boox_pen.koplugin into APK assets..." -ForegroundColor Green
if (-not (Test-Path (Split-Path $PluginDst))) {
    New-Item -ItemType Directory -Path (Split-Path $PluginDst) | Out-Null
}
Copy-Item -Recurse -Force $PluginSrc $PluginDst

# 3. Populate Native .so Libraries
Write-Host "[*] Updating native libraries (lib/arm64-v8a)..." -ForegroundColor Yellow
$Arm64Libs = Join-Path $TempDir "lib\arm64-v8a"
$TargetLibs = Join-Path $LibsDir "arm64-v8a"

if (Test-Path $Arm64Libs) {
    if (-not (Test-Path $TargetLibs)) {
        New-Item -ItemType Directory -Path $TargetLibs -Force | Out-Null
    }
    Copy-Item -Recurse -Force "$Arm64Libs\*" $TargetLibs
}

# Cleanup temp files
Remove-Item -Recurse -Force $TempDir

Write-Host "====================================================" -ForegroundColor Green
Write-Host "Ingestion complete! KOReader assets & libs ready." -ForegroundColor Green
Write-Host "You can now run: .\scripts\build_apk.ps1" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Green
