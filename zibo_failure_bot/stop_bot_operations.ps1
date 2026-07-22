#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$regex = 'zibo_failure_bot\.lua|twitch_event_bridge\.lua|auto_events\.ps1|event_relay\.ps1|start_auto_events\.bat|start_twitch_bridge\.bat'

$targets = Get-CimInstance Win32_Process |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match $regex
    }

if (-not $targets) {
    if (-not $Quiet) {
        Write-Host "[stop] No bot-related processes found."
    }
    return
}

if (-not $Quiet) {
    Write-Host "[stop] Stopping bot-related processes:"
    $targets | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize | Out-String | Write-Host
}

foreach ($proc in $targets) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}

if (-not $Quiet) {
    Write-Host "[stop] Stop command completed."
}
