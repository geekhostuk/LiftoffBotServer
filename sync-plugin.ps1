<#
.SYNOPSIS
  Copy the freshly-built LiftoffPhotonEventLogger DLL from the Liftoff repo
  into ./plugin-build/ so `docker compose build` picks it up.

.DESCRIPTION
  Defaults assume the sibling repo layout (C:\Projects\Liftoff). Override
  with -PluginRepo to point elsewhere. Fails fast if the DLL is missing —
  run `dotnet build -c Release` in the plugin repo first.

.EXAMPLE
  .\sync-plugin.ps1
  .\sync-plugin.ps1 -PluginRepo "D:\other\Liftoff"
#>

param(
  [string]$PluginRepo = "C:\Projects\Liftoff",
  [string]$Configuration = "Release",
  [string]$TargetFramework = "net472"
)

$ErrorActionPreference = "Stop"

$sourceDir = Join-Path $PluginRepo "Pluggins\LiftoffPhotonEventLogger\bin\$Configuration\$TargetFramework"
$sourceDll = Join-Path $sourceDir "LiftoffPhotonEventLogger.dll"
$destDir   = Join-Path $PSScriptRoot "plugin-build"
$destDll   = Join-Path $destDir "LiftoffPhotonEventLogger.dll"

if (-not (Test-Path $sourceDll)) {
  Write-Error @"
Plugin DLL not found at:
  ${sourceDll}

Build it first. From ${PluginRepo}:
  dotnet build -c ${Configuration} Pluggins\LiftoffPhotonEventLogger\LiftoffPhotonEventLogger.csproj
"@
  exit 1
}

New-Item -ItemType Directory -Force -Path $destDir | Out-Null

Copy-Item -Path $sourceDll -Destination $destDll -Force
$srcInfo = Get-Item $sourceDll
Write-Host "Copied LiftoffPhotonEventLogger.dll" -ForegroundColor Green
Write-Host "  from: $sourceDll"
Write-Host "  to:   $destDll"
Write-Host "  size: $([math]::Round($srcInfo.Length / 1KB, 1)) KB"
Write-Host "  mtime: $($srcInfo.LastWriteTime)"
Write-Host ""
Write-Host "Next: docker compose build && docker compose up -d" -ForegroundColor Cyan
