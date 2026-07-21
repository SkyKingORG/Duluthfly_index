#Requires -Version 5.1
<#
.SYNOPSIS
  Automatically sends randomized StreamElements events and Twitch chat commands
  to the running zibo_failure_bot on a continuous timer.

.PARAMETER BotPort
  HTTP port the bot listens on (default: 6100).

.PARAMETER MinDelaySec
  Minimum seconds between events (default: 20).

.PARAMETER MaxDelaySec
  Maximum seconds between events (default: 90).

.PARAMETER TwitchOAuth
  Reads TWITCH_OAUTH env var if not supplied.

.PARAMETER TwitchNick
  Reads TWITCH_BOT_NICK env var, defaults to OnlyPilots.

.PARAMETER TwitchChannel
  Reads TWITCH_CHANNEL env var, defaults to #desktoppilotsociety.
#>

param(
    [int]   $BotPort      = 6100,
    [int]   $MinDelaySec  = 20,
    [int]   $MaxDelaySec  = 90,
    [string]$TwitchOAuth   = $env:TWITCH_OAUTH,
    [string]$TwitchNick    = $(if ($env:TWITCH_BOT_NICK) { $env:TWITCH_BOT_NICK } else { "OnlyPilots" }),
    [string]$TwitchChannel = $(if ($env:TWITCH_CHANNEL)  { $env:TWITCH_CHANNEL  } else { "#desktoppilotsociety" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$rng = [System.Random]::new()

# ── StreamElements event pool ─────────────────────────────────────────────────

$se_events = @(
    @{ type = "tip";        amount   = 5;  username = "StreamFan1" }
    @{ type = "tip";        amount   = 10; username = "StreamFan2" }
    @{ type = "subscriber"; months   = 1;  username = "NewSub1"    }
    @{ type = "subscriber"; months   = 6;  username = "ResubUser"  }
    @{ type = "raid";       viewers  = 25; username = "RaidLeader" }
    @{ type = "gifted";     amount   = 1;  username = "GiftGiver"  }
    @{ type = "gifted";     amount   = 5;  username = "MegaGifter" }
    @{ type = "bits";       bits     = 100; username = "BitsCheerer" }
    @{ type = "bits";       bits     = 500; username = "BigBitsDonor" }
    @{ type = "follow";     username = "NewFollower1" }
)

# ── Twitch commands pool ───────────────────────────────────────────────────────

$twitch_commands = @("!fail", "!zibo")

# ── helpers ───────────────────────────────────────────────────────────────────

function Send-SEEvent {
    param([hashtable]$Body)
    $url  = "http://127.0.0.1:$BotPort/streamelements"
    $json = $Body | ConvertTo-Json -Compress
    try {
        $resp = Invoke-RestMethod -Uri $url -Method POST `
            -ContentType "application/json" -Body $json -TimeoutSec 5
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [SE ] Sent $($Body.type) from $($Body.username) -> $($resp | ConvertTo-Json -Compress)"
    } catch {
        Write-Warning "[SE ] POST failed: $_"
    }
}

function Send-TwitchCommand {
    param([string]$Command)
    if (-not $TwitchOAuth -or $TwitchOAuth -eq "oauth:replace_with_token") {
        Write-Warning "[IRC] TWITCH_OAUTH not set — skipping Twitch command."
        return
    }
    $channel = $TwitchChannel.TrimStart("#")
    try {
        $tcp    = [System.Net.Sockets.TcpClient]::new("irc.chat.twitch.tv", 6667)
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.AutoFlush = $true

        $writer.WriteLine("PASS $TwitchOAuth")
        $writer.WriteLine("NICK $TwitchNick")
        $writer.WriteLine("JOIN #$channel")

        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        while ([DateTime]::UtcNow -lt $deadline -and $tcp.Connected) {
            if ($stream.DataAvailable) {
                $line = $reader.ReadLine()
                if ($line -match "366") { break }
            } else {
                [System.Threading.Thread]::Sleep(100)
            }
        }

        $writer.WriteLine("PRIVMSG #$channel :$Command")
        [System.Threading.Thread]::Sleep(300)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [IRC] Sent to #$channel`: $Command"

        $writer.Close(); $reader.Close(); $tcp.Close()
    } catch {
        Write-Warning "[IRC] Error: $_"
    }
}

# ── main loop ─────────────────────────────────────────────────────────────────

Write-Host "=== auto_events started. Bot port: $BotPort | Delay: ${MinDelaySec}-${MaxDelaySec}s ==="
Write-Host "Press Ctrl+C to stop."
Write-Host ""

while ($true) {
    # Pick SE event or Twitch command (70% SE, 30% Twitch)
    $roll = $rng.NextDouble()

    if ($roll -lt 0.70) {
        $event = $se_events[$rng.Next(0, $se_events.Count)]
        Send-SEEvent -Body $event
    } else {
        $cmd = $twitch_commands[$rng.Next(0, $twitch_commands.Count)]
        Send-TwitchCommand -Command $cmd
    }

    $delay = $rng.Next($MinDelaySec, $MaxDelaySec + 1)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Next event in $delay s..."
    Start-Sleep -Seconds $delay
}
