#Requires -Version 7.0
<#
  Claude Code PermissionRequest hook: approve or deny a tool call from Telegram.

  Contract (see the repo README):
    - stdout is exactly one decision JSON object on allow/deny, and nothing otherwise.
    - The exit code is always 0. Any error, missing configuration or timeout prints nothing,
      so the normal local permission prompt decides. This script never auto-allows.
    - Only replies from TELEGRAM_CHAT_ID (sender and private chat) that carry the request ID count.

  Secrets: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are read from the process environment, then
  from the User environment (so a running Claude app needs no restart). They are never written
  to stdout, the log or the state file.

  Concurrency: every running copy of this script and of telegram-turn.ps1 shares state\state.json
  under a named mutex (telegram-common.ps1). Whichever copy polls first confirms the Telegram updates
  and files each valid reply under its request ID, so parallel requests never steal each other's replies.
#>
[CmdletBinding()]
param(
    [int]$WindowSeconds = 300,
    [int]$PollSeconds = 2,
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
# Must be set before the first network call in this process.
[AppContext]::SetSwitch('System.Net.DisableIPv6', $true)

$script:Output = $null          # exact text for stdout, or $null to fall through
$script:ToolUseId = $null       # transcript tool_use this request belongs to, once found
$script:LogName = 'telegram-approve'

try { . (Join-Path $PSScriptRoot 'telegram-common.ps1'); Initialize-TelegramCommon }
catch { exit 0 }

$AllowJson = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'

# Claude doesn't cancel this hook when the local dialog answers first, so each poll checks the
# session transcript for a result to our tool call. Only a tool_use that has no result yet is
# adopted, so an earlier identical command can't end the wait by mistake.
function Get-InputKey([string]$Tool, $Ti) {
    if ($Tool -eq 'Bash') { return "$($Ti.command)" }
    return '{0}|{1}|{2}|{3}' -f $Ti.file_path, "$($Ti.content)".Length, "$($Ti.old_string)".Length, "$($Ti.new_string)".Length
}

function Test-AnsweredElsewhere($In) {
    $path = "$($In.transcript_path)"
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
    $lines = Read-TranscriptTail $path
    $hasResult = { param($tid) $needle = '"tool_use_id":"' + $tid + '"'; [bool]($lines | Where-Object { $_.Contains($needle) } | Select-Object -First 1) }
    if (-not $script:ToolUseId) {
        $want = Get-InputKey $In.tool_name $In.tool_input
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if (-not $lines[$i].Contains('"tool_use"')) { continue }
            try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
            $hit = @($o.message.content) | Where-Object { $_.type -eq 'tool_use' -and $_.name -eq $In.tool_name -and (Get-InputKey $_.name $_.input) -eq $want } | Select-Object -Last 1
            if ($hit) {
                if (-not (& $hasResult $hit.id)) { $script:ToolUseId = $hit.id; Write-Log 'watching' "tool_use=$($hit.id)" }
                break
            }
        }
        return $false
    }
    return (& $hasResult $script:ToolUseId)
}

function Format-Request($In, [string]$Id, [datetime]$Expires) {
    $ti = $In.tool_input
    $tool = "$($In.tool_name)"
    $proj = if ($In.cwd) { Split-Path -Leaf "$($In.cwd)" } else { '?' }
    $who = if ($In.agent_type) { " / subagent: $($In.agent_type)" } elseif ($In.agent_id) { ' / subagent' } else { '' }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("`u{1F510} Claude Code wants to use $tool  [$Id]")
    $lines.Add((Limit-Text (Protect-Text "Project: $proj / mode: $($In.permission_mode)$who") 200))
    switch ($tool) {
        'Bash' {
            $lines.Add('$ ' + (Limit-Text (Protect-Text "$($ti.command)") 300))
            if ($ti.description) { $lines.Add('Why: ' + (Limit-Text (Protect-Text "$($ti.description)") 200)) }
        }
        'Write' {
            $lines.Add('File: ' + (Limit-Text (Protect-Text "$($ti.file_path)") 200))
            $lines.Add("Size: $("$($ti.content)".Length) chars (content not sent)")
        }
        'Edit' {
            $lines.Add('File: ' + (Limit-Text (Protect-Text "$($ti.file_path)") 200))
            $all = if ($ti.replace_all) { ', all occurrences' } else { '' }
            $lines.Add("Edit: replace $("$($ti.old_string)".Length) chars with $("$($ti.new_string)".Length) chars$all (content not sent)")
        }
        default {
            $keys = if ($ti) { ($ti.PSObject.Properties.Name -join ', ') } else { '' }
            $lines.Add('Input fields: ' + (Limit-Text (Protect-Text $keys) 200) + ' (values not sent)')
        }
    }
    $lines.Add('')
    $lines.Add("Approve: /yes_$Id")
    $lines.Add("Deny: /no_$Id")
    $lines.Add("or type: yes $Id  /  no $Id <reason>")
    $lines.Add("Expires $($Expires.ToString('HH:mm:ss')); after that, answer at the PC.")
    return ($lines -join "`n")
}

function Invoke-Main {
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), $script:Utf8)
    $in = $reader.ReadToEnd() | ConvertFrom-Json
    $sess = "$($in.session_id)"
    $script:LogCtx = 'tool={0} mode={1} sess={2}' -f $in.tool_name, $in.permission_mode, $sess.Substring(0, [Math]::Min(8, $sess.Length))
    if ($in.hook_event_name -and $in.hook_event_name -ne 'PermissionRequest') { Write-Log 'skip' "event=$($in.hook_event_name)"; return }

    Initialize-Secrets
    $now = Get-Date
    $deadline = $now.AddSeconds($WindowSeconds)
    if ($PreviewMessage) { $script:Output = Format-Request $in 'abc234' $deadline; return }
    if (-not (Test-Configured)) { Write-Log 'not-configured'; return }

    Remove-OldLogs
    $id = Use-State {
        param($st)
        $new = New-RequestId $st
        $st.pending[$new] = @{ kind = 'approve'; pid = $PID; created = (Get-UnixNow); expires = ([DateTimeOffset]$deadline).ToUnixTimeSeconds() }
        return $new
    }
    $script:ReqId = $id
    Write-Log 'start' "window=$WindowSeconds"

    try { $null = Send-Text 'request' (Format-Request $in $id $deadline) 3 }
    catch {
        $null = Use-State { param($st) $st.pending.Remove($id) }
        return
    }

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $elsewhere = $false
        try { $elsewhere = Test-AnsweredElsewhere $in } catch { Write-Log 'transcript-error' "$($_.Exception.Message)" }
        if ($elsewhere) {
            $null = Use-State { param($st) $st.pending.Remove($id); $st.done[$id] = @{ result = 'answered at the PC'; at = (Get-UnixNow) } }
            Write-Log 'answered-elsewhere' "tool_use=$($script:ToolUseId)"
            try { $null = Send-Text 'elsewhere' "`u{1F5A5} $id was answered at the PC. Nothing to do here." 1 5 } catch { }
            return
        }
        try {
            $step = Use-State {
                param($st)
                $replies = Receive-Replies $st
                $mine = Get-MyReply $st $id { param($r) if ($r.verb -eq 'yes') { 'allowed' } else { 'denied' } }
                return @{ mine = $mine; replies = $replies }
            }
        } catch {
            Write-Log 'poll-error' "$($_.Exception.Message)"
            continue
        }
        foreach ($r in $step.replies) { try { $null = Send-Text 'stale-reply' $r } catch { } }
        if ($step.mine) {
            if ($step.mine.verb -eq 'yes') {
                $script:Output = $AllowJson
                Write-Log 'decision' 'allow'
                try { $null = Send-Text 'confirm' "`u{2705} Allowed $id" 1 5 } catch { }
            } else {
                $msg = "The user denied this from their phone (Telegram, request $id)."
                if ($step.mine.reason) { $msg += ' Reason: ' + (Limit-Text "$($step.mine.reason)" 300) }
                $script:Output = @{ hookSpecificOutput = [ordered]@{ hookEventName = 'PermissionRequest'; decision = [ordered]@{ behavior = 'deny'; message = $msg } } } |
                    ConvertTo-Json -Compress -Depth 5 -EscapeHandling EscapeNonAscii
                Write-Log 'decision' 'deny'
                try { $null = Send-Text 'confirm' "`u{26D4} Denied $id" 1 5 } catch { }
            }
            return
        }
    }

    $null = Use-State { param($st) $st.pending.Remove($id); $st.done[$id] = @{ result = 'timed out'; at = (Get-UnixNow) } }
    Write-Log 'timeout' 'no reply; falling back to the local prompt'
    try { $null = Send-Text 'timeout' "`u{23F1} Timed out $id. Nothing was approved; answer at the PC." 1 5 } catch { }
}

try { $null = Invoke-Main }
catch { $script:Output = $null; Write-Log 'error' "$($_.Exception.Message)" }

if ($script:Output) { Write-Stdout $script:Output }
exit 0
