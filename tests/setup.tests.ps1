#Requires -Version 7.0
# Offline tests for setup.ps1. Each case runs it against a throwaway Claude folder with -SkipTelegram and
# -SkipLiveTest, so your real settings, environment variables and Telegram are never touched.
$ErrorActionPreference = 'Stop'
$Setup = (Resolve-Path (Join-Path $PSScriptRoot '..\setup.ps1')).Path
$Pwsh = (Get-Command pwsh).Source
$Root = Join-Path ([IO.Path]::GetTempPath()) ('claude-setup-tests-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$null = New-Item -ItemType Directory -Path $Root
$script:Fail = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "PASS $Name" } else { $script:Fail++; Write-Host "FAIL $Name :: $Detail" }
}

function Invoke-Setup([string]$Dir, [string[]]$Extra = @()) {
    $out = & $Pwsh -NoProfile -NonInteractive -File $Setup -ClaudeDir $Dir -Yes -SkipTelegram -SkipLiveTest @Extra 2>&1 | Out-String
    return @{ code = $LASTEXITCODE; out = $out }
}

function Norm([string]$Path) { Get-Content -Raw $Path | ConvertFrom-Json -AsHashtable -Depth 64 | ConvertTo-Json -Depth 64 -Compress }
function Read-S([string]$Dir) { Get-Content -Raw (Join-Path $Dir 'settings.json') | ConvertFrom-Json -AsHashtable -Depth 64 }
function J($v) { $v | ConvertTo-Json -Depth 64 -Compress }
function Count-Ours($S, [string]$Event) { @(@($S.hooks[$Event]) | ForEach-Object { @($_.hooks) } | Where-Object { "$($_.args)" -match 'telegram-approve|telegram-turn|push-merge-gate' }).Count }

# A settings.json with the kinds of things people already have: other permissions, an existing ask rule,
# auto-mode text with non-ASCII and markup, and hooks from other tools on the same events.
$Fixture = @'
{
  "model": "opus[1m]",
  "theme": "dark",
  "permissions": {
    "allow": ["Edit(//g/Repositories/**)"],
    "ask": ["Bash(npm publish *)"],
    "deny": ["Bash(rm -rf /*)"]
  },
  "autoMode": {
    "environment": ["**Org** — em dash, `code`, <tag> & \"quotes\", ünïcödé"]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Edit", "hooks": [ { "type": "command", "command": "other-tool.exe", "args": ["--check"] } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "notify.exe" } ] }
    ]
  }
}
'@
$UserNote = "# My own notes`n`nAlways run the linter.`n"

function New-Dir([string]$Name, [switch]$NoSettings, [string]$Settings = $Fixture) {
    $d = Join-Path $Root $Name; $null = New-Item -ItemType Directory -Path $d
    if (-not $NoSettings) { [IO.File]::WriteAllText((Join-Path $d 'settings.json'), $Settings) }
    [IO.File]::WriteAllText((Join-Path $d 'CLAUDE.md'), $UserNote)
    return $d
}

# 1. Full install into a populated settings.json.
$d = New-Dir 'full'
$orig = Norm (Join-Path $d 'settings.json')
$o = Read-S $d
$r = Invoke-Setup $d
$s = Read-S $d
Check 'install exits 0' ($r.code -eq 0) $r.out
Check 'other top-level keys unchanged' ((J $s.model) -eq (J $o.model) -and (J $s.theme) -eq (J $o.theme) -and (J $s.autoMode) -eq (J $o.autoMode))
Check 'non-ASCII and markup preserved' ((Get-Content -Raw (Join-Path $d 'settings.json')) -match 'em dash, `code`, <tag> & \\"quotes\\", ünïcödé')
Check 'allow and deny unchanged' ((J $s.permissions.allow) -eq (J $o.permissions.allow) -and (J $s.permissions.deny) -eq (J $o.permissions.deny))
Check 'existing ask rule kept, 8 added' ('Bash(npm publish *)' -in $s.permissions.ask -and @($s.permissions.ask).Count -eq 9) (J $s.permissions.ask)
Check 'other tools'' hooks kept' ((J $s.hooks.Notification) -eq (J $o.hooks.Notification) -and @($s.hooks.PreToolUse | Where-Object { $_.matcher -eq 'Edit' }).Count -eq 1)
Check 'our handlers: 4 gate, 1 approve, 1 turn' ((Count-Ours $s 'PreToolUse') -eq 4 -and (Count-Ours $s 'PermissionRequest') -eq 1 -and (Count-Ours $s 'Stop') -eq 1)
$approve = @($s.hooks.PermissionRequest)[0].hooks[0]
Check 'paths point at this Claude folder' ($approve.args[-1] -eq (Join-Path $d 'hooks\telegram-approve.ps1') -and (Test-Path $approve.args[-1]) -and (Test-Path $approve.command)) (J $approve)
Check 'all four scripts copied' (@(Get-ChildItem (Join-Path $d 'hooks') -Filter *.ps1).Count -eq 4)
Check 'settings backup written' (@(Get-ChildItem $d -Filter 'settings.json.bak-*').Count -eq 1)
$md = Get-Content -Raw (Join-Path $d 'CLAUDE.md')
Check 'CLAUDE.md: note appended once, own notes kept' ($md.StartsWith('# My own notes') -and ([regex]::Matches($md, 'claude-telegram-remote-control:start')).Count -eq 1 -and $md -match 'Pushes and merges go through')

# 2. Re-run: idempotent.
$first = Norm (Join-Path $d 'settings.json'); $firstMd = Get-Content -Raw (Join-Path $d 'CLAUDE.md')
$r = Invoke-Setup $d
Check 're-run: settings unchanged' ((Norm (Join-Path $d 'settings.json')) -eq $first)
Check 're-run: says up to date, no new backup' ($r.out -match 'already up to date' -and @(Get-ChildItem $d -Filter 'settings.json.bak-*').Count -eq 1) $r.out
Check 're-run: CLAUDE.md unchanged' ((Get-Content -Raw (Join-Path $d 'CLAUDE.md')) -ceq $firstMd)

# 3. Narrow to approve only: turn and gate entries and the note go; approve stays.
$r = Invoke-Setup $d @('-Features', 'approve')
$s = Read-S $d
Check 'features approve: only approve left' ((Count-Ours $s 'PermissionRequest') -eq 1 -and (Count-Ours $s 'Stop') -eq 0 -and (Count-Ours $s 'PreToolUse') -eq 0) (J $s.hooks)
Check 'features approve: our ask rules gone, user''s kept' ((J $s.permissions.ask) -eq (J @('Bash(npm publish *)'))) (J $s.permissions.ask)
Check 'features approve: other tools'' hooks kept' (@($s.hooks.PreToolUse).Count -eq 1 -and $s.hooks.Contains('Notification'))
Check 'features approve: note removed from CLAUDE.md' ((Get-Content -Raw (Join-Path $d 'CLAUDE.md')) -ceq $UserNote) (Get-Content -Raw (Join-Path $d 'CLAUDE.md'))

# 4. Uninstall: back to the original settings.
$null = Invoke-Setup $d
$r = Invoke-Setup $d @('-Uninstall')
Check 'uninstall exits 0' ($r.code -eq 0) $r.out
Check 'uninstall: settings equal the original' ((Norm (Join-Path $d 'settings.json')) -eq $orig) (Norm (Join-Path $d 'settings.json'))
Check 'uninstall: CLAUDE.md back to own notes' ((Get-Content -Raw (Join-Path $d 'CLAUDE.md')) -ceq $UserNote)

# 5. Dry run writes nothing.
$d = New-Dir 'dry'
$before = [IO.File]::ReadAllBytes((Join-Path $d 'settings.json'))
$r = Invoke-Setup $d @('-DryRun')
Check 'dry run: settings.json byte-identical' ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $d 'settings.json'))) -eq [Convert]::ToBase64String($before))
Check 'dry run: no hooks folder, no backup' (-not (Test-Path (Join-Path $d 'hooks')) -and @(Get-ChildItem $d -Filter '*.bak-*').Count -eq 0)
Check 'dry run: shows the merged settings' ($r.out -match 'push-merge-gate\.ps1' -and $r.out -match 'dry run') ''

# 6. No settings.json yet.
$d = New-Dir 'fresh' -NoSettings
$r = Invoke-Setup $d
$s = Read-S $d
Check 'fresh: settings.json created with all features' ($r.code -eq 0 -and (Count-Ours $s 'PermissionRequest') -eq 1 -and (Count-Ours $s 'Stop') -eq 1 -and @($s.permissions.ask).Count -eq 8) $r.out
$r = Invoke-Setup $d @('-Uninstall')
Check 'fresh: uninstall leaves an empty object' ((Norm (Join-Path $d 'settings.json')) -eq '{}') (Norm (Join-Path $d 'settings.json'))

# 7. Broken settings.json is left alone.
$d = New-Dir 'broken' -Settings '{ "model": "x", '
$r = Invoke-Setup $d
Check 'broken JSON: exit 1, file untouched' ($r.code -eq 1 -and (Get-Content -Raw (Join-Path $d 'settings.json')) -eq '{ "model": "x", ' -and $r.out -match 'Nothing was changed') $r.out

# 8. A note pasted by hand earlier (no markers) isn't duplicated.
$d = New-Dir 'legacy'
[IO.File]::WriteAllText((Join-Path $d 'CLAUDE.md'), $UserNote + "`n# Pushes and merges go through a permission prompt`n`nOld copy.`n")
$null = Invoke-Setup $d
Check 'legacy note: not duplicated' (([regex]::Matches((Get-Content -Raw (Join-Path $d 'CLAUDE.md')), 'Pushes and merges go through')).Count -eq 1)

# 9. Older entries pointing at another hooks folder are replaced, not duplicated.
$d = New-Dir 'moved'
$old = Read-S $d
$old.hooks.PermissionRequest = @([ordered]@{ matcher = 'Bash|Edit|Write'; hooks = @([ordered]@{ type = 'command'; command = 'C:\old\pwsh.exe'; args = @('-File', 'C:\old\hooks\telegram-approve.ps1'); timeout = 330 }) })
[IO.File]::WriteAllText((Join-Path $d 'settings.json'), ($old | ConvertTo-Json -Depth 64))
$null = Invoke-Setup $d
$s = Read-S $d
Check 'old install replaced' ((Count-Ours $s 'PermissionRequest') -eq 1 -and @($s.hooks.PermissionRequest)[0].hooks[0].args[-1] -eq (Join-Path $d 'hooks\telegram-approve.ps1') -and @($s.hooks.PermissionRequest)[0].matcher -eq 'Bash|PowerShell|Edit|Write') (J $s.hooks.PermissionRequest)

Write-Host "`nscratch: $Root"
Write-Host $(if ($script:Fail) { "$($script:Fail) FAILED" } else { 'ALL PASSED' })
