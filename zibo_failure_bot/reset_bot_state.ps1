#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BotHost = "127.0.0.1",
    [int]$BotPort = 6100,
    [string]$StatePath = (Join-Path $PSScriptRoot "dashboard_state.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$zeroState = [ordered]@{
    severity = 0
    last_event = "idle"
    event_counter = 0
    failures = @{}
    last_failure_ts = 0
    last_raid = @{ user = "None"; viewers = 0; ts = 0 }
    last_follower = @{ user = "None"; ts = 0 }
    last_bits = @{ user = "None"; amount = 0; ts = 0 }
    total_bits = 0
    top_bits_giver = @{ user = "None"; amount = 0; ts = 0 }
    highest_single_bits = @{ user = "None"; amount = 0; ts = 0 }
}

$parent = Split-Path -Parent $StatePath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$zeroState | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $StatePath -NoNewline -Encoding ascii
Write-Host "[reset] Wrote zero state file: $StatePath"

$adminResetUri = "http://$BotHost`:$BotPort/admin/reset"
try {
    $null = Invoke-RestMethod -Uri $adminResetUri -Method Post -ContentType "application/json" -Body "{}" -TimeoutSec 2
    Write-Host "[reset] Sent live admin reset: $adminResetUri"
} catch {
    Write-Host "[reset] Live admin reset unavailable (bot may be offline): $($_.Exception.Message)"
}
