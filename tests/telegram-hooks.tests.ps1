#Requires -Version 7.0
# Offline tests for telegram-approve.ps1 and telegram-turn.ps1 working together: fake token, fake updates, -NoSend. No network.
$ErrorActionPreference = 'Stop'
$Hooks = (Resolve-Path (Join-Path $PSScriptRoot '..\hooks')).Path
$Root = Join-Path ([IO.Path]::GetTempPath()) ("claude-telegram-tests-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$State = Join-Path $Root 'state'; $Logs = Join-Path $Root 'logs'; $Fake = Join-Path $Root 'updates.json'
$null = New-Item -ItemType Directory -Force $Root, $State, $Logs
$FakeToken = '123456789:FAKEtokenFAKEtokenFAKEtokenFAKE0000'
$Chat = '999000111'
$env:TELEGRAM_BOT_TOKEN = $FakeToken
$env:TELEGRAM_CHAT_ID = $Chat
$env:TELEGRAM_TURN_ALERTS = ''
$Pwsh = (Get-Command pwsh).Source
$script:Fail = 0
$script:UpdateId = 1000

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "PASS $Name" } else { $script:Fail++; Write-Host "FAIL $Name :: $Detail" }
}

function Start-Hook([string]$Script, [string]$Payload, [string[]]$Extra = @()) {
    $psi = [Diagnostics.ProcessStartInfo]::new($Pwsh)
    foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $(if ([IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $Hooks $Script }),
            '-StateDir', $State, '-LogDir', $Logs, '-FakeUpdatesPath', $Fake, '-NoSend', '-PollSeconds', '1') + $Extra) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($Payload); $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    return @{ p = $p; out = $o; err = $e }
}

function Wait-Hook($H, [int]$Sec = 30) {
    if (-not $H.p.WaitForExit($Sec * 1000)) { $H.p.Kill(); return @{ code = 'killed'; out = ''; err = '' } }
    return @{ code = $H.p.ExitCode; out = $H.out.Result; err = $H.err.Result }
}

function Get-State { Get-Content -Raw (Join-Path $State 'state.json') | ConvertFrom-Json -AsHashtable }

function Wait-Pending([string]$Kind, [string[]]$Not = @()) {
    for ($i = 0; $i -lt 100; $i++) {
        try { $st = Get-State; foreach ($k in $st.pending.Keys) { if (($st.pending[$k].kind ?? 'approve') -eq $Kind -and $k -notin $Not) { return $k } } } catch { }
        Start-Sleep -Milliseconds 200
    }
    throw "no pending $Kind"
}

function Set-Updates([object[]]$Msgs) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $res = foreach ($m in $Msgs) {
        $script:UpdateId++
        $msg = [ordered]@{ message_id = $script:UpdateId; from = @{ id = [long]$Chat }; chat = @{ id = [long]($m.chat ?? $Chat); type = 'private' }; date = $now; text = $m.text }
        if ($m.reply_to) { $msg.reply_to_message = @{ message_id = $m.reply_to } }
        @{ update_id = $script:UpdateId; message = $msg }
    }
    @{ ok = $true; result = @($res) } | ConvertTo-Json -Depth 6 | Set-Content -Path $Fake -Encoding utf8
}

function New-Transcript([string]$Name, [hashtable]$Box) {
    $path = Join-Path $Root "$Name.jsonl"
    $ts = [DateTimeOffset]::UtcNow.ToString('o')
    $lines = @(
        (@{ type = 'user'; promptId = 'p1'; message = @{ role = 'user'; content = 'do the thing' }; timestamp = $ts } | ConvertTo-Json -Compress -Depth 8)
        (@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = 'working' }) }; timestamp = $ts } | ConvertTo-Json -Compress -Depth 8)
    )
    if ($Box) {
        $lines += (@{ type = 'assistant'; timestamp = $ts; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = 'toolu_x'; name = 'mcp__ccd_turn__wrap_up'; input = $Box }) } } | ConvertTo-Json -Compress -Depth 8)
        $lines += (@{ type = 'user'; promptId = 'p1'; timestamp = $ts; message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'toolu_x'; content = 'ok' }) } } | ConvertTo-Json -Compress -Depth 8)
    }
    [IO.File]::WriteAllText($path, ($lines -join "`n") + "`n")
    return $path
}

function Stop-Payload([string]$Transcript, [string]$Sess = 'sess-aaaa-1111') {
    @{ session_id = $Sess; transcript_path = $Transcript; cwd = 'G:\Repositories\demo-proj'; permission_mode = 'default'; hook_event_name = 'Stop'; stop_hook_active = $false; last_assistant_message = 'closing text' } | ConvertTo-Json -Compress
}

$BashPayload = @{ session_id = 'sess-bbbb-2222'; transcript_path = ''; cwd = 'G:\Repositories\demo-proj'; permission_mode = 'default'; hook_event_name = 'PermissionRequest'; tool_name = 'Bash'; tool_input = @{ command = 'git push origin main --token=abc12345678'; description = 'Push it' } } | ConvertTo-Json -Compress
$Box = @{ recap = 'I fixed the CI config. Not merged yet. token=supersecretvalue123'; ask = 'Tell me when #119 CI is green so I can merge?'; actions = @(@{ label = 'Merge now'; message = 'CI is green, merge it.' }, @{ label = 'Wait'; message = 'Hold off for now.' }, @{ action = 'commit' }) }

Set-Updates @()

# 1. Approve preview: tool, command (redacted) and the tappable answers.
$new = Wait-Hook (Start-Hook 'telegram-approve.ps1' $BashPayload @('-PreviewMessage'))
Check 'approve preview: command, redaction, buttons' ($new.out -match 'wants to use Bash' -and $new.out -match 'git push origin main' -and $new.out -notmatch 'abc12345678' -and $new.out -match '/yes_abc234' -and $new.out -match '/no_abc234') "out=[$($new.out)] err=$($new.err)"

# 2. Approve: yes -> allow JSON.
$h = Start-Hook 'telegram-approve.ps1' $BashPayload
$id = Wait-Pending 'approve'
Set-Updates @(@{ text = "/yes_$id" })
$r = Wait-Hook $h
Check 'approve yes -> allow' ($r.code -eq 0 -and $r.out -eq '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}') "code=$($r.code) out=$($r.out) err=$($r.err)"

# 3. Approve: no with reason -> deny JSON.
$h = Start-Hook 'telegram-approve.ps1' $BashPayload
$id = Wait-Pending 'approve'
Set-Updates @(@{ text = "no $id not now" })
$r = Wait-Hook $h
Check 'approve no -> deny' ($r.out -match '"behavior":"deny"' -and $r.out -match 'Reason: not now') "out=$($r.out) err=$($r.err)"

# 4. Turn preview.
$t = New-Transcript 'turn-preview' $Box
$r = Wait-Hook (Start-Hook 'telegram-turn.ps1' (Stop-Payload $t) @('-PreviewMessage'))
Write-Host "---- preview ----`n$($r.out)`n-----------------"
Check 'turn preview has ask, buttons, redaction' ($r.out -match 'CI is green so I can merge' -and $r.out -match '/re_abc234_1  Merge now' -and $r.out -match '/re_abc234_3  commit' -and $r.out -notmatch 'supersecretvalue') "out=$($r.out) err=$($r.err)"

# 5. Turn: no box question -> no alert, exit 0.
$t2 = New-Transcript 'turn-noask' @{ recap = 'Done, nothing pending.' }
$r = Wait-Hook (Start-Hook 'telegram-turn.ps1' (Stop-Payload $t2))
Check 'turn without ask is silent' ($r.code -eq 0 -and -not $r.out -and -not $r.err) "code=$($r.code) out=$($r.out) err=$($r.err)"

# 6. Turn: no wrap_up at all -> silent.
$t3 = New-Transcript 'turn-nobox' $null
$r = Wait-Hook (Start-Hook 'telegram-turn.ps1' (Stop-Payload $t3))
Check 'turn without box is silent' ($r.code -eq 0 -and -not $r.err) "code=$($r.code) err=$($r.err)"

# 7. Turn: tapped button -> exit 2, stderr has the button message.
$t = New-Transcript 'turn-button' $Box
$h = Start-Hook 'telegram-turn.ps1' (Stop-Payload $t)
$id = Wait-Pending 'turn'
Set-Updates @(@{ text = "/re_$($id)_1" })
$r = Wait-Hook $h
Check 'turn button -> exit 2 + message' ($r.code -eq 2 -and $r.err -match 'Merge now' -and $r.err -match 'CI is green, merge it\.' -and -not $r.out) "code=$($r.code) out=$($r.out) err=$($r.err)"

# 7b. Turn: a box with a single button (PowerShell must not unroll it into a bare hashtable).
$t1 = New-Transcript 'turn-one-button' @{ ask = 'Merge #119?'; actions = @(@{ label = 'Merge now'; message = 'Yes, merge it.' }) }
$r = Wait-Hook (Start-Hook 'telegram-turn.ps1' (Stop-Payload $t1 'sess-one-preview') @('-PreviewMessage'))
Check 'one-button preview lists it once' ($r.out -match '/re_abc234_1  Merge now' -and $r.out -notmatch '/re_abc234_2') "out=$($r.out)"
$h = Start-Hook 'telegram-turn.ps1' (Stop-Payload $t1 'sess-one')
$id = Wait-Pending 'turn'
Set-Updates @(@{ text = "/re_$($id)_1" })
$r = Wait-Hook $h
Check 'one-button tap -> exit 2 + its message' ($r.code -eq 2 -and $r.err -match 'Merge now' -and $r.err -match 'Yes, merge it\.') "code=$($r.code) err=$($r.err)"

# 8. Turn: typed reply.
$h = Start-Hook 'telegram-turn.ps1' (Stop-Payload $t 'sess-typed')
$id = Wait-Pending 'turn'
Set-Updates @(@{ text = "re $id please rebase first, then ping me" })
$r = Wait-Hook $h
Check 'turn typed -> exit 2 + text' ($r.code -eq 2 -and $r.err -match 'please rebase first, then ping me') "code=$($r.code) err=$($r.err)"

# 9. Turn: swipe-reply to the alert message.
$h = Start-Hook 'telegram-turn.ps1' (Stop-Payload $t 'sess-swipe')
$id = Wait-Pending 'turn'
$m = [Threading.Mutex]::new($false, 'Local\ClaudeTelegramApprove-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($State.ToLowerInvariant()))).Substring(0, 12))
$null = $m.WaitOne(); $st = Get-State; $st.pending[$id].msg_id = 777; [IO.File]::WriteAllText((Join-Path $State 'state.json'), ($st | ConvertTo-Json -Depth 6 -Compress)); $m.ReleaseMutex()
Set-Updates @(@{ text = 'swiped answer here'; reply_to = 777 })
$r = Wait-Hook $h
Check 'turn swipe-reply -> exit 2' ($r.code -eq 2 -and $r.err -match 'swiped answer here') "code=$($r.code) err=$($r.err)"

# 10. Shared polling: approve and turn wait together; one batch answers both, wrong-format reply gets a hint.
$ha = Start-Hook 'telegram-approve.ps1' $BashPayload
$ht = Start-Hook 'telegram-turn.ps1' (Stop-Payload $t 'sess-shared')
$ida = Wait-Pending 'approve'; $idt = Wait-Pending 'turn'
Set-Updates @(@{ text = "yes $idt" }, @{ text = "re $idt from phone" }, @{ text = "yes $ida" }, @{ text = "re $idt chat from a stranger"; chat = '1' })
$ra = Wait-Hook $ha; $rt = Wait-Hook $ht
Check 'shared: approve got its yes' ($ra.out -match '"behavior":"allow"') "out=$($ra.out)"
Check 'shared: turn got its re' ($rt.code -eq 2 -and $rt.err -match 'from phone' -and $rt.err -notmatch 'stranger') "code=$($rt.code) err=$($rt.err)"

# 11. Supersede: a newer turn of the same session ends the older wait silently.
$h1 = Start-Hook 'telegram-turn.ps1' (Stop-Payload $t 'sess-same')
$id1 = Wait-Pending 'turn'
$h2 = Start-Hook 'telegram-turn.ps1' (Stop-Payload $t 'sess-same')
$id2 = Wait-Pending 'turn' @($id1)
$r1 = Wait-Hook $h1
Check 'supersede: old wait exits 0 silently' ($r1.code -eq 0 -and -not $r1.err) "code=$($r1.code) err=$($r1.err)"
Set-Updates @(@{ text = "re $id1 late" }, @{ text = "re $id2 newest" })
$r2 = Wait-Hook $h2
Check 'supersede: new wait gets its reply' ($r2.code -eq 2 -and $r2.err -match 'newest') "code=$($r2.code) err=$($r2.err)"

# 12. Moved on at the PC: a new prompt in the transcript ends the wait silently.
$t4 = New-Transcript 'turn-pc' $Box
$h = Start-Hook 'telegram-turn.ps1' (Stop-Payload $t4 'sess-pc')
$id = Wait-Pending 'turn'
Start-Sleep -Seconds 1
Add-Content -Path $t4 -Value (@{ type = 'user'; promptId = 'p2'; message = @{ role = 'user'; content = 'typed at pc' } } | ConvertTo-Json -Compress)
$r = Wait-Hook $h
Check 'moved on at PC -> exit 0' ($r.code -eq 0 -and -not $r.err) "code=$($r.code) err=$($r.err)"
Check 'moved on recorded' ((Get-State).done[$id].result -eq 'answered at the PC') "done=$((Get-State).done[$id] | ConvertTo-Json -Compress)"

# 13. Timeout.
$h = Start-Hook 'telegram-turn.ps1' (Stop-Payload $t 'sess-timeout') @('-WindowSeconds', '3')
$r = Wait-Hook $h
Check 'timeout -> exit 0 silent' ($r.code -eq 0 -and -not $r.err) "code=$($r.code) err=$($r.err)"

# 14. TELEGRAM_TURN_ALERTS=off and =all.
$env:TELEGRAM_TURN_ALERTS = 'off'
$r = Wait-Hook (Start-Hook 'telegram-turn.ps1' (Stop-Payload $t) @('-PreviewMessage'))
Check 'alerts off -> nothing' (-not $r.out -and $r.code -eq 0) "out=$($r.out)"
$env:TELEGRAM_TURN_ALERTS = 'all'
$r = Wait-Hook (Start-Hook 'telegram-turn.ps1' (Stop-Payload $t2) @('-PreviewMessage'))
Check 'alerts all -> recap-only turn alerts' ($r.out -match 'finished a turn' -and $r.out -match 'Done, nothing pending') "out=$($r.out)"
$env:TELEGRAM_TURN_ALERTS = ''

# 15. Secrets never land in state or logs.
$blob = (Get-ChildItem $Logs, $State -File | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
Check 'no token/chat id in logs+state' ($blob -notmatch [regex]::Escape($FakeToken) -and $blob -notmatch $Chat) ''
Check 'wrong-format hint logged' ($blob -match 'reason=wrong-format') ''

Write-Host "`nlogs: $Logs"
Write-Host $(if ($script:Fail) { "$($script:Fail) FAILED" } else { 'ALL PASSED' })
