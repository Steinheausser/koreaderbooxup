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

# Auto-detect Android SDK
$SdkCandidates = @(
    "$env:LOCALAPPDATA\Android\Sdk",
    $env:ANDROID_HOME,
    $env:ANDROID_SDK_ROOT,
    "C:\Program Files (x86)\Android\android-sdk",
    "C:\Program Files\Android\android-sdk"
)

$FoundSdk = $SdkCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($FoundSdk) {
    $env:ANDROID_HOME = $FoundSdk
    $env:ANDROID_SDK_ROOT = $FoundSdk
    Write-Host "[*] Using Android SDK at: $FoundSdk" -ForegroundColor Green
    
    $LocalProps = Join-Path $LauncherDir "local.properties"
    $EscapedSdk = $FoundSdk -replace '\\', '\\'
    Set-Content -Path $LocalProps -Value "sdk.dir=$EscapedSdk" -Force
} else {
    Write-Warning "Android SDK could not be located automatically."
    Write-Host "Please set ANDROID_HOME or configure android-launcher\local.properties." -ForegroundColor Yellow
}

# Ensure output directory exists
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Push-Location $LauncherDir
try {
    $TaskName = "assembleArm64Rocks$BuildType"
    Write-Host "[*] Executing Gradle task: $TaskName..." -ForegroundColor Yellow
    
    $DestName = "KOReader-Boox-Stylus-$BuildType.apk"
    $FinalPath = Join-Path $OutputDir $DestName
    if (Test-Path $FinalPath) {
        Remove-Item -Force $FinalPath
    }

    if (Test-Path ".\gradlew.bat") {
        .\gradlew.bat $TaskName --stacktrace
    } else {
        java -cp "gradle\wrapper\gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain $TaskName --stacktrace
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Gradle build failed with exit code $LASTEXITCODE"
    }

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
