#Requires -Version 7.0
<#
  Copies the hook scripts into your Claude Code hooks folder and prints the settings to merge into
  ~/.claude/settings.json, with your paths filled in. It never edits settings.json, never touches the
  Telegram environment variables, and makes no network calls.

  Usage:
    pwsh -File install.ps1                 # install to ~/.claude/hooks
    pwsh -File install.ps1 -Force          # also replace copies that differ (old copy kept as .bak)
    pwsh -File install.ps1 -Destination D:\somewhere\hooks
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $HOME '.claude\hooks'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'hooks'
$null = New-Item -ItemType Directory -Force -Path $Destination

foreach ($f in Get-ChildItem -Path $source -Filter '*.ps1' -File) {
    $dst = Join-Path $Destination $f.Name
    if (Test-Path $dst) {
        if ((Get-FileHash $dst).Hash -eq (Get-FileHash $f.FullName).Hash) { "unchanged  $($f.Name)"; continue }
        if (-not $Force) { Write-Warning "$dst differs from the repo copy; rerun with -Force to replace it (the old copy is kept as $($f.Name).bak)"; continue }
        Copy-Item $dst "$dst.bak" -Force
    }
    Copy-Item $f.FullName $dst -Force
    "installed  $($f.Name)"
}

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
$jsonEscape = { param($s) ($s | ConvertTo-Json).Trim('"') }
$template = Get-Content -Raw (Join-Path $PSScriptRoot 'examples\settings.template.json')
$snippet = $template.Replace('{{PWSH}}', (& $jsonEscape $pwsh)).Replace('{{HOOKS_DIR}}', (& $jsonEscape $Destination.TrimEnd('\')))

''
'Next steps (see README.md):'
'  1. Create the bot and set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID (README, "Setup", steps 1-2).'
'  2. Merge the JSON below into ~/.claude/settings.json. Keep your existing keys; if you already have'
'     "permissions" or "hooks", add these entries to them rather than replacing them.'
'  3. Optional: append examples\CLAUDE.md to ~/.claude/CLAUDE.md (see README, "Pushes and merges").'
''
$snippet
