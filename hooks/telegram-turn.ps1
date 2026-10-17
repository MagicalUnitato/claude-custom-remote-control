#Requires -Version 7.0
<#
  Claude Code Stop hook: tell the phone when a session ends its turn with a question, and let a
  Telegram reply continue the session.

  Registered with "async": true and "asyncRewake": true, so the turn ends normally and this script
  keeps running in the background:
    - It reads the turn's "next step" box (the desktop app's mcp__ccd_turn__wrap_up call) from the
      transcript, falling back to last_assistant_message, and sends it, redacted and shortened.
    - It then waits up to $WindowSeconds for "re <id> <text>", a tapped "/re_<id>_<n>" button, or a
      swipe-reply to the alert. On one, it prints the reply to stderr and exits 2, which wakes Claude
      with that text. Otherwise it exits 0 and prints nothing.
    - It stops waiting, silently, when the session moves on at the PC (a new prompt in the transcript),
      when a newer turn of the same session starts its own wait, or when the session's process exits.

  TELEGRAM_TURN_ALERTS (Process, then User environment): 'ask' (default) alerts only when the box has a
  question, 'all' alerts on every turn end, 'off' disables this hook.

  Secrets and state work as in telegram-approve.ps1 (see telegram-common.ps1 and the repo README).
#>
[CmdletBinding()]
param(
    [int]$WindowSeconds = 1800,
    [int]$PollSeconds = 4,
    # Test-only parameters; the registered hook passes none of these.
    [string]$FakeUpdatesPath,
    [switch]$NoSend,
    [switch]$PreviewMessage,
    [string]$StateDir = (Join-Path $PSScriptRoot 'state'),
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# IPv6 to api.telegram.org can hang for 10+ s on some networks; IPv4 is reliable.
[AppContext]::SetSwitch('System.Net.DisableIPv6', $true)

$script:ExitCode = 0
$script:Wake = $null            # text for stderr when a reply wakes Claude
$script:LogName = 'telegram-turn'

try { . (Join-Path $PSScriptRoot 'telegram-common.ps1'); Initialize-TelegramCommon }
catch { exit 0 }

$WrapUpTool = 'mcp__ccd_turn__wrap_up'
$StartTool = 'mcp__ccd_session__start_session'
$BoxMaxAgeSeconds = 900         # a box older than this belongs to an earlier turn

function Test-PromptLine([string]$Line) {
    # A new user prompt or a message queued for the session: the turn after ours has begun.
    if ($Line.Contains('"type":"queue-operation"') -and $Line.Contains('"operation":"enqueue"')) { return $true }
    return ($Line.Contains('"type":"user"') -and $Line.Contains('"promptId"') -and -not $Line.Contains('"tool_result"'))
}

# The current turn's wrap_up input (recap, ask, actions), or $null. Only looks back to the turn's prompt.
function Find-Box([string[]]$Lines) {
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $line = $Lines[$i]
        if (Test-PromptLine $line) { return $null }
        if (-not ($line.Contains($WrapUpTool) -and $line.Contains('"tool_use"'))) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $hit = @($o.message.content) | Where-Object { $_.type -eq 'tool_use' -and $_.name -eq $WrapUpTool } | Select-Object -Last 1
        if (-not $hit) { continue }
        $at = try { [DateTimeOffset]::Parse("$($o.timestamp)").ToUnixTimeSeconds() } catch { 0 }
        if ($at -and (Get-UnixNow) - $at -gt $BoxMaxAgeSeconds) { return $null }
        return $hit.input
    }
    return $null
}

# Titles of "New session" cards proposed in the current turn (start_session with initiation
# own_initiative). They can't be started from the phone; the alert only tells you they're waiting.
function Find-Cards([string[]]$Lines) {
    $titles = [Collections.Generic.List[string]]::new()
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $line = $Lines[$i]
        if (Test-PromptLine $line) { break }
        if (-not ($line.Contains($StartTool) -and $line.Contains('"tool_use"'))) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        foreach ($c in @($o.message.content)) {
            if ($c.type -eq 'tool_use' -and $c.name -eq $StartTool -and "$($c.input.initiation)" -eq 'own_initiative' -and
                "$($c.input.title)".Trim() -and -not $c.input.proposal_id) { $titles.Insert(0, "$($c.input.title)".Trim()) }
        }
    }
    return $titles
}

function Get-Buttons($Box) {
    $list = [Collections.Generic.List[object]]::new()
    foreach ($a in @($Box.actions)) {
        if (-not $a) { continue }
        $label = if ($a.label) { "$($a.label)" } else { "$($a.action)" }
        if (-not $label) { continue }
        $list.Add(@{ label = $label; message = "$($a.message)"; action = "$($a.action)" })
        if ($list.Count -ge 9) { break }
    }
    return $list
}

function Format-Alert($In, $Box, $Buttons, $Cards, [string]$Id, [datetime]$Expires) {
    $proj = if ($In.cwd) { Split-Path -Leaf "$($In.cwd)" } else { '?' }
    $sess = "$($In.session_id)"; $sess = $sess.Substring(0, [Math]::Min(8, $sess.Length))
    $lines = [Collections.Generic.List[string]]::new()
    if ($Box.ask) { $lines.Add("`u{2753} Claude is waiting on you  [$Id]") }
    elseif ($Cards.Count) { $lines.Add("`u{1F195} Claude proposed a new session  [$Id]") }
    else { $lines.Add("`u{1F4AC} Claude finished a turn  [$Id]") }
    $lines.Add((Limit-Text (Protect-Text "Project: $proj / session $sess") 200))
    if ($Box.ask) { $lines.Add(''); $lines.Add((Limit-Text (Protect-Text "$($Box.ask)") 300)) }
    if ($Cards.Count) {
        $lines.Add('')
        $lines.Add('New session card' + $(if ($Cards.Count -gt 1) { 's' } else { '' }) + ' waiting in the app (start at the PC):')
        foreach ($t in ($Cards | Select-Object -First 5)) { $lines.Add("`u{1F195} " + (Limit-Text (Protect-Text $t) 80)) }
    }
    $body = if ($Box.recap) { "$($Box.recap)" } else { "$($In.last_assistant_message)" }
    if ($body.Trim()) { $lines.Add(''); $lines.Add((Limit-Text (Protect-Text $body.Trim()) 500)) }
    $lines.Add('')
    if ($Buttons.Count) {
        $lines.Add('Tap to answer:')
        for ($n = 1; $n -le $Buttons.Count; $n++) { $lines.Add("/re_$($Id)_$n  " + (Limit-Text (Protect-Text $Buttons[$n - 1].label) 60)) }
    }
    $lines.Add("Or swipe-reply to this message, or type: re $Id <answer>")
    $lines.Add("Open until $($Expires.ToString('HH:mm')); after that, answer at the PC.")
    return ($lines -join "`n")
}

function Format-Wake($Reply, $Buttons, [string]$Id) {
    $n = [int]$Reply.button
    if ($n -ge 1 -and $n -le $Buttons.Count) {
        $b = $Buttons[$n - 1]
        if ($b.action) {
            return "The user tapped the app button `"$($b.label)`" ($($b.action)) from their phone via Telegram (request $Id). The app button itself can't be pressed remotely."
        }
        $send = if ($b.message) { $b.message } else { $b.label }
        $msg = "The user answered your last question from their phone via Telegram (request $Id) by tapping `"$($b.label)`", which says:`n$send"
        if ($Reply.reason) { $msg += "`nThey added: " + (Limit-Text "$($Reply.reason)" 2000) }
        return $msg
    }
    return "The user replied from their phone via Telegram (request $Id) to your last message:`n" + (Limit-Text "$($Reply.reason)" 4000)
}

function Get-ParentPid {
    try { return [int](Get-Process -Id $PID).Parent.Id } catch { return 0 }
}

function Invoke-Main {
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), $script:Utf8)
    $in = $reader.ReadToEnd() | ConvertFrom-Json
    $sess = "$($in.session_id)"
    $script:LogCtx = 'mode={0} sess={1}' -f $in.permission_mode, $sess.Substring(0, [Math]::Min(8, $sess.Length))
    if ($in.hook_event_name -and $in.hook_event_name -ne 'Stop') { Write-Log 'skip' "event=$($in.hook_event_name)"; return }

    $alerts = "$(Get-Setting 'TELEGRAM_TURN_ALERTS')".Trim().ToLowerInvariant()
    if (-not $alerts) { $alerts = 'ask' }
    if ($alerts -eq 'off') { return }

    Initialize-Secrets
    $path = "$($in.transcript_path)"
    $box = $null; $startLen = 0; $cards = @()
    # The box is written before the turn's last message, but give a slow flush a moment.
    for ($try = 1; $try -le 3; $try++) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $startLen = (Get-Item -LiteralPath $path).Length
            $tail = Read-TranscriptTail $path
            $box = Find-Box $tail
            $cards = @(Find-Cards $tail)
        }
        if ($box -or $PreviewMessage) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $box) { $box = [pscustomobject]@{ recap = $null; ask = $null; actions = @() } }
    if ($alerts -ne 'all' -and -not "$($box.ask)".Trim() -and -not $cards.Count) { Write-Log 'no-question' "box=$([bool]$box.recap)"; return }
    if ($alerts -eq 'all' -and -not "$($box.ask)$($box.recap)$($in.last_assistant_message)".Trim() -and -not $cards.Count) { Write-Log 'empty-turn'; return }

    $buttons = @(Get-Buttons $box)   # @(): a single button must stay a one-item list
    $deadline = (Get-Date).AddSeconds($WindowSeconds)
    if ($PreviewMessage) { Write-Stdout (Format-Alert $in $box $buttons $cards 'abc234' $deadline); return }
    if (-not (Test-Configured)) { Write-Log 'not-configured'; return }

    Remove-OldLogs
    $parentPid = Get-ParentPid
    $id = Use-State {
        param($st)
        $new = New-RequestId $st
        # Only the latest turn of a session waits; an older wait for it ends on its next poll.
        foreach ($k in @($st.pending.Keys)) {
            $e = $st.pending[$k]
            if ($e.kind -eq 'turn' -and "$($e.sess)" -eq $sess) {
                $st.pending.Remove($k); $st.done[$k] = @{ result = 'superseded by a newer turn'; at = (Get-UnixNow) }
            }
        }
        $st.pending[$new] = @{ kind = 'turn'; sess = $sess; pid = $PID; created = (Get-UnixNow); expires = ([DateTimeOffset]$deadline).ToUnixTimeSeconds(); msg_id = 0 }
        return $new
    }
    $script:ReqId = $id
    Write-Log 'start' "window=$WindowSeconds alerts=$alerts ask=$([bool]$box.ask) buttons=$($buttons.Count) cards=$($cards.Count) parent=$parentPid"

    try { $msgId = Send-Text 'alert' (Format-Alert $in $box $buttons $cards $id $deadline) 3 }
    catch {
        $null = Use-State { param($st) $st.pending.Remove($id) }
        return
    }
    if ($msgId) { $null = Use-State { param($st) if ($st.pending.Contains($id)) { $st.pending[$id].msg_id = $msgId } } }

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $end = $null
        try {
            if ($path -and (Test-Path -LiteralPath $path)) {
                $len = (Get-Item -LiteralPath $path).Length
                if ($len -gt $startLen) {
                    if (@(Read-TranscriptTail $path $startLen | Where-Object { Test-PromptLine $_ }).Count) { $end = 'answered at the PC' }
                    else { $startLen = $len }
                }
            }
        } catch { Write-Log 'transcript-error' "$($_.Exception.Message)" }
        if (-not $end -and $parentPid -and -not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { $end = 'session closed' }
        if ($end) {
            $null = Use-State { param($st) $st.pending.Remove($id); $st.done[$id] = @{ result = $end; at = (Get-UnixNow) } }
            Write-Log 'moved-on' $end
            return
        }
        try {
            $step = Use-State {
                param($st)
                $replies = Receive-Replies $st
                $mine = Get-MyReply $st $id { param($r) 'answered from the phone' }
                return @{ mine = $mine; replies = $replies; gone = (-not $mine -and -not $st.pending.Contains($id)) }
            }
        } catch {
            Write-Log 'poll-error' "$($_.Exception.Message)"
            continue
        }
        foreach ($r in $step.replies) { try { $null = Send-Text 'stale-reply' $r } catch { } }
        if ($step.mine) {
            $script:Wake = Format-Wake $step.mine $buttons $id
            $script:ExitCode = 2
            Write-Log 'reply' "button=$($step.mine.button) len=$("$($step.mine.reason)".Length)"
            try { $null = Send-Text 'confirm' "`u{21A9} Sent to Claude ($id)" 1 5 } catch { }
            return
        }
        if ($step.gone) { Write-Log 'superseded'; return }
    }

    $null = Use-State { param($st) $st.pending.Remove($id); $st.done[$id] = @{ result = 'timed out'; at = (Get-UnixNow) } }
    Write-Log 'timeout' 'no reply'
}

try { $null = Invoke-Main }
catch { $script:Wake = $null; $script:ExitCode = 0; Write-Log 'error' "$($_.Exception.Message)" }

if ($script:Wake) {
    $bytes = $script:Utf8.GetBytes($script:Wake)
    $stderr = [Console]::OpenStandardError()
    $stderr.Write($bytes, 0, $bytes.Length)
    $stderr.Flush()
}
exit $script:ExitCode
