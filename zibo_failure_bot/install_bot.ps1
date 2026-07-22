[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$SimulatorRoot,

  [Parameter(Mandatory = $false)]
  [string]$SourceRoot = $PSScriptRoot,

  [Parameter(Mandatory = $false)]
  [string]$BotFolderName = "ZiboFailureBot",

  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
  $SourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Write-Step {
  param([string]$Message)
  Write-Host "[install] $Message"
}

function Resolve-ExistingPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Label
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Label was not provided."
  }

  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
  return $resolved.ProviderPath
}

function New-Directory {
  param([string]$Path)

  if ($DryRun) {
    Write-Step "[dry-run] ensure directory: $Path"
    return
  }

  New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Copy-FileTo {
  param(
    [string]$Source,
    [string]$Destination
  )

  $destDir = Split-Path -Parent $Destination
  New-Directory -Path $destDir

  if ($DryRun) {
    Write-Step "[dry-run] copy file: $Source -> $Destination"
    return
  }

  Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Copy-DirectoryTo {
  param(
    [string]$Source,
    [string]$Destination
  )

  New-Directory -Path $Destination

  if ($DryRun) {
    Write-Step "[dry-run] copy directory: $Source -> $Destination"
    return
  }

  Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function Get-DefaultSimulatorRoot {
  $candidates = @(
    "C:\\X-Plane 12",
    "D:\\X-Plane 12",
    "C:\\Program Files\\X-Plane 12",
    "C:\\Program Files (x86)\\X-Plane 12"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return (Resolve-Path -LiteralPath $candidate).ProviderPath
    }
  }

  return $null
}

$resolvedSourceRoot = Resolve-ExistingPath -Path $SourceRoot -Label "SourceRoot"

if ([string]::IsNullOrWhiteSpace($SimulatorRoot)) {
  $detectedRoot = Get-DefaultSimulatorRoot
  if ($detectedRoot) {
    $SimulatorRoot = $detectedRoot
    Write-Step "SimulatorRoot not provided. Using detected path: $SimulatorRoot"
  } else {
    throw 'Could not auto-detect the simulator root. Re-run with -SimulatorRoot "<X-Plane root path>".'
  }
}

if (-not (Test-Path -LiteralPath $SimulatorRoot)) {
  throw "SimulatorRoot does not exist: $SimulatorRoot"
}

$resolvedSimulatorRoot = (Resolve-Path -LiteralPath $SimulatorRoot).ProviderPath

$simResources = Join-Path $resolvedSimulatorRoot "Resources"
if (-not (Test-Path -LiteralPath $simResources)) {
  Write-Step "Warning: Resources folder not found under simulator root. Verify the path points to X-Plane 12 root."
}

$hostInstallRoot = Join-Path $resolvedSimulatorRoot (Join-Path "Tools" $BotFolderName)
$flyWithLuaScriptsRoot = Join-Path $resolvedSimulatorRoot "Resources\plugins\FlyWithLua\Scripts"
$bridgeTargetFile = Join-Path $flyWithLuaScriptsRoot "zibo_failure_xplane_bridge.lua"

$hostFiles = @(
  "README.md",
  "dashboard.html",
  "auto_events.ps1",
  "event_relay.ps1",
  "send_events.ps1",
  "start_all_bats.bat",
  "start_auto_events.bat",
  "start_bot.bat",
  "start_live_mode.bat",
  "start_twitch_bridge.bat",
  "start_twitch_then_bot.lua",
  "twitch_event_bridge.lua",
  "xplane_bridge_xpilot_safe.lua",
  "zibo_failure_bot.lua",
  "install_bot.ps1",
  "install_bot.bat"
)

$optionalDirectories = @(
  "luarocks-tree"
)

Write-Step "Installing bot host files into: $hostInstallRoot"
New-Directory -Path $hostInstallRoot

foreach ($fileName in $hostFiles) {
  $sourcePath = Join-Path $resolvedSourceRoot $fileName
  if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Required source file missing: $sourcePath"
  }

  $destinationPath = Join-Path $hostInstallRoot $fileName
  Copy-FileTo -Source $sourcePath -Destination $destinationPath
}

foreach ($dirName in $optionalDirectories) {
  $sourceDir = Join-Path $resolvedSourceRoot $dirName
  if (Test-Path -LiteralPath $sourceDir) {
    $destinationDir = Join-Path $hostInstallRoot $dirName
    Copy-DirectoryTo -Source $sourceDir -Destination $destinationDir
  } else {
    Write-Step "Optional directory not found, skipping: $sourceDir"
  }
}

Write-Step "Installing X-Plane bridge into: $bridgeTargetFile"
$bridgeSourcePath = Join-Path $resolvedSourceRoot "xplane_bridge_xpilot_safe.lua"
if (-not (Test-Path -LiteralPath $bridgeSourcePath)) {
  throw "Required bridge script missing: $bridgeSourcePath"
}

Copy-FileTo -Source $bridgeSourcePath -Destination $bridgeTargetFile

Write-Step "Install complete."
Write-Step "Host bot folder: $hostInstallRoot"
Write-Step "FlyWithLua bridge: $bridgeTargetFile"
Write-Step "Recommended launcher: start_live_mode.bat from the host bot folder. Keep X-Plane running with FlyWithLua enabled."
