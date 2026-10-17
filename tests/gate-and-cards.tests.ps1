#Requires -Version 7.0
# Offline tests: push-merge-gate.ps1 patterns, and card alerts in telegram-turn.ps1 (-PreviewMessage). No network.
$ErrorActionPreference = 'Stop'
$Hooks = (Resolve-Path (Join-Path $PSScriptRoot '..\hooks')).Path
$Pwsh = (Get-Command pwsh).Source
$Gate = Join-Path $Hooks 'push-merge-gate.ps1'
$Turn = Join-Path $Hooks 'telegram-turn.ps1'
$Root = Join-Path ([IO.Path]::GetTempPath()) ('claude-gate-tests-' + (Get-Date -Format 'yyyyMMdd-HHmmss')); $null = New-Item -ItemType Directory $Root
$Fails = 0

function Invoke-Hook([string]$Script, [string]$Payload, [string[]]$Extra = @()) {
    $psi = [Diagnostics.ProcessStartInfo]::new($Pwsh)
    foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Extra) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.Environment['TELEGRAM_TURN_ALERTS'] = 'ask'
    $p = [Diagnostics.Process]::Start($psi)
    $ms = [IO.MemoryStream]::new(); $copy = $p.StandardOutput.BaseStream.CopyToAsync($ms); $null = $p.StandardError.ReadToEndAsync()
    $b = [Text.UTF8Encoding]::new($false).GetBytes($Payload); $p.StandardInput.BaseStream.Write($b, 0, $b.Length); $p.StandardInput.Close()
    $p.WaitForExit(); $copy.Wait()
    [pscustomobject]@{ out = [Text.Encoding]::UTF8.GetString($ms.ToArray()); exit = $p.ExitCode }
}

# --- Gate patterns: $true = must ask, $false = must stay silent
$cases = [ordered]@{
    'git push'                                             = $true
    'git push origin main'                                 = $true
    'git push --force-with-lease origin HEAD'              = $true
    'git -C . push origin main'                            = $true
    'git -C "C:/some dir/repo" push'                       = $true
    'git -c push.default=current push origin main'         = $true
    'git --git-dir=C:/r/.git push origin main'             = $true
    'git --git-dir C:/r/.git --work-tree C:/r push'        = $true
    'git --no-pager push'                                  = $true
    '"C:\Program Files\Git\cmd\git.exe" push origin main'  = $true
    'cd repo && git add . && git commit -m x && git push'  = $true
    'git submodule foreach git push'                       = $true
    'gh pr merge 119 --squash --delete-branch'             = $true
    'gh pr merge feat/x --repo example-org/example-repo --squash'       = $true
    'gh -R example-org/example-repo pr merge 119 --squash'              = $true
    'gh api -X PUT repos/example-org/example-repo/pulls/119/merge'      = $true
    'GIT PUSH upstream dev'                                = $true
    'git status'                                           = $false
    'git log --grep push'                                  = $false
    'git stash push -m wip'                                = $false
    'git commit -m "push the fix"'                         = $false
    'git push-notes'                                       = $false
    'git pull'                                             = $false
    'gh pr view 119'                                       = $false
    'gh pr checks 119'                                     = $false
    'gh api repos/example-org/example-repo/pulls/119'                   = $false
    'npm run merge-reports'                                = $false
    'echo pushing'                                         = $false
}
$expectJson = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"git push needs your OK (PC or Telegram)."}}'
$rows = foreach ($cmd in $cases.Keys) {
    foreach ($tool in 'Bash', 'PowerShell') {
        $payload = @{ session_id = 'gate-test-0001'; hook_event_name = 'PreToolUse'; permission_mode = 'bypassPermissions'; tool_name = $tool; tool_input = @{ command = $cmd } } | ConvertTo-Json -Compress
        $r = Invoke-Hook $Gate $payload @('-LogDir', (Join-Path $Root 'logs'))
        $asked = $r.out -match '"permissionDecision":"ask"'
        $ok = ($asked -eq $cases[$cmd]) -and $r.exit -eq 0 -and ($r.out.Length -eq 0 -or ($r.out | ConvertFrom-Json))
        if (-not $ok) { $script:Fails++ }
        [pscustomobject]@{ Tool = $tool; Command = $cmd; Want = $(if ($cases[$cmd]) { 'ask' } else { 'silent' }); Got = $(if ($asked) { 'ask' } else { 'silent' }); Exit = $r.exit; Pass = $ok }
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 220
$sample = Invoke-Hook $Gate (@{ session_id = 's'; tool_name = 'Bash'; tool_input = @{ command = 'git push' } } | ConvertTo-Json -Compress) @('-LogDir', (Join-Path $Root 'logs'))
"exact push JSON: $($sample.out -ceq $expectJson)"; if ($sample.out -cne $expectJson) { $Fails++ }
'gate log (no command text):'; Get-Content (Get-ChildItem (Join-Path $Root 'logs') -File)[0].FullName -TotalCount 3

# --- Card alerts via -PreviewMessage against a fake transcript
$tx = Join-Path $Root 'transcript.jsonl'
function Line($o) { $o | ConvertTo-Json -Compress -Depth 10 }
$now = [DateTimeOffset]::UtcNow.ToString('o')
$prompt = Line @{ type = 'user'; promptId = 'p1'; timestamp = $now; message = @{ role = 'user'; content = 'do the thing' } }
$card = { param($t, $init) Line @{ type = 'assistant'; timestamp = $now; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = "toolu_$(Get-Random)"; name = 'mcp__ccd_session__start_session'; input = @{ initiation = $init; title = $t; prompt = 'secret ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 brief' } }) } } }
$box = { param($ask) $in = [ordered]@{ recap = 'Did the work.' }; if ($ask) { $in.ask = $ask; $in.actions = @([ordered]@{ label = 'Yes' }) }; Line @{ type = 'assistant'; timestamp = $now; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = 'toolu_box'; name = 'mcp__ccd_turn__wrap_up'; input = $in }) } } }
$old = & $card 'Old card from an earlier turn' 'own_initiative'
$stopPayload = { @{ session_id = 'card-test-0001'; hook_event_name = 'Stop'; permission_mode = 'bypassPermissions'; cwd = 'G:\Repositories\x'; transcript_path = $tx; last_assistant_message = '' } | ConvertTo-Json -Compress }
$turnArgs = @('-PreviewMessage', '-NoSend', '-StateDir', (Join-Path $Root 'state'), '-LogDir', (Join-Path $Root 'logs'))

# C1: card, no question -> alert with the card, not the older one
Set-Content $tx -Value @($old, $prompt, (& $card 'Log the rewrite''s real job ID' 'own_initiative'), (& $box $null)) -Encoding utf8NoBOM
$r = Invoke-Hook $Turn (& $stopPayload) $turnArgs
$c1 = $r.out -match 'proposed a new session' -and $r.out -match 'real job ID' -and $r.out -notmatch 'Old card' -and $r.out -notmatch 'ghp_' -and $r.exit -eq 0
"C1 card without question -> alert: $c1"; if (-not $c1) { $Fails++ }; $r.out; ''

# C2: question + two cards -> question header, both cards listed
Set-Content $tx -Value @($prompt, (& $card 'First card' 'own_initiative'), (& $card 'Second card' 'own_initiative'), (& $box 'Merge #119?')) -Encoding utf8NoBOM
$r = Invoke-Hook $Turn (& $stopPayload) $turnArgs
$c2 = $r.out -match 'waiting on you' -and $r.out -match 'First card' -and $r.out -match 'Second card' -and $r.out -match 'cards waiting' -and $r.out -match '/re_abc234_1  Yes'
"C2 question + 2 cards: $c2"; if (-not $c2) { $Fails++ }; $r.out; ''

# C3: no question, no card -> nothing (default 'ask'); 'offer' and 'user_asked' starts don't count as cards
Set-Content $tx -Value @($old, $prompt, (& $card 'Offered' 'offer'), (& $card 'Started' 'user_asked'), (& $box $null)) -Encoding utf8NoBOM
$r = Invoke-Hook $Turn (& $stopPayload) $turnArgs
$c3 = $r.out.Length -eq 0 -and $r.exit -eq 0
"C3 no question/no own_initiative card -> silent: $c3"; if (-not $c3) { $Fails++ }

"TOTAL FAILS: $Fails"
