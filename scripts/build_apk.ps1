<#
.SYNOPSIS
    Builds the custom KOReader Android APK with Onyx Boox low-latency stylus support.

.PARAMETER BuildType
    "Debug" (default) or "Release".
#>

param(
    [ValidateSet("Debug", "Release")]
    [string]$BuildType = "Debug"
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LauncherDir = Join-Path $Root "android-launcher"
$OutputDir = Join-Path $Root "output"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "Building KOReader with Onyx Boox Stylus Support" -ForegroundColor Cyan
Write-Host "Build Type: $BuildType (Architecture: ARM64-v8a)" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# Check for Android SDK
if (-not $env:ANDROID_HOME -and -not $env:ANDROID_SDK_ROOT) {
    Write-Warning "Neither ANDROID_HOME nor ANDROID_SDK_ROOT environment variable is set."
    Write-Host "Ensure Android SDK is installed or configure local.properties in android-launcher." -ForegroundColor Yellow
}

# Ensure output directory exists
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Push-Location $LauncherDir
try {
    $GradleCommand = if ($IsWindows -or $env:OS -like "*Windows*") { ".\gradlew.bat" } else { "./gradlew" }
    
    $TaskName = "assembleArm64$BuildType"
    Write-Host "[*] Executing Gradle task: $TaskName..." -ForegroundColor Yellow
    
    & $GradleCommand $TaskName --stacktrace

    # Locate generated APK
    $ApkPath = Get-ChildItem -Path "app\build\outputs\apk" -Filter "*.apk" -Recurse | 
               Where-Object { $_.FullName -like "*arm64*$BuildType*" } | 
               Select-Object -First 1

    if ($ApkPath) {
        $DestName = "KOReader-Boox-Stylus-$BuildType.apk"
        $FinalPath = Join-Path $OutputDir $DestName
        Copy-Item -Force $ApkPath.FullName $FinalPath
        
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host "BUILD SUCCESSFUL!" -ForegroundColor Green
        Write-Host "Output APK: $FinalPath" -ForegroundColor Cyan
        Write-Host "Install to device via ADB:" -ForegroundColor Yellow
        Write-Host "    adb install -r `"$FinalPath`"" -ForegroundColor White
        Write-Host "====================================================" -ForegroundColor Green
    } else {
        Write-Warning "Build finished, but could not locate generated APK in outputs folder."
    }
} finally {
    Pop-Location
}
