#Requires -Version 5.1
<#
.SYNOPSIS
  Automatically relays paired events to the bot's StreamElements endpoint AND
  sends matching commands to Twitch chat.  Starts immediately when the bot
  starts and runs until the window is closed.

.PARAMETER BotPort      HTTP port the bot listens on (default: 6100).
.PARAMETER MinDelaySec  Minimum seconds between event pairs (default: 15).
.PARAMETER MaxDelaySec  Maximum seconds between event pairs (default: 60).
#>

param(
    [int]   $BotPort      = 6100,
    [int]   $MinDelaySec  = 15,
    [int]   $MaxDelaySec  = 60,
    [string]$TwitchOAuth   = $env:TWITCH_OAUTH,
    [string]$TwitchNick    = $(if ($env:TWITCH_BOT_NICK) { $env:TWITCH_BOT_NICK } else { "OnlyPilots" }),
    [string]$TwitchChannel = $(if ($env:TWITCH_CHANNEL)  { $env:TWITCH_CHANNEL  } else { "#desktoppilotsociety" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"
$rng = [System.Random]::new()

# ── Event pairs: each entry sends an SE payload AND a Twitch chat command ─────

$event_pairs = @(
    @{ se = @{ type = "tip";        amount   = 5;   username = "TipperFan"     }; irc = "!fail"  }
    @{ se = @{ type = "tip";        amount   = 10;  username = "BigTipper"     }; irc = "!zibo"  }
    @{ se = @{ type = "tip";        amount   = 20;  username = "GenerousFan"   }; irc = "!fail"  }
    @{ se = @{ type = "subscriber"; months   = 1;   username = "NewSub"        }; irc = "!zibo"  }
    @{ se = @{ type = "subscriber"; months   = 3;   username = "LoyalSub"      }; irc = "!fail"  }
    @{ se = @{ type = "subscriber"; months   = 12;  username = "VeteranSub"    }; irc = "!zibo"  }
    @{ se = @{ type = "raid";       viewers  = 15;  username = "RaidBoss"      }; irc = "!fail"  }
    @{ se = @{ type = "raid";       viewers  = 50;  username = "MegaRaider"    }; irc = "!zibo"  }
    @{ se = @{ type = "gifted";     amount   = 1;   username = "GiftGiver"     }; irc = "!fail"  }
    @{ se = @{ type = "gifted";     amount   = 5;   username = "GiftBomber"    }; irc = "!zibo"  }
    @{ se = @{ type = "bits";       bits     = 100; username = "BitsFan"       }; irc = "!fail"  }
    @{ se = @{ type = "bits";       bits     = 500; username = "BigBitsDonor"  }; irc = "!zibo"  }
    @{ se = @{ type = "follow";     username = "NewFollower"                   }; irc = "!fail"  }
)

# ── helpers ───────────────────────────────────────────────────────────────────

function Send-SEEvent([hashtable]$Body) {
    $url  = "http://127.0.0.1:$BotPort/streamelements"
    $json = $Body | ConvertTo-Json -Compress
    try {
        $null = Invoke-RestMethod -Uri $url -Method POST `
            -ContentType "application/json" -Body $json -TimeoutSec 5
        Write-Host "[$(Get-Date -f 'HH:mm:ss')] [SE ] $($Body.type) <- $($Body.username)"
    } catch {
        Write-Warning "[SE ] POST failed (is the bot running?): $_"
    }
}

function Send-TwitchCommand([string]$Command) {
    if (-not $TwitchOAuth -or $TwitchOAuth -eq "oauth:replace_with_token") {
        Write-Warning "[IRC] TWITCH_OAUTH not set — skipping."
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

        $deadline = [DateTime]::UtcNow.AddSeconds(4)
        while ([DateTime]::UtcNow -lt $deadline -and $tcp.Connected) {
            if ($stream.DataAvailable) {
                if ($reader.ReadLine() -match "366") { break }
            } else { [System.Threading.Thread]::Sleep(100) }
        }

        $writer.WriteLine("PRIVMSG #$channel :$Command")
        [System.Threading.Thread]::Sleep(300)
        Write-Host "[$(Get-Date -f 'HH:mm:ss')] [IRC] $Command -> #$channel"

        $writer.Close(); $reader.Close(); $tcp.Close()
    } catch {
        Write-Warning "[IRC] Error: $_"
    }
}

function Send-EventPair([hashtable]$Pair) {
    Send-SEEvent   -Body    $Pair.se
    Send-TwitchCommand -Command $Pair.irc
}

# ── wait for bot to be ready ──────────────────────────────────────────────────

Write-Host "=== event_relay starting. Waiting for bot on port $BotPort... ==="
$ready = $false
for ($i = 0; $i -lt 20; $i++) {
    try {
        $null = Invoke-RestMethod "http://127.0.0.1:$BotPort/health" -TimeoutSec 2
        $ready = $true; break
    } catch { [System.Threading.Thread]::Sleep(2000) }
}
if (-not $ready) { Write-Warning "Bot did not respond on port $BotPort — sending anyway." }

Write-Host "=== relay active. Firing events every ${MinDelaySec}-${MaxDelaySec}s. Ctrl+C to stop. ==="
Write-Host ""

# ── main loop ─────────────────────────────────────────────────────────────────

while ($true) {
    $pair = $event_pairs[$rng.Next(0, $event_pairs.Count)]
    Send-EventPair -Pair $pair

    $delay = $rng.Next($MinDelaySec, $MaxDelaySec + 1)
    Write-Host "[$(Get-Date -f 'HH:mm:ss')] Next in $delay s..."
    Start-Sleep -Seconds $delay
}
