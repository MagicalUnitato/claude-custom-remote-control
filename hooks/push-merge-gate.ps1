#Requires -Version 7.0
<#
  Claude Code PreToolUse hook: force a permission prompt for git push and PR merges.

  The ask rules in ~/.claude/settings.json (permissions.ask) are the main gate: they prompt in every mode,
  bypassPermissions included, and see through compound commands and subshells. They match by prefix, so
  they miss forms such as `git --git-dir=x push`, a full path to git.exe, or `gh api .../pulls/N/merge`.
  This hook covers those: on a match it returns permissionDecision "ask", so the prompt appears, and the
  Telegram PermissionRequest hook can answer it from the phone.

  It is registered with `if` filters (e.g. Bash(*git*push*)), so it only starts for commands that
  mention both words. No network. stdout is the decision JSON on a match and nothing otherwise; exit 0.
  The log records the match kind, never the command.
#>
[CmdletBinding()]
param(
    # Only makes each registered handler distinct (identical handlers are deduplicated); logged.
    [string]$Kind = '',
    [string]$LogDir = (Join-Path $PSScriptRoot 'logs')
)

$ErrorActionPreference = 'Stop'

# git [global options] push. Global options that take a value are consumed with it.
$PushPattern = @'
(?ix)
(?<![\w.-])git(?:\.exe)?["']?
(?:\s+(?:
     -[Cc]\s*(?:"[^"]*"|'[^']*'|\S+)
   | --(?:git-dir|work-tree|namespace|exec-path|config-env|super-prefix)(?:=|\s+)(?:"[^"]*"|'[^']*'|\S+)
   | --?[\w-]+
))*
\s+["']?push["']?(?![\w-])
'@

# gh [global options] pr merge, or a REST merge through gh api.
$MergePattern = @'
(?ix)
(?<![\w.-])gh(?:\.exe)?["']?(?:\s+(?:-R\s*\S+|--repo(?:=|\s+)\S+|--?[\w-]+))*\s+pr\s+merge(?![\w-])
| (?<![\w.-])gh(?:\.exe)?["']?\s+api\b[^\n;|&]*?pulls/[^/\s"']+/merge\b
'@

function Write-GateLog([string]$Line) {
    try {
        if (-not (Test-Path $LogDir)) { $null = New-Item -ItemType Directory -Path $LogDir -Force }
        $file = Join-Path $LogDir ('push-merge-gate-{0:yyyy-MM}.log' -f (Get-Date))
        [IO.File]::AppendAllText($file, ('{0:yyyy-MM-ddTHH:mm:ss.fffzzz} pid={1} {2}' -f (Get-Date), $PID, $Line) + "`n")
    } catch { }
}

$output = $null
try {
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false))
    $in = $reader.ReadToEnd() | ConvertFrom-Json
    $cmd = "$($in.tool_input.command)"
    $sess = "$($in.session_id)"; $sess = $sess.Substring(0, [Math]::Min(8, $sess.Length))
    $found = if ($cmd -match $PushPattern) { 'push' } elseif ($cmd -match $MergePattern) { 'merge' } else { $null }
    if ($found) {
        $output = @{ hookSpecificOutput = [ordered]@{
                hookEventName            = 'PreToolUse'
                permissionDecision       = 'ask'
                permissionDecisionReason = "git $found needs your OK (PC or Telegram)."
            } } | ConvertTo-Json -Compress -Depth 4
    }
    Write-GateLog ('tool={0} mode={1} sess={2} filter={3} ev={4}' -f $in.tool_name, $in.permission_mode, $sess, $Kind, $(if ($found) { "ask kind=$found" } else { 'no-match' }))
} catch {
    Write-GateLog "ev=error $($_.Exception.GetType().Name)"
}

if ($output) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($output)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
exit 0
