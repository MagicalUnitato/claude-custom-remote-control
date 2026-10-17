#Requires -Version 7.0
<#
  Shared code for the Telegram hooks (telegram-approve.ps1, telegram-turn.ps1). Dot-source it after the
  caller's param block. The caller defines $StateDir, $LogDir, $NoSend and $FakeUpdatesPath, and sets
  $script:LogName (log file prefix) before calling Initialize-TelegramCommon.

  Both hooks share state\state.json and one named mutex, and both parse every reply format here, so a
  copy of either script that polls first files each valid reply under its request ID for the copy that
  owns it. Neither steals the other's replies.

  Pending entries carry `kind`: 'approve' (yes/no) or 'turn' (re <id> <text>). Entries without one are
  'approve', as written by older copies.
#>

$script:Token = $null
$script:ChatId = $null
$script:SecretValues = @()
$script:ReqId = '-'
$script:LogCtx = ''
$script:Utf8 = [Text.UTF8Encoding]::new($false)

$IdAlphabet = 'abcdefghjkmnpqrstuvwxyz23456789'
$ReplyMaxAgeSeconds = 600       # answer "expired" only to recent messages, not to a day-old backlog

# Patterns are applied in order; each replacement keeps enough context to read the text.
$script:Redactions = @(
    , @('(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}', '$1 [redacted]')
    , @('(?i)\b(?:sk|rk|pk)-[A-Za-z0-9_-]{10,}', '[redacted-key]')
    , @('\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})', '[redacted-github-token]')
    , @('\bxox[abposr]-[A-Za-z0-9-]{10,}', '[redacted-slack-token]')
    , @('\b(?:AKIA|ASIA)[0-9A-Z]{16}\b', '[redacted-aws-key]')
    , @('\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}', '[redacted-jwt]')
    , @('(?i)(\w+://[^/\s:@]+:)[^@\s/]+@', '$1[redacted]@')
    , @('(?i)((?:password|passwd|pwd|secret|token|api[_-]?key|apikey|access[_-]?key|auth)[A-Za-z0-9_-]*["'']?\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s&;,]+)', '$1[redacted]')
    , @('(?i)(--?(?:password|passwd|pwd|secret|token|api-?key|auth)[A-Za-z0-9-]*(?:\s+|=))("[^"]*"|''[^'']*''|\S+)', '$1[redacted]')
    , @('\b[0-9a-fA-F]{32,}\b', '[redacted-hex]')
    , @('(?<![A-Za-z0-9+/_-])(?=[A-Za-z0-9+/_-]*\d)(?=[A-Za-z0-9+/_-]*[a-z])(?=[A-Za-z0-9+/_-]*[A-Z])[A-Za-z0-9+/_-]{32,}={0,2}', '[redacted-blob]')
)

function Initialize-TelegramCommon {
    # Same name for every copy of either script that uses this state folder.
    $hash = [Security.Cryptography.SHA256]::HashData($script:Utf8.GetBytes($StateDir.ToLowerInvariant()))
    $script:MutexName = 'Local\ClaudeTelegramApprove-' + [Convert]::ToHexString($hash).Substring(0, 12)
}

function Get-Setting([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    return $v
}

# Reads the token and chat ID, and every secret-looking environment value, for redaction.
function Initialize-Secrets {
    $script:Token = Get-Setting 'TELEGRAM_BOT_TOKEN'
    $script:ChatId = Get-Setting 'TELEGRAM_CHAT_ID'
    $secrets = @(Get-ChildItem env: | Where-Object { $_.Name -match 'TOKEN|SECRET|PASSWORD|PASSWD|KEY|CREDENTIAL' -and "$($_.Value)".Length -ge 8 } | ForEach-Object Value)
    $secrets += @($script:Token, $script:ChatId) | Where-Object { $_ }
    $script:SecretValues = @($secrets | Select-Object -Unique | Sort-Object Length -Descending)
}

function Test-Configured { [bool]($script:Token -and $script:ChatId -match '^\d+$') }

function Get-UnixNow { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Protect-Text([string]$Text) {
    if (-not $Text) { return '' }
    foreach ($v in $script:SecretValues) { $Text = $Text.Replace($v, '[redacted]') }
    foreach ($r in $script:Redactions) { $Text = [regex]::Replace($Text, $r[0], $r[1]) }
    return $Text
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + '...'
}

function Write-Log([string]$Event, [string]$Detail = '') {
    try {
        if (-not (Test-Path $LogDir)) { $null = New-Item -ItemType Directory -Path $LogDir -Force }
        $file = Join-Path $LogDir ('{0}-{1:yyyy-MM}.log' -f $script:LogName, (Get-Date))
        $line = '{0:yyyy-MM-ddTHH:mm:ss.fffzzz} pid={1} id={2} {3} ev={4} {5}' -f (Get-Date), $PID, $script:ReqId, $script:LogCtx, $Event, (Protect-Text $Detail)
        for ($i = 0; $i -lt 5; $i++) {
            try { [IO.File]::AppendAllText($file, $line.TrimEnd() + "`n", $script:Utf8); break }
            catch [IO.IOException] { Start-Sleep -Milliseconds (20 + (Get-Random -Maximum 80)) }
        }
    } catch { }
}

function Remove-OldLogs {
    # Monthly files older than 90 days go to the Recycle Bin, never a hard delete.
    try {
        $old = @(Get-ChildItem -Path $LogDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(telegram-|push-merge-gate-)' -and $_.LastWriteTime -lt (Get-Date).AddDays(-90) })
        if ($old.Count -eq 0) { return }
        Add-Type -AssemblyName Microsoft.VisualBasic
        foreach ($f in $old) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
        }
    } catch { }
}

function Invoke-Telegram([string]$Method, [hashtable]$Body, [int]$TimeoutSec = 10) {
    $json = $Body | ConvertTo-Json -Compress -Depth 5
    try {
        $r = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($script:Token)/$Method" `
            -ContentType 'application/json; charset=utf-8' -Body $script:Utf8.GetBytes($json) -TimeoutSec $TimeoutSec
    } catch {
        $msg = "$($_.Exception.Message)"
        if ($script:Token) { $msg = $msg.Replace($script:Token, '<token>') }
        throw "Telegram $Method failed: $msg"
    }
    if (-not $r.ok) { throw "Telegram $Method returned ok=false" }
    return $r
}

# Returns the sent message's ID (0 with -NoSend).
function Send-Text([string]$Kind, [string]$Text, [int]$Attempts = 2, [int]$TimeoutSec = 10) {
    if ($NoSend) { Write-Log 'send-skipped' "kind=$Kind len=$($Text.Length)"; return 0 }
    # A retry after a lost response can mean a duplicate message, which is harmless (same ID).
    for ($attempt = 1; ; $attempt++) {
        try {
            $r = Invoke-Telegram 'sendMessage' @{
                chat_id              = $script:ChatId
                text                 = $Text
                link_preview_options = @{ is_disabled = $true }
            } $TimeoutSec
            Write-Log 'sent' "kind=$Kind attempt=$attempt"
            return [long]$r.result.message_id
        } catch {
            Write-Log 'send-failed' "kind=$Kind attempt=$attempt $($_.Exception.Message)"
            if ($attempt -ge $Attempts) { throw }
        }
    }
}

function Read-TranscriptTail([string]$Path, [long]$From = -1) {
    # Reads from byte $From (or the last 2 MB, whichever is later) to the end, split into lines.
    $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try {
        $start = [Math]::Max($fs.Length - 2MB, [Math]::Max($From, 0))
        $take = [int]($fs.Length - $start)
        if ($take -le 0) { return @() }
        $null = $fs.Seek($start, [IO.SeekOrigin]::Begin)
        $buf = [byte[]]::new($take); $read = 0
        while ($read -lt $take) { $n = $fs.Read($buf, $read, $take - $read); if ($n -le 0) { break }; $read += $n }
        return $script:Utf8.GetString($buf, 0, $read) -split "`n"
    } finally { $fs.Dispose() }
}

function Get-NewUpdates([long]$Cursor) {
    if ($FakeUpdatesPath) {
        if (-not (Test-Path $FakeUpdatesPath)) { return @() }
        $r = Get-Content -Raw -Path $FakeUpdatesPath | ConvertFrom-Json
    } else {
        # Short client timeout: an occasional hung call only skips one poll; unconfirmed updates stay on the server.
        $r = Invoke-Telegram 'getUpdates' @{ offset = $Cursor + 1; timeout = 0; allowed_updates = @('message') } 5
    }
    return @($r.result | Where-Object { [long]$_.update_id -gt $Cursor } | Sort-Object { [long]$_.update_id })
}

function ConvertFrom-Reply([string]$Text) {
    # "yes <id>", "no <id> [reason]", "/yes_<id>", "/no_<id>[@bot]" answer a permission request.
    if ($Text -match '(?is)^\s*/?(yes|no)[_\s]+([a-z0-9]{6})(?:@\w+)?(?:\s+(.+?))?\s*$') {
        return @{ verb = $Matches[1].ToLowerInvariant(); id = $Matches[2].ToLowerInvariant(); reason = "$($Matches[3])"; button = 0 }
    }
    # "re <id> <text>" or the tappable "/re_<id>_<n>[@bot]" answer an end-of-turn question.
    if ($Text -match '(?is)^\s*/?re[_\s]+([a-z0-9]{6})(?:_(\d))?(?:@\w+)?(?:\s+(.+?))?\s*$') {
        return @{ verb = 're'; id = $Matches[1].ToLowerInvariant(); reason = "$($Matches[3])"; button = [int]("0$($Matches[2])") }
    }
    return $null
}

function Read-State {
    $path = Join-Path $StateDir 'state.json'
    $st = $null
    if (Test-Path $path) {
        try { $st = Get-Content -Raw -Path $path | ConvertFrom-Json -AsHashtable }
        catch { Write-Log 'state-reset' 'state file unreadable' }
    }
    if ($st -isnot [Collections.IDictionary]) { $st = @{} }
    foreach ($k in 'pending', 'done') { if ($st[$k] -isnot [Collections.IDictionary]) { $st[$k] = @{} } }
    $inbox = [Collections.Generic.List[object]]::new()
    foreach ($e in @($st['inbox'])) { if ($e) { $inbox.Add($e) } }
    $st['inbox'] = $inbox
    $st['cursor'] = [long]($st['cursor'] ?? 0)
    return $st
}

function Test-PendingAlive($Pending) {
    if (-not $Pending) { return $false }
    if ([long]$Pending.expires -lt (Get-UnixNow)) { return $false }
    if ([int]$Pending.pid -eq $PID) { return $true }
    return [bool](Get-Process -Id ([int]$Pending.pid) -ErrorAction SilentlyContinue)
}

function Write-State($St) {
    $now = Get-UnixNow
    foreach ($k in @($St.pending.Keys)) { if (-not (Test-PendingAlive $St.pending[$k])) { $St.pending.Remove($k) } }
    foreach ($k in @($St.done.Keys)) { if ([long]$St.done[$k].at -lt $now - 86400) { $St.done.Remove($k) } }
    $keep = [Collections.Generic.List[object]]::new()
    foreach ($e in $St.inbox) { if ($St.pending.Contains($e.id)) { $keep.Add($e) } }
    $St.inbox = $keep
    if (-not (Test-Path $StateDir)) { $null = New-Item -ItemType Directory -Path $StateDir -Force }
    [IO.File]::WriteAllText((Join-Path $StateDir 'state.json'), ($St | ConvertTo-Json -Depth 6 -Compress), $script:Utf8)
}

function Use-State([scriptblock]$Action) {
    $mutex = [Threading.Mutex]::new($false, $script:MutexName)
    $held = $false
    try {
        try { $held = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'timed out waiting for the state lock' }
        $st = Read-State
        $result = & $Action $st
        Write-State $st
        return $result
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function New-RequestId($St) {
    do { $new = -join (1..6 | ForEach-Object { $IdAlphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($IdAlphabet.Length)] }) }
    while ($St.pending.Contains($new) -or $St.done.Contains($new))
    return $new
}

# Call inside Use-State. Fetches new updates, advances the shared cursor and files each valid reply
# under its request ID in the inbox, for whichever copy owns it. Returns texts to send back for
# replies that can't be filed (expired, already answered, wrong format for that request).
function Receive-Replies($St) {
    $replies = [Collections.Generic.List[string]]::new()
    foreach ($u in (Get-NewUpdates $St.cursor)) {
        $St.cursor = [long]$u.update_id
        $m = $u.message
        $tag = "update=$($u.update_id)"
        if (-not $m) { Write-Log 'ignored' "$tag reason=not-a-message"; continue }
        if ("$($m.from.id)" -ne $script:ChatId -or "$($m.chat.id)" -ne $script:ChatId -or "$($m.chat.type)" -ne 'private') {
            Write-Log 'ignored' "$tag reason=wrong-sender-or-chat"; continue
        }
        $p = ConvertFrom-Reply "$($m.text)"
        if (-not $p -and $m.reply_to_message -and "$($m.text)".Trim()) {
            # A swipe-reply to a turn alert answers that alert with the whole text.
            $to = [long]$m.reply_to_message.message_id
            foreach ($k in @($St.pending.Keys)) {
                $e = $St.pending[$k]
                if ($e.kind -eq 'turn' -and [long]($e.msg_id ?? 0) -eq $to -and $to -ne 0) {
                    $p = @{ verb = 're'; id = $k; reason = "$($m.text)".Trim(); button = 0 }; break
                }
            }
        }
        if (-not $p) { Write-Log 'ignored' "$tag reason=not-a-reply"; continue }
        $pend = $St.pending[$p.id]
        if ((Test-PendingAlive $pend) -and [long]$m.date -ge [long]$pend.created - 60) {
            $kind = $pend.kind ?? 'approve'
            $hint = $null
            if ($kind -eq 'approve' -and $p.verb -eq 're') { $hint = "$($p.id) is a permission request. Tap /yes_$($p.id) or /no_$($p.id)." }
            elseif ($kind -eq 'turn' -and $p.verb -ne 're') { $hint = "$($p.id) is a question. Reply: re $($p.id) <your answer>" }
            elseif ($p.verb -eq 're' -and -not $p.reason -and $p.button -eq 0) { $hint = "Nothing to send. Reply: re $($p.id) <your answer>" }
            if ($hint) {
                Write-Log 'ignored' "$tag reason=wrong-format for=$($p.id) verb=$($p.verb)"
                $replies.Add("`u{2753} $hint"); continue
            }
            $St.inbox.Add(@{ update_id = [long]$u.update_id; id = $p.id; verb = $p.verb; reason = $p.reason; button = $p.button })
            Write-Log 'queued' "$tag for=$($p.id) verb=$($p.verb)"
            continue
        }
        $prior = $St.done[$p.id]
        $why = if ($prior) { "already-$($prior.result)" } else { 'unknown-or-expired' }
        Write-Log 'ignored' "$tag reason=stale-id for=$($p.id) $why"
        if ((Get-UnixNow) - [long]$m.date -le $ReplyMaxAgeSeconds) {
            $replies.Add($(if ($prior) { "`u{23F1} $($p.id) was already answered ($($prior.result)). Nothing changed." }
                    else { "`u{23F1} $($p.id) is expired or unknown. Nothing was sent or approved." }))
        }
    }
    return $replies
}

# Takes this request's first queued reply out of the inbox and marks the request done.
function Get-MyReply($St, [string]$Id, [scriptblock]$Result) {
    $mine = $St.inbox | Where-Object { $_.id -eq $Id } | Sort-Object { [long]$_.update_id } | Select-Object -First 1
    if ($mine) {
        $St.pending.Remove($Id)
        $St.done[$Id] = @{ result = (& $Result $mine); at = (Get-UnixNow) }
    }
    return $mine
}

function Write-Stdout([string]$Text) {
    $bytes = $script:Utf8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
