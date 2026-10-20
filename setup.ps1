#Requires -Version 7.0
<#
.SYNOPSIS
  Interactive setup for the Telegram remote-control hooks for Claude Code.

.DESCRIPTION
  Walks you through everything the hooks need:
    1. checks (Windows, PowerShell 7, Claude settings, policies that block hooks);
    2. your Telegram bot token, checked with Telegram and stored as a User environment variable;
    3. your chat ID, found from a code you send to the bot;
    4. copying the hooks to ~/.claude/hooks;
    5. merging ~/.claude/settings.json (backed up first; your other settings are kept);
    6. the ~/.claude/CLAUDE.md note for pushes and merges;
    7. a live test on your phone.

  Safe to re-run: it replaces its own entries and leaves everything else in settings.json alone. The token
  and chat ID are never written to a file or printed.

.EXAMPLE
  .\setup.cmd
  Runs the whole setup interactively.

.EXAMPLE
  pwsh -File setup.ps1 -Features approve,turn
  Installs only phone approvals and end-of-turn alerts (no push/merge gate).

.EXAMPLE
  pwsh -File setup.ps1 -DryRun
  Shows what would change in settings.json, without writing anything.

.EXAMPLE
  pwsh -File setup.ps1 -Uninstall
  Removes this tool's entries from settings.json and CLAUDE.md (backed up first).
#>
[CmdletBinding()]
param(
    # approve = phone approval of permission prompts; turn = end-of-turn questions and replies;
    # gate = always ask before git push / PR merges. Default: all three (asked one by one unless -Yes).
    [ValidateSet('approve', 'turn', 'gate')]
    [string[]]$Features,
    # Remove this tool's settings entries and CLAUDE.md note.
    [switch]$Uninstall,
    # Accept every default without asking. Needs the Telegram variables already set unless -SkipTelegram.
    [switch]$Yes,
    # Show what would change in settings.json; write nothing.
    [switch]$DryRun,
    # Leave the bot token and chat ID alone (for a re-install or for tests).
    [switch]$SkipTelegram,
    # Don't send test messages at the end.
    [switch]$SkipLiveTest,
    # Claude Code's user folder. Change only for testing.
    [string]$ClaudeDir = (Join-Path $HOME '.claude')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# IPv6 to api.telegram.org can hang for 10+ s on some networks; IPv4 is reliable.
[AppContext]::SetSwitch('System.Net.DisableIPv6', $true)

$RepoRoot = $PSScriptRoot
$HookScripts = 'telegram-common.ps1', 'telegram-approve.ps1', 'telegram-turn.ps1', 'push-merge-gate.ps1'
$OurScriptPattern = 'telegram-approve\.ps1|telegram-turn\.ps1|push-merge-gate\.ps1'
$MarkerStart = '<!-- claude-telegram-remote-control:start -->'
$MarkerEnd = '<!-- claude-telegram-remote-control:end -->'
$LegacyHeading = '# Pushes and merges go through a permission prompt'
$Utf8 = [Text.UTF8Encoding]::new($false)
$HooksDir = Join-Path $ClaudeDir 'hooks'
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$ClaudeMdPath = Join-Path $ClaudeDir 'CLAUDE.md'
$script:Token = $null
$script:ChatId = $null
$script:BotName = $null

# ---------------------------------------------------------------- output and prompts

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [ok] $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "  $Text" }
function Write-Warn([string]$Text) { Write-Host "  [!] $Text" -ForegroundColor Yellow }
function Stop-Setup([string]$Text) { Write-Host ''; Write-Host "  [x] $Text" -ForegroundColor Red; exit 1 }

function Read-YesNo([string]$Question, [bool]$Default = $true) {
    if ($Yes) { return $Default }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = (Read-Host "  $Question $hint").Trim().ToLowerInvariant()
        if (-not $a) { return $Default }
        if ($a -in 'y', 'yes') { return $true }
        if ($a -in 'n', 'no') { return $false }
    }
}

# ---------------------------------------------------------------- Telegram

function Invoke-Tg([string]$Token, [string]$Method, [hashtable]$Body = @{}, [int]$TimeoutSec = 15) {
    $json = $Body | ConvertTo-Json -Compress -Depth 5
    try {
        $r = Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$Token/$Method" -ContentType 'application/json; charset=utf-8' `
            -Body $Utf8.GetBytes($json) -TimeoutSec $TimeoutSec -SkipHttpErrorCheck -StatusCodeVariable status
    } catch {
        throw ("Telegram $Method failed: " + "$($_.Exception.Message)".Replace($Token, '<token>'))
    }
    if (-not $r.ok) {
        $desc = "$($r.description)".Replace($Token, '<token>')
        throw [InvalidOperationException]::new("Telegram $Method returned $status`: $desc")
    }
    return $r.result
}

function Test-BotToken([string]$Token) {
    if ($Token -notmatch '^\d+:[A-Za-z0-9_-]{30,}$') { return $null }
    try { return Invoke-Tg $Token 'getMe' } catch { Write-Warn $_.Exception.Message; return $null }
}

function Set-UserVar([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Initialize-BotToken {
    $existing = [Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN', 'User')
    if ($existing) {
        $me = Test-BotToken $existing
        if ($me -and (Read-YesNo "A bot token is already set, for @$($me.username). Keep using it?" $true)) {
            $script:Token = $existing; $script:BotName = $me.username
            Write-Ok "Using @$($me.username)."
            return
        }
        if (-not $me) { Write-Warn 'The bot token that is already set doesn''t work. Enter a new one.' }
    }
    if ($Yes) { Stop-Setup 'No working TELEGRAM_BOT_TOKEN is set. Run setup without -Yes to enter one.' }

    Write-Note 'Create a bot, or reuse one you already have:'
    Write-Note '  1. In Telegram, open a chat with @BotFather and send /newbot. Pick a name and a username.'
    Write-Note '     (Existing bot: send /mybots, pick it, then "API Token".)'
    Write-Note '  2. Send /setjoingroups, pick your bot, then Disable, so nobody can add it to a group.'
    Write-Note '  3. Copy the token BotFather shows you (it looks like 123456789:AAH...).'
    Write-Note 'Your typing is hidden, and the token is never saved to a file or to shell history.'
    for ($try = 1; $try -le 3; $try++) {
        $secure = Read-Host -AsSecureString '  Paste the bot token'
        $token = [Net.NetworkCredential]::new('', $secure).Password.Trim()
        $me = Test-BotToken $token
        if ($me) {
            Set-UserVar 'TELEGRAM_BOT_TOKEN' $token
            $script:Token = $token; $script:BotName = $me.username
            Write-Ok "Token works for @$($me.username). Stored in your user environment (TELEGRAM_BOT_TOKEN)."
            return
        }
        Write-Warn 'That token didn''t work. Check you copied all of it (digits, a colon, then about 35 characters).'
    }
    Stop-Setup 'No working bot token after 3 tries.'
}

function Initialize-ChatId {
    $existing = [Environment]::GetEnvironmentVariable('TELEGRAM_CHAT_ID', 'User')
    if ($existing -match '^\d+$' -and (Read-YesNo 'A chat ID is already set. Keep it?' $true)) {
        $script:ChatId = $existing
        Write-Ok 'Keeping your chat ID.'
        return
    }
    if ($Yes) { Stop-Setup 'No TELEGRAM_CHAT_ID is set. Run setup without -Yes to find it.' }

    $code = 'setup ' + (Get-Random -Minimum 1000 -Maximum 9999)
    Write-Note "Open your chat with @$script:BotName in Telegram (tap Start if it's new) and send exactly:"
    Write-Host ''
    Write-Host "      $code" -ForegroundColor White
    Write-Host ''
    Write-Note 'Waiting up to 3 minutes...'
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        try {
            # No offset: this reads without confirming, so nothing is taken from the hooks.
            $updates = Invoke-Tg $script:Token 'getUpdates' @{ timeout = 20; allowed_updates = @('message') } 30
        } catch {
            if ($_.Exception.Message -match '409') {
                Stop-Setup 'This bot has a webhook set, so it can''t be polled. Remove it (Telegram Bot API deleteWebhook) or use another bot.'
            }
            Write-Warn $_.Exception.Message; Start-Sleep -Seconds 3; continue
        }
        $hit = @($updates | Where-Object { "$($_.message.text)".Trim() -ieq $code }) | Select-Object -Last 1
        if (-not $hit) { continue }
        $m = $hit.message
        if ("$($m.chat.type)" -ne 'private' -or "$($m.from.id)" -ne "$($m.chat.id)") {
            Write-Warn 'That message came from a group, not your private chat with the bot. Send it in the private chat.'
            continue
        }
        $who = (("$($m.from.first_name) $($m.from.last_name)").Trim() + $(if ($m.from.username) { " (@$($m.from.username))" } else { '' })).Trim()
        if (-not (Read-YesNo "Got it from $who. Is that you?" $true)) { Stop-Setup 'Setup stopped. Run it again and send the code from your own account.' }
        Set-UserVar 'TELEGRAM_CHAT_ID' "$($m.chat.id)"
        $script:ChatId = "$($m.chat.id)"
        Write-Ok 'Chat ID stored in your user environment (TELEGRAM_CHAT_ID).'
        return
    }
    Stop-Setup ("No ""$code"" message arrived. Check you sent it to @$script:BotName. If Claude is waiting on a Telegram " +
        'reply on another computer with the same bot, that computer may have taken it; try again when it''s idle.')
}

# ---------------------------------------------------------------- settings.json

function Get-PwshPath {
    $std = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path $std) { return $std }
    $p = (Get-Process -Id $PID).Path
    if ($p -match 'WindowsApps') {
        Write-Warn "PowerShell runs from the Microsoft Store folder ($p). That path changes on every update, which breaks the hooks."
        Write-Warn 'Install PowerShell with winget instead: winget install --id Microsoft.PowerShell'
    }
    return $p
}

function Read-Settings {
    if (-not (Test-Path $SettingsPath)) { return [ordered]@{} }
    $raw = Get-Content -Raw -Path $SettingsPath
    if (-not "$raw".Trim()) { return [ordered]@{} }
    try { $s = $raw | ConvertFrom-Json -AsHashtable -Depth 64 }
    catch { Stop-Setup "Couldn't read $SettingsPath as JSON ($($_.Exception.Message)). Fix it, then run setup again. Nothing was changed." }
    if ($s -isnot [Collections.IDictionary]) { Stop-Setup "$SettingsPath doesn't contain a JSON object. Nothing was changed." }
    return $s
}

function ConvertTo-SettingsJson($S) { ($S | ConvertTo-Json -Depth 64) + "`n" }

# Our entries, built from examples/settings.template.json with this machine's paths.
function Get-OurEntries([string]$Pwsh) {
    $esc = { param($v) ($v | ConvertTo-Json).Trim('"') }
    $text = Get-Content -Raw (Join-Path $RepoRoot 'examples\settings.template.json')
    $text = $text.Replace('{{PWSH}}', (& $esc $Pwsh)).Replace('{{HOOKS_DIR}}', (& $esc $HooksDir.TrimEnd('\')))
    return ($text | ConvertFrom-Json -AsHashtable -Depth 64)
}

function Test-OurHandler($H) {
    $line = "$($H.command) " + (@($H.args) -join ' ')
    return [bool]($line -match $OurScriptPattern)
}

# Removes every handler that runs one of our scripts, and our ask rules. Leaves everything else.
function Remove-OurEntries($S, $AskRules) {
    if ($S.Contains('hooks') -and $S.hooks -is [Collections.IDictionary]) {
        foreach ($event in @($S.hooks.Keys)) {
            $groups = [Collections.Generic.List[object]]::new()
            foreach ($g in @($S.hooks[$event])) {
                if ($g -isnot [Collections.IDictionary]) { $groups.Add($g); continue }
                $kept = @(@($g.hooks) | Where-Object { $_ -and -not (Test-OurHandler $_) })
                if ($kept.Count -eq @($g.hooks).Count) { $groups.Add($g); continue }
                if ($kept.Count) { $g.hooks = $kept; $groups.Add($g) }
            }
            if ($groups.Count) { $S.hooks[$event] = $groups.ToArray() } else { $S.hooks.Remove($event) }
        }
        if ($S.hooks.Count -eq 0) { $S.Remove('hooks') }
    }
    if ($S.Contains('permissions') -and $S.permissions -is [Collections.IDictionary] -and $S.permissions.Contains('ask')) {
        $left = @(@($S.permissions.ask) | Where-Object { $_ -notin $AskRules })
        if ($left.Count) { $S.permissions.ask = $left } else { $S.permissions.Remove('ask') }
        if ($S.permissions.Count -eq 0) { $S.Remove('permissions') }
    }
}

function Add-OurEntries($S, $Ours, [string[]]$Selected) {
    $events = @()
    if ('approve' -in $Selected) { $events += 'PermissionRequest' }
    if ('turn' -in $Selected) { $events += 'Stop' }
    if ('gate' -in $Selected) {
        $events += 'PreToolUse'
        if (-not $S.Contains('permissions') -or $S.permissions -isnot [Collections.IDictionary]) { $S.permissions = [ordered]@{} }
        $S.permissions.ask = @(@($S.permissions.ask) | Where-Object { $_ }) + @($Ours.permissions.ask | Where-Object { $_ -notin @($S.permissions.ask) })
    }
    if (-not $events) { return }
    if (-not $S.Contains('hooks') -or $S.hooks -isnot [Collections.IDictionary]) { $S.hooks = [ordered]@{} }
    # Template order, so a re-run over an identical install compares equal.
    foreach ($e in @($Ours.hooks.Keys | Where-Object { $_ -in $events })) { $S.hooks[$e] = @(@($S.hooks[$e]) | Where-Object { $_ }) + @($Ours.hooks[$e]) }
}

function Get-Summary($S) {
    $lines = @()
    if ($S.permissions.ask) { $mine = @($S.permissions.ask | Where-Object { $_ -match 'git|gh pr merge' }); if ($mine) { $lines += "permissions.ask: $($mine.Count) push/merge rules" } }
    if (-not ($S.Contains('hooks') -and $S.hooks -is [Collections.IDictionary])) { return $lines }
    foreach ($e in 'PreToolUse', 'PermissionRequest', 'Stop') {
        $n = @(@($S.hooks[$e]) | ForEach-Object { if ($_) { @($_.hooks) } } | Where-Object { $_ -and (Test-OurHandler $_) }).Count
        if ($n) { $lines += "hooks.$e`: $n handler(s) from this tool" }
    }
    return $lines
}

function Save-WithBackup([string]$Path, [string]$Content) {
    if (Test-Path $Path) {
        $bak = "$Path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $Path $bak
        Write-Ok "Backed up to $bak"
    }
    [IO.File]::WriteAllText($Path, $Content, $Utf8)
}

function Update-Settings([string[]]$Selected, [switch]$RemoveOnly) {
    $before = Read-Settings
    $beforeJson = ConvertTo-SettingsJson $before
    $after = Read-Settings
    $ours = Get-OurEntries (Get-PwshPath)
    Remove-OurEntries $after @($ours.permissions.ask)
    if (-not $RemoveOnly) { Add-OurEntries $after $ours $Selected }
    $afterJson = ConvertTo-SettingsJson $after

    if ($afterJson -ceq $beforeJson) { Write-Ok "$SettingsPath is already up to date."; return }
    $summary = Get-Summary $after
    if ($RemoveOnly) { Write-Note 'This tool''s entries will be removed from settings.json. Everything else stays.' }
    else {
        Write-Note 'settings.json will contain:'
        foreach ($l in $summary) { Write-Note "  + $l" }
        Write-Note 'Your other settings stay as they are (the file may be re-indented).'
    }
    if ($DryRun) {
        Write-Note '--- settings.json after setup (dry run, not written):'
        Write-Host $afterJson
        return
    }
    if (-not (Read-YesNo "Write these changes to $SettingsPath?" $true)) { Stop-Setup 'Setup stopped before changing settings.json.' }
    Save-WithBackup $SettingsPath $afterJson
    Write-Ok 'settings.json updated. Running Claude sessions pick this up on their own.'
}

# ---------------------------------------------------------------- CLAUDE.md

function Update-ClaudeMd([bool]$Want) {
    $text = if (Test-Path $ClaudeMdPath) { [IO.File]::ReadAllText($ClaudeMdPath) } else { '' }
    $pattern = '(?s)\r?\n?' + [regex]::Escape($MarkerStart) + '.*?' + [regex]::Escape($MarkerEnd) + '\r?\n?'
    $hasBlock = $text.Contains($MarkerStart)
    if ($Want) {
        $note = (Get-Content -Raw (Join-Path $RepoRoot 'examples\CLAUDE.md')).TrimEnd()
        $block = "$MarkerStart`n$note`n$MarkerEnd`n"
        if ($hasBlock) { $new = [regex]::Replace($text, $pattern, "`n$block", 1).TrimStart("`r", "`n") }
        elseif ($text.Contains($LegacyHeading)) { Write-Ok 'CLAUDE.md already has the push/merge note.'; return }
        elseif ($text.Trim()) { $new = $text.TrimEnd() + "`n`n" + $block }
        else { $new = $block }
    } else {
        if (-not $hasBlock) { return }
        $new = [regex]::Replace($text, $pattern, "`n").Trim()
        if ($new) { $new += "`n" }
    }
    if ($new -ceq $text) { Write-Ok 'CLAUDE.md is already up to date.'; return }
    if ($DryRun) { Write-Note "Would $(if ($Want) { 'add' } else { 'remove' }) the push/merge note in $ClaudeMdPath (dry run)."; return }
    Save-WithBackup $ClaudeMdPath $new
    Write-Ok "$(if ($Want) { 'Added' } else { 'Removed' }) the push/merge note in $ClaudeMdPath."
}

# ---------------------------------------------------------------- hook files

function Install-HookFiles {
    if ($DryRun) { Write-Note "Would copy $($HookScripts -join ', ') to $HooksDir (dry run)."; return }
    $null = New-Item -ItemType Directory -Force -Path $HooksDir
    foreach ($name in $HookScripts) {
        $src = Join-Path $RepoRoot "hooks\$name"
        $dst = Join-Path $HooksDir $name
        if ((Test-Path $dst) -and (Get-FileHash $dst).Hash -eq (Get-FileHash $src).Hash) { continue }
        if (Test-Path $dst) { Copy-Item $dst "$dst.bak" -Force }
        Copy-Item $src $dst -Force
        Unblock-File $dst -ErrorAction SilentlyContinue
    }
    Write-Ok "Hook scripts are in $HooksDir."
}

# ---------------------------------------------------------------- live tests

function Invoke-HookProcess([string]$Script, [string]$Payload, [string[]]$Extra) {
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-PwshPath))
    foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Extra) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.Write($Payload); $p.StandardInput.Close()
    $p.WaitForExit()
    return @{ code = $p.ExitCode; out = $out.Result; err = $err.Result }
}

function Invoke-LiveTests([string[]]$Selected) {
    if ('approve' -in $Selected -and (Read-YesNo 'Send a test approval request to your phone now?' $true)) {
        Write-Note 'Tap Approve (/yes_...) on your phone. Waiting up to 2 minutes...'
        $payload = @{ session_id = 'setup-test'; transcript_path = ''; cwd = $RepoRoot; permission_mode = 'default'
            hook_event_name = 'PermissionRequest'; tool_name = 'Bash'
            tool_input = @{ command = 'echo setup-test'; description = 'Setup test: tap Approve. Nothing will run.' } } | ConvertTo-Json -Compress
        $r = Invoke-HookProcess (Join-Path $HooksDir 'telegram-approve.ps1') $payload @('-WindowSeconds', '120')
        if ($r.out -match '"behavior":"allow"') { Write-Ok 'Your phone approved the test request.' }
        elseif ($r.out -match '"behavior":"deny"') { Write-Ok 'Your phone denied the test request (that works too).' }
        else { Write-Warn "No answer arrived. Check the newest log in $HooksDir\logs." }
    }
    if ('turn' -in $Selected -and (Read-YesNo 'Send a test question and reply to it from your phone?' $true)) {
        $tx = Join-Path ([IO.Path]::GetTempPath()) ("claude-telegram-setup-$PID.jsonl")
        $ts = [DateTimeOffset]::UtcNow.ToString('o')
        $lines = @(
            (@{ type = 'user'; promptId = 'setup'; timestamp = $ts; message = @{ role = 'user'; content = 'setup test' } } | ConvertTo-Json -Compress -Depth 8)
            (@{ type = 'assistant'; timestamp = $ts; message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; id = 'toolu_setup'; name = 'mcp__ccd_turn__wrap_up'
                                input = [ordered]@{ recap = 'This is the setup test.'; ask = 'Setup test: swipe-reply to this message with any text.' } }) } } | ConvertTo-Json -Compress -Depth 8)
        )
        [IO.File]::WriteAllText($tx, ($lines -join "`n") + "`n", $Utf8)
        Write-Note 'Swipe-reply to the question on your phone with any text. Waiting up to 2 minutes...'
        $payload = @{ session_id = "setup-test-$PID"; transcript_path = $tx; cwd = $RepoRoot; permission_mode = 'default'; hook_event_name = 'Stop' } | ConvertTo-Json -Compress
        $r = Invoke-HookProcess (Join-Path $HooksDir 'telegram-turn.ps1') $payload @('-WindowSeconds', '120')
        Remove-Item -LiteralPath $tx -ErrorAction SilentlyContinue
        if ($r.code -eq 2) { Write-Ok 'Your reply came back. Claude would continue with it.' }
        else { Write-Warn "No reply arrived. Check the newest log in $HooksDir\logs." }
    }
}

# ---------------------------------------------------------------- main

Write-Host 'Claude Code remote control over Telegram: setup' -ForegroundColor Cyan
if ($DryRun) { Write-Note '(dry run: nothing is written)' }

Write-Step 'Checking this machine'
if (-not $IsWindows) {
    Write-Warn 'These hooks are built and tested on Windows only.'
    if (-not (Read-YesNo 'Continue anyway?' $false)) { exit 1 }
}
Write-Ok "PowerShell $($PSVersionTable.PSVersion) at $(Get-PwshPath)"
if (-not (Test-Path $ClaudeDir)) {
    Write-Warn "$ClaudeDir doesn't exist yet. Install Claude Code and start it once, or let setup create the folder."
    if (-not (Read-YesNo 'Create it?' $true)) { exit 1 }
    if (-not $DryRun) { $null = New-Item -ItemType Directory -Force -Path $ClaudeDir }
}
$current = Read-Settings
Write-Ok "Claude settings: $SettingsPath$(if (-not (Test-Path $SettingsPath)) { ' (will be created)' })"
foreach ($m in (Join-Path $env:ProgramData 'ClaudeCode\managed-settings.json'), (Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.json')) {
    if ((Test-Path $m) -and (Select-String -Path $m -Pattern '"(allowManagedHooksOnly|disableAllHooks)"\s*:\s*true' -Quiet)) {
        Write-Warn "Your organization's managed settings ($m) block personal hooks. These hooks won't run until that changes."
    }
}
if ($current.disableAllHooks -eq $true) { Write-Warn '"disableAllHooks": true is set in your settings.json, so no hooks run. Remove it to use these.' }

if ($Uninstall) {
    Write-Step 'Removing this tool from Claude settings'
    Update-Settings @() -RemoveOnly
    Update-ClaudeMd $false
    if (-not $DryRun -and ([Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN', 'User') -or [Environment]::GetEnvironmentVariable('TELEGRAM_CHAT_ID', 'User'))) {
        if (Read-YesNo 'Also remove the bot token and chat ID from your user environment?' $false) {
            Set-UserVar 'TELEGRAM_BOT_TOKEN' $null; Set-UserVar 'TELEGRAM_CHAT_ID' $null
            Write-Ok 'Removed TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID.'
        }
    }
    Write-Note "The scripts, state and logs stay in $HooksDir; delete that folder if you don't need it."
    Write-Host ''; Write-Ok 'Uninstall finished.'
    exit 0
}

Write-Step 'Choosing features'
$chosen = [Collections.Generic.List[string]]::new()
if ($Features) { foreach ($f in $Features) { if ($f -notin $chosen) { $chosen.Add($f) } } }
else {
    if (Read-YesNo 'Approve permission prompts from your phone?' $true) { $chosen.Add('approve') }
    if (Read-YesNo 'Get end-of-turn questions on your phone, and reply to continue?' $true) { $chosen.Add('turn') }
    if (Read-YesNo 'Always ask before git push / PR merges, even in bypass mode?' $true) { $chosen.Add('gate') }
}
if (-not $chosen.Count) { Stop-Setup 'No features selected; nothing to do. (Use -Uninstall to remove this tool.)' }
$chosen = $chosen.ToArray()
Write-Ok ('Selected: ' + ($chosen -join ', '))

$needsTelegram = [bool]($chosen | Where-Object { $_ -in 'approve', 'turn' })
if ($needsTelegram -and -not $SkipTelegram -and -not $DryRun) {
    Write-Step 'Telegram bot'
    Initialize-BotToken
    Write-Step 'Your chat ID'
    Initialize-ChatId
    Write-Note 'Anyone who can message your bot as your Telegram account can approve tool calls.'
    Write-Note 'Turn on two-step verification in Telegram: Settings > Privacy and Security.'
}

Write-Step 'Installing the hooks'
Install-HookFiles

Write-Step 'Updating Claude settings'
Update-Settings $chosen
Update-ClaudeMd ('gate' -in $chosen)

if (-not $SkipLiveTest -and -not $DryRun -and $needsTelegram) {
    if ([Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN', 'User') -and [Environment]::GetEnvironmentVariable('TELEGRAM_CHAT_ID', 'User')) {
        Write-Step 'Live test'
        Invoke-LiveTests $chosen
    }
}

Write-Step 'Done'
if ('approve' -in $chosen) { Write-Note '- Permission prompts now also go to your phone; answer with the /yes_ or /no_ link.' }
if ('turn' -in $chosen) { Write-Note '- When Claude ends a turn with a question, your phone gets it; reply to continue.' }
if ('gate' -in $chosen) { Write-Note '- git push and PR merges always ask first, even in bypass mode.' }
Write-Note '- Use one computer at a time per bot: two computers waiting at once can take each other''s replies.'
Write-Note "- Turn it off: pwsh -File `"$PSCommandPath`" -Uninstall   (or set TELEGRAM_CHAT_ID to empty)."
exit 0
