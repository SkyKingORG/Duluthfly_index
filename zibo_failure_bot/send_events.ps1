#Requires -Version 5.1
<#
.SYNOPSIS
  Send test events to the zibo_failure_bot HTTP endpoint or via Twitch IRC.

.DESCRIPTION
  Supports StreamElements/Streamlabs webhook-style POST events and direct
  Twitch IRC chat commands (!fail, !zibo).

.PARAMETER Event
  The event type to send. One of:
    tip, subscribe, raid, gift, bits, follow    (-> StreamElements HTTP)
    fail, zibo                                  (-> Twitch IRC chat command)
    all                                         (-> fires one of each SE event)

.PARAMETER Amount
  Numeric amount for tip/bits/raid/gift/subscribe (default: 1).

.PARAMETER User
  Display name to use in the event payload (default: TestUser).

.PARAMETER BotPort
  HTTP port the bot is listening on (default: 6100).

.PARAMETER TwitchOAuth
  OAuth token for the Twitch IRC sender. Reads TWITCH_OAUTH env var if not set.

.PARAMETER TwitchNick
  Twitch nick for the IRC sender. Reads TWITCH_BOT_NICK env var, default OnlyPilots.

.PARAMETER TwitchChannel
  Twitch channel to send commands in. Reads TWITCH_CHANNEL env var, default #desktoppilotsociety.

.EXAMPLE
  .\send_events.ps1 -Event tip -Amount 5 -User "StreamFan"
  .\send_events.ps1 -Event fail
  .\send_events.ps1 -Event all
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("tip","subscribe","raid","gift","bits","follow","fail","zibo","all")]
    [string]$Event,

    [double]$Amount   = 1,
    [string]$User     = "TestUser",
    [int]   $BotPort  = 6100,

    [string]$TwitchOAuth   = $env:TWITCH_OAUTH,
    [string]$TwitchNick    = $(if ($env:TWITCH_BOT_NICK)    { $env:TWITCH_BOT_NICK }    else { "OnlyPilots" }),
    [string]$TwitchChannel = $(if ($env:TWITCH_CHANNEL)     { $env:TWITCH_CHANNEL }     else { "#desktoppilotsociety" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── helpers ──────────────────────────────────────────────────────────────────

function Send-SEEvent {
    param([hashtable]$Body)
    $url  = "http://127.0.0.1:$BotPort/streamelements"
    $json = $Body | ConvertTo-Json -Compress
    try {
        $resp = Invoke-RestMethod -Uri $url -Method POST `
            -ContentType "application/json" -Body $json -TimeoutSec 5
        Write-Host "[SE] $($Body.type) sent -> $($resp | ConvertTo-Json -Compress)"
    } catch {
        Write-Warning "[SE] POST failed: $_"
    }
}

function Send-TwitchCommand {
    param([string]$Command)

    if (-not $TwitchOAuth -or $TwitchOAuth -eq "oauth:replace_with_token") {
        Write-Warning "[IRC] TWITCH_OAUTH is not set. Cannot send Twitch command."
        return
    }

    $channel = $TwitchChannel.TrimStart("#")
    $server  = "irc.chat.twitch.tv"
    $port    = 6667

    try {
        $tcp    = [System.Net.Sockets.TcpClient]::new($server, $port)
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.AutoFlush = $true

        $writer.WriteLine("PASS $TwitchOAuth")
        $writer.WriteLine("NICK $TwitchNick")
        $writer.WriteLine("JOIN #$channel")

        # Drain join/welcome lines (up to 3 s)
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        while ([DateTime]::UtcNow -lt $deadline -and $tcp.Connected) {
            if ($stream.DataAvailable) {
                $line = $reader.ReadLine()
                if ($line -and $line -match "366") { break }   # End of NAMES = join confirmed
            } else {
                Start-Sleep -Milliseconds 100
            }
        }

        $writer.WriteLine("PRIVMSG #$channel :$Command")
        Start-Sleep -Milliseconds 300
        Write-Host "[IRC] Sent to #$channel`: $Command"

        $writer.Close()
        $reader.Close()
        $tcp.Close()
    } catch {
        Write-Warning "[IRC] Twitch IRC error: $_"
    }
}

# ── event map ────────────────────────────────────────────────────────────────

$se_events = @{
    tip       = @{ type = "tip";          amount = $Amount; username = $User }
    subscribe = @{ type = "subscriber";   months = [int]$Amount; username = $User }
    raid      = @{ type = "raid";         viewers = [int]$Amount; username = $User }
    gift      = @{ type = "gifted";       amount = [int]$Amount; username = $User }
    bits      = @{ type = "bits";         bits   = [int]$Amount; username = $User }
    follow    = @{ type = "follow";       username = $User }
}

$twitch_commands = @{
    fail = "!fail"
    zibo = "!zibo"
}

# ── dispatch ─────────────────────────────────────────────────────────────────

if ($Event -eq "all") {
    Write-Host "=== Sending all SE event types ==="
    foreach ($key in $se_events.Keys) {
        Send-SEEvent -Body $se_events[$key]
        Start-Sleep -Milliseconds 300
    }
} elseif ($se_events.ContainsKey($Event)) {
    Send-SEEvent -Body $se_events[$Event]
} elseif ($twitch_commands.ContainsKey($Event)) {
    Send-TwitchCommand -Command $twitch_commands[$Event]
} else {
    Write-Error "Unknown event: $Event"
}
