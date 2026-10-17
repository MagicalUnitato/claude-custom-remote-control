#Requires -Version 7.0
# Offline tests for telegram-approve.ps1: fake token, fake chat 111, -NoSend, fake updates file. No network.
$ErrorActionPreference = 'Stop'
$Hooks = (Resolve-Path (Join-Path $PSScriptRoot '..\hooks')).Path
$Hook = Join-Path $Hooks 'telegram-approve.ps1'
$Pwsh = (Get-Command pwsh).Source
$Root = Join-Path ([IO.Path]::GetTempPath()) ('claude-telegram-approve-tests-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$null = New-Item -ItemType Directory -Path $Root -Force
$AllowJson = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
$FakeToken = '123456:FAKE-offline-test-token-not-real'
$Results = [Collections.Generic.List[object]]::new()

function New-Payload([string]$Tool, $ToolInput, [string]$Event = 'PermissionRequest') {
    @{ session_id = 'offline-test-0001'; transcript_path = 'x'; cwd = 'G:\Repositories\claude-custom-remote-control'
       permission_mode = 'default'; hook_event_name = $Event; tool_name = $Tool; tool_input = $ToolInput } | ConvertTo-Json -Compress -Depth 5
}

function Start-Hook([string]$Payload, [string]$Dir, [int]$Window = 20, [string[]]$Extra = @(), [hashtable]$Env = @{}, [switch]$NoConfig) {
    $psi = [Diagnostics.ProcessStartInfo]::new($Pwsh)
    foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Hook, '-NoSend', '-PollSeconds', '1',
            '-WindowSeconds', "$Window", '-StateDir', (Join-Path $Dir 'state'), '-LogDir', (Join-Path $Dir 'logs'),
            '-FakeUpdatesPath', (Join-Path $Dir 'updates.json')) + $Extra) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    if ($NoConfig) { $psi.Environment.Remove('TELEGRAM_BOT_TOKEN'); $psi.Environment.Remove('TELEGRAM_CHAT_ID') }
    else { $psi.Environment['TELEGRAM_BOT_TOKEN'] = $FakeToken; $psi.Environment['TELEGRAM_CHAT_ID'] = '111' }
    foreach ($k in $Env.Keys) { $psi.Environment[$k] = $Env[$k] }
    $p = [Diagnostics.Process]::Start($psi)
    $ms = [IO.MemoryStream]::new()
    $copy = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    $err = $p.StandardError.ReadToEndAsync()
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Payload)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.Close()
    return @{ p = $p; ms = $ms; copy = $copy; err = $err; t0 = Get-Date }
}

function Wait-Hook($h) {
    $h.p.WaitForExit(); $h.copy.Wait()
    return [pscustomobject]@{ stdout = [Text.Encoding]::UTF8.GetString($h.ms.ToArray()); exit = $h.p.ExitCode
        secs = [math]::Round(((Get-Date) - $h.t0).TotalSeconds, 1); stderr = $h.err.Result }
}

function Get-Pending([string]$Dir) {
    try { return @((Get-Content -Raw (Join-Path $Dir 'state\state.json') | ConvertFrom-Json -AsHashtable).pending.Keys) } catch { return @() }
}

function Wait-NewPending([string]$Dir, [string[]]$Known = @()) {
    for ($i = 0; $i -lt 100; $i++) {
        $new = @(Get-Pending $Dir | Where-Object { $_ -notin $Known })
        if ($new.Count) { return $new[0] }
        Start-Sleep -Milliseconds 200
    }
    throw "no new pending request in $Dir"
}

function Add-Updates([string]$Dir, [object[]]$Msgs) {
    $file = Join-Path $Dir 'updates.json'
    $list = [Collections.Generic.List[object]]::new()
    if (Test-Path $file) { foreach ($u in (Get-Content -Raw $file | ConvertFrom-Json -AsHashtable).result) { $list.Add($u) } }
    foreach ($m in $Msgs) {
        $uid = 1000 + $list.Count + 1
        $list.Add(@{ update_id = $uid; message = @{ message_id = $uid; date = ($m.date ?? [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
            from = @{ id = ($m.from ?? 111); is_bot = $false; first_name = 'T' }; chat = @{ id = ($m.chat ?? 111); type = ($m.type ?? 'private') }; text = $m.text } })
    }
    $tmp = "$file.tmp"
    Set-Content -Path $tmp -Value (@{ ok = $true; result = $list } | ConvertTo-Json -Depth 6 -Compress) -NoNewline
    Move-Item -Path $tmp -Destination $file -Force
}

function Add-Result([string]$Name, $R, [bool]$Pass, [string]$Note = '') {
    $Results.Add([pscustomobject]@{ Test = $Name; Pass = $Pass; Exit = $R.exit; Secs = $R.secs; StdoutLen = $R.stdout.Length; Stdout = $R.stdout; Note = $Note })
}

$bash = { param($c) New-Payload 'Bash' @{ command = $c; description = 'Offline test' } }

# --- S1: yes <id> -> exact allow JSON
$d = Join-Path $Root 's1'; $null = New-Item -ItemType Directory $d
$h = Start-Hook (& $bash 'echo tg-test-yes') $d
$id1 = Wait-NewPending $d
Add-Updates $d @(@{ text = "yes $id1" })
$r = Wait-Hook $h
Add-Result 'S1 yes <id>' $r ($r.exit -eq 0 -and $r.stdout -ceq $AllowJson) "id=$id1"

# --- S2: tappable /no_<id> with reason -> deny JSON with message
$h = Start-Hook (& $bash 'echo tg-test-no') $d
$id2 = Wait-NewPending $d
Add-Updates $d @(@{ text = "/no_$id2 use git diff instead" })
$r = Wait-Hook $h
$j = $r.stdout | ConvertFrom-Json
Add-Result 'S2 /no_<id> reason' $r ($r.exit -eq 0 -and $j.hookSpecificOutput.hookEventName -eq 'PermissionRequest' -and
    $j.hookSpecificOutput.decision.behavior -eq 'deny' -and $j.hookSpecificOutput.decision.message -match 'use git diff instead') "id=$id2"

# --- S3: wrong sender, group chat, wrong id, too-old message, stale id -> all ignored; then correct yes -> allow
$h = Start-Hook (& $bash 'echo tg-test-filters') $d
$id3 = Wait-NewPending $d
Add-Updates $d @(
    @{ text = "yes $id3"; from = 999; chat = 999 },                 # another Telegram user, own private chat
    @{ text = "yes $id3"; from = 999; chat = 111 },                 # spoofed chat, wrong sender
    @{ text = "yes $id3"; from = 111; chat = -100123; type = 'group' }, # right user, in a group
    @{ text = 'yes zzzzzz' },                                       # wrong id
    @{ text = "yes $id1" },                                         # stale id (S1, already allowed)
    @{ text = "yes $id3"; date = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 3600) }, # sent before the request
    @{ text = "hello" })                                            # not a reply
Start-Sleep -Seconds 4
$stillRunning = -not $h.p.HasExited
Add-Updates $d @(@{ text = "YES $id3" })
$r = Wait-Hook $h
Add-Result 'S3 bad replies ignored, then yes' $r ($stillRunning -and $r.exit -eq 0 -and $r.stdout -ceq $AllowJson) "id=$id3 stillRunningAfterBadReplies=$stillRunning"

# --- S4: timeout -> no stdout, exit 0
$h = Start-Hook (& $bash 'echo tg-test-timeout') $d -Window 5
$id4 = Wait-NewPending $d
$r = Wait-Hook $h
Add-Result 'S4 timeout (5 s window)' $r ($r.exit -eq 0 -and $r.stdout.Length -eq 0 -and $r.secs -ge 5) "id=$id4"

# --- S5: late reply to the timed-out id is ignored by the next request
$h = Start-Hook (& $bash 'echo tg-test-late') $d -Window 6
$id5 = Wait-NewPending $d
Add-Updates $d @(@{ text = "yes $id4" })
$r = Wait-Hook $h
Add-Result 'S5 late yes to timed-out id' $r ($r.exit -eq 0 -and $r.stdout.Length -eq 0) "late=$id4 current=$id5"

# --- S6: two overlapping requests, answers arrive in one batch in reverse order
$d6 = Join-Path $Root 's6'; $null = New-Item -ItemType Directory $d6
$hA = Start-Hook (& $bash 'echo tg-test-A') $d6 -Window 30
$idA = Wait-NewPending $d6
$hB = Start-Hook (& $bash 'echo tg-test-B') $d6 -Window 30
$idB = Wait-NewPending $d6 @($idA)
Add-Updates $d6 @(@{ text = "no $idB" }, @{ text = "yes $idA" })
$rA = Wait-Hook $hA; $rB = Wait-Hook $hB
Add-Result 'S6 overlap: A' $rA ($rA.exit -eq 0 -and $rA.stdout -ceq $AllowJson) "A=$idA"
Add-Result 'S6 overlap: B' $rB ($rB.exit -eq 0 -and ($rB.stdout | ConvertFrom-Json).hookSpecificOutput.decision.behavior -eq 'deny') "B=$idB"

# --- S7: three overlapping, answered one at a time
$d7 = Join-Path $Root 's7'; $null = New-Item -ItemType Directory $d7
$hs = @(); $ids = @()
foreach ($n in 1..3) { $hs += , (Start-Hook (& $bash "echo tg-test-C$n") $d7 -Window 30); $ids += Wait-NewPending $d7 $ids }
Add-Updates $d7 @(@{ text = "yes $($ids[2])" }); Start-Sleep -Milliseconds 1500
Add-Updates $d7 @(@{ text = "no $($ids[0])" }); Start-Sleep -Milliseconds 1500
Add-Updates $d7 @(@{ text = "yes $($ids[1])" })
$rs = $hs | ForEach-Object { Wait-Hook $_ }
$ok = $rs[0].stdout -match '"deny"' -and $rs[1].stdout -ceq $AllowJson -and $rs[2].stdout -ceq $AllowJson
Add-Result 'S7 three overlapping' $rs[0] $ok ("ids=" + ($ids -join ',') + " out=" + (($rs | ForEach-Object { if ($_.stdout -match 'deny') { 'deny' } elseif ($_.stdout) { 'allow' } else { 'none' } }) -join ','))

# --- S8: not configured -> no stdout, exit 0, immediate
$d8 = Join-Path $Root 's8'; $null = New-Item -ItemType Directory $d8
# The hooks fall back to the User environment, so this case can only run where the real variables aren't set.
if ([Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN', 'User') -or [Environment]::GetEnvironmentVariable('TELEGRAM_CHAT_ID', 'User')) {
    $Results.Add([pscustomobject]@{ Test = 'S8 no token/chat id'; Pass = $true; Exit = '-'; Secs = 0; StdoutLen = 0; Stdout = ''; Note = 'SKIPPED: real TELEGRAM_* variables are set in the User environment' })
} else {
    $r = Wait-Hook (Start-Hook (& $bash 'echo tg-test-noconfig') $d8 -NoConfig)
    Add-Result 'S8 no token/chat id' $r ($r.exit -eq 0 -and $r.stdout.Length -eq 0 -and $r.secs -lt 5)
}

# --- S9: garbage stdin -> no stdout, exit 0
$r = Wait-Hook (Start-Hook 'this is not json {' $d8)
Add-Result 'S9 garbage stdin' $r ($r.exit -eq 0 -and $r.stdout.Length -eq 0)

# --- S10: wrong event name -> no stdout, exit 0
$r = Wait-Hook (Start-Hook (New-Payload 'Bash' @{ command = 'echo x' } 'PreToolUse') $d8)
Add-Result 'S10 other event' $r ($r.exit -eq 0 -and $r.stdout.Length -eq 0)

# --- Redaction previews (stdout carries the would-be Telegram text only in -PreviewMessage mode)
$d9 = Join-Path $Root 's9'; $null = New-Item -ItemType Directory $d9
$secretCmd = 'curl -H "Authorization: Bearer abcDEF1234567890ghiJKL" "https://user:hunter2pass@example.com/api?token=sekrit123&x=1" && ' +
    'export OPENAI_API_KEY=sk-proj-AbCdEf1234567890XyZ && git push https://ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@github.com/x/y && ' +
    'mysql --password=Pa55word! -e 1 && echo 0123456789abcdef0123456789abcdef && echo zz-unique-env-value-77'
$r = Wait-Hook (Start-Hook (& $bash $secretCmd) $d9 -Extra @('-PreviewMessage') -Env @{ FAKE_SERVICE_TOKEN = 'zz-unique-env-value-77' })
$leaks = @('abcDEF1234567890ghiJKL', 'hunter2pass', 'sekrit123', 'AbCdEf1234567890XyZ', 'ghp_ABCDEFGHIJ', 'Pa55word!', '0123456789abcdef0123', 'zz-unique-env-value-77', $FakeToken, '111') |
    Where-Object { $r.stdout.Contains($_) }
Add-Result 'R1 Bash secrets redacted' $r ($leaks.Count -eq 0) ("leaks=" + ($leaks -join ','))

$r = Wait-Hook (Start-Hook (& $bash ('echo ' + ('word ' * 120))) $d9 -Extra @('-PreviewMessage'))
$cmdLine = ($r.stdout -split "`n" | Where-Object { $_.StartsWith('$ ') })
Add-Result 'R2 long command truncated' $r ($cmdLine.Length -le 306 -and $cmdLine.EndsWith('...')) "cmdLineLen=$($cmdLine.Length)"

$r = Wait-Hook (Start-Hook (New-Payload 'Write' @{ file_path = 'C:\proj\.env'; content = ('SECRET_CONTENT_SHOULD_NOT_APPEAR=1' * 10) }) $d9 -Extra @('-PreviewMessage'))
Add-Result 'R3 Write: path+size only' $r (-not $r.stdout.Contains('SECRET_CONTENT') -and $r.stdout -match 'Size: 340 chars')

$r = Wait-Hook (Start-Hook (New-Payload 'Edit' @{ file_path = 'C:\proj\app.config'; old_string = 'pw=old-secret'; new_string = 'pw=new-secret-value' }) $d9 -Extra @('-PreviewMessage'))
Add-Result 'R4 Edit: path+sizes only' $r (-not $r.stdout.Contains('secret') -and $r.stdout -match 'replace 13 chars with 19 chars')

# --- S11/S12: answered at the PC (transcript watch)
$d11 = Join-Path $Root 's11'; $null = New-Item -ItemType Directory $d11
$tx = Join-Path $d11 'transcript.jsonl'
function Add-Tx([string]$Line) { Add-Content -Path $tx -Value $Line -Encoding utf8NoBOM }
function TxUse([string]$Tid, [string]$Cmd) { @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = $Tid; name = 'Bash'; input = @{ command = $Cmd; description = 'x' } }) } } | ConvertTo-Json -Compress -Depth 8 }
function TxResult([string]$Tid) { @{ type = 'user'; message = @{ role = 'user'; content = @(@{ tool_use_id = $Tid; type = 'tool_result'; content = 'ok' }) } } | ConvertTo-Json -Compress -Depth 8 }
function New-TxPayload([string]$Cmd) {
    @{ session_id = 'offline-test-0001'; transcript_path = $tx; cwd = 'G:\Repositories\claude-custom-remote-control'; permission_mode = 'default'
       hook_event_name = 'PermissionRequest'; tool_name = 'Bash'; tool_input = @{ command = $Cmd; description = 'x' } } | ConvertTo-Json -Compress -Depth 5
}
Add-Tx (TxUse 'toolu_PC' 'echo tg-test-pc')
$h = Start-Hook (New-TxPayload 'echo tg-test-pc') $d11 -Window 30
$id11 = Wait-NewPending $d11
Start-Sleep -Seconds 3
Add-Tx (TxResult 'toolu_PC')       # the local dialog answered
$r = Wait-Hook $h
Add-Result 'S11 answered at PC -> stop' $r ($r.exit -eq 0 -and $r.stdout.Length -eq 0 -and $r.secs -lt 10) "id=$id11"

# S12: an older identical command with a result must not stop the wait; late tap on S11 gets 'already answered'
Add-Tx (TxUse 'toolu_OLD' 'echo tg-test-dup'); Add-Tx (TxResult 'toolu_OLD')
$h = Start-Hook (New-TxPayload 'echo tg-test-dup') $d11 -Window 30
$id12 = Wait-NewPending $d11 @($id11)
Start-Sleep -Seconds 3
Add-Tx (TxUse 'toolu_NEW' 'echo tg-test-dup')
Start-Sleep -Seconds 3
$alive = -not $h.p.HasExited
Add-Updates $d11 @(@{ text = "yes $id11" }, @{ text = "yes $id12" })
$r = Wait-Hook $h
Add-Result 'S12 old identical cmd ignored; yes' $r ($alive -and $r.exit -eq 0 -and $r.stdout -ceq $AllowJson) "id=$id12 aliveBeforeReply=$alive"

# --- Report
$Results | Format-Table Test, Pass, Exit, Secs, StdoutLen, Note -AutoSize -Wrap | Out-String -Width 220
'--- exact stdout of S1/S2:'
$Results[0].Stdout; ''
$Results[1].Stdout; ''
'--- R1 preview text:'
$Results | Where-Object Test -like 'R1*' | ForEach-Object Stdout
''
'--- R3 preview text:'
$Results | Where-Object Test -like 'R3*' | ForEach-Object Stdout
''
'--- S1-S5 log (shared state dir s1):'
Get-Content (Get-ChildItem (Join-Path $Root 's1\logs') -File | Select-Object -First 1).FullName
'--- S6 log:'
Get-Content (Get-ChildItem (Join-Path $Root 's6\logs') -File | Select-Object -First 1).FullName
'--- S11/S12 log:'
Get-Content (Get-ChildItem (Join-Path $Root 's11\logs') -File | Select-Object -First 1).FullName
'--- leftover pending after all runs: s1=' + (Get-Pending (Join-Path $Root 's1')).Count + ' s6=' + (Get-Pending $d6).Count + ' s7=' + (Get-Pending $d7).Count
'--- fake token in any log/state file: ' + @(Get-ChildItem $Root -Recurse -File | Select-String -SimpleMatch $FakeToken).Count
"ALL PASS: $(-not ($Results | Where-Object { -not $_.Pass }))"
