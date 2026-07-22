#Requires -Version 5.1
<#
.SYNOPSIS
  Generates recurring StreamElements events and optional Twitch chat commands
  for the running Zibo failure bot.

.DESCRIPTION
  This script waits for the local bot health endpoint to respond, then loops
  forever sending randomized events to the bot's StreamElements webhook. If a
  valid Twitch OAuth token is available, it also sends Twitch chat commands that
  the Twitch bridge can recognize in real time.

.PARAMETER BotHost
  Host where the bot is listening (default: 127.0.0.1).

.PARAMETER BotPort
  HTTP port the bot listens on (default: 6100).

.PARAMETER HealthTimeoutSec
  Seconds to wait for the bot health endpoint before starting the loop.

.PARAMETER MinDelaySec
  Minimum seconds between generated events.

.PARAMETER MaxDelaySec
  Maximum seconds between generated events.

.PARAMETER TwitchChance
  Chance of sending a Twitch chat command instead of a StreamElements event
  when Twitch OAuth is available.
#>

[CmdletBinding()]
param(
    [string]$BotHost = "127.0.0.1",
    [int]$BotPort = 6100,
    [int]$HealthTimeoutSec = 30,
    [int]$MinDelaySec = 20,
    [int]$MaxDelaySec = 90,
    [double]$TwitchChance = 0.30,
    [string]$TwitchOAuth = $env:TWITCH_OAUTH,
    [string]$TwitchNick = $(if ($env:TWITCH_BOT_NICK) { $env:TWITCH_BOT_NICK } else { "OnlyPilots" }),
    [string]$TwitchChannel = $(if ($env:TWITCH_CHANNEL) { $env:TWITCH_CHANNEL } else { "#desktoppilotsociety" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rng = [System.Random]::new()
$botHealthUri = "http://$BotHost`:$BotPort/health"
$seEndpoint = "http://$BotHost`:$BotPort/streamelements"

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [auto-events] $Message"
}

function Normalize-TwitchOAuth {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    if ($Token.StartsWith("oauth:", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Token
    }

    return "oauth:$Token"
}

function Test-BotReady {
    param(
        [string]$Uri,
        [int]$TimeoutSec
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $null = Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 3
            return $true
        } catch {
            Start-Sleep -Seconds 2
        }
    }

    return $false
}

function Send-SEEvent {
    param([hashtable]$Body)

    $json = $Body | ConvertTo-Json -Compress -Depth 6
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $seEndpoint -Method Post -ContentType "application/json" -Body $json -TimeoutSec 5
            Write-Log "SE sent: $($Body.type) from $($Body.username)"
            return $response
        } catch {
            if ($attempt -eq 3) {
                Write-Warning "[auto-events] SE POST failed after 3 attempts: $_"
            } else {
                Start-Sleep -Milliseconds 500
            }
        }
    }
}

function Send-TwitchCommand {
    param([string]$Command)

    $token = Normalize-TwitchOAuth -Token $TwitchOAuth
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Log "No TWITCH_OAUTH provided; skipping Twitch command."
        return
    }

    $channel = $TwitchChannel.TrimStart("#")

    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("irc.chat.twitch.tv", 6667)
        $tcp.ReceiveTimeout = 3000
        $tcp.SendTimeout = 3000

        $stream = $tcp.GetStream()
        $reader = [System.IO.StreamReader]::new($stream)
        $writer = [System.IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true

        $writer.WriteLine("CAP REQ :twitch.tv/tags twitch.tv/commands")
        $writer.WriteLine("PASS $token")
        $writer.WriteLine("NICK $TwitchNick")
        $writer.WriteLine("JOIN #$channel")

        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ([DateTime]::UtcNow -lt $deadline -and $tcp.Connected) {
            if ($stream.DataAvailable) {
                $line = $reader.ReadLine()
                if (-not $line) {
                    continue
                }

                if ($line.StartsWith("PING")) {
                    $writer.WriteLine($line.Replace("PING", "PONG"))
                    continue
                }

                if ($line -match ' 001 ' -or $line -match ' 366 ') {
                    break
                }
            } else {
                Start-Sleep -Milliseconds 100
            }
        }

        $writer.WriteLine("PRIVMSG #$channel :$Command")
        Start-Sleep -Milliseconds 300
        Write-Log "IRC sent to #${channel}: $Command"

        $writer.Close()
        $reader.Close()
        $tcp.Close()
    } catch {
        Write-Warning "[auto-events] Twitch IRC send failed: $_"
    }
}

$seEvents = @(
    @{ type = "tip";         amount = 5;   username = "StreamFan1" }
    @{ type = "tip";         amount = 10;  username = "StreamFan2" }
    @{ type = "subscriber";  months = 1;   username = "NewSub1" }
    @{ type = "subscriber";  months = 6;   username = "ResubUser" }
    @{ type = "raid";        viewers = 25; username = "RaidLeader" }
    @{ type = "gifted";      amount = 1;   username = "GiftGiver" }
    @{ type = "gifted";      amount = 5;   username = "MegaGifter" }
    @{ type = "bits";        bits = 100;   username = "BitsCheerer" }
    @{ type = "bits";        bits = 500;   username = "BigBitsDonor" }
    @{ type = "follow";      username = "NewFollower1" }
)

$twitchCommands = @("!fail", "!zibo")
$twitchEnabled = -not [string]::IsNullOrWhiteSpace((Normalize-TwitchOAuth -Token $TwitchOAuth))

Write-Host "=== auto_events started ==="
Write-Host "Bot health: $botHealthUri"
Write-Host "SE endpoint: $seEndpoint"
Write-Host "Delay range: $MinDelaySec-$MaxDelaySec seconds"
Write-Host "Twitch commands enabled: $twitchEnabled"
Write-Host "Press Ctrl+C to stop."

if (-not (Test-BotReady -Uri $botHealthUri -TimeoutSec $HealthTimeoutSec)) {
    throw "Bot did not respond at $botHealthUri within $HealthTimeoutSec seconds. Start the bot first."
}

Write-Log "Bot health check passed. Starting generator loop."

while ($true) {
    $useTwitch = $twitchEnabled -and ($rng.NextDouble() -lt $TwitchChance)

    if ($useTwitch) {
        $command = $twitchCommands[$rng.Next(0, $twitchCommands.Count)]
        Send-TwitchCommand -Command $command
    } else {
        $event = $seEvents[$rng.Next(0, $seEvents.Count)]
        Send-SEEvent -Body $event | Out-Null
    }

    $delay = $rng.Next($MinDelaySec, $MaxDelaySec + 1)
    Write-Log "Next event in $delay seconds."
    Start-Sleep -Seconds $delay
}
