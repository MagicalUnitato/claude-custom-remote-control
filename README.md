# Claude Code remote control over Telegram

Approve Claude Code permission prompts, answer its questions, and confirm `git push` / PR merges from your
phone, using a private Telegram bot and Claude Code hooks. It's built for setups where Claude Code's own
Remote Control isn't available (for example, disabled by an organization policy).

| What you get on the phone | Hook | Script |
|---|---|---|
| A tool needs permission (Bash, PowerShell, Edit, Write): tap **Approve** or **Deny** | `PermissionRequest` | `telegram-approve.ps1` |
| A session ends its turn with a question, or proposes a new-session card: the question, its buttons, and the card titles. Your reply continues the session | `Stop` | `telegram-turn.ps1` |
| `git push` and PR merges always ask first, even in bypass permissions mode, so a phone tap is a real approval | `PreToolUse` + ask rules | `push-merge-gate.ps1` |

A permission message looks like this:

```
🔐 Claude Code wants to use Bash  [k3m9tq]
Project: my-app / mode: default
$ git push origin main
Why: Push the fix

Approve: /yes_k3m9tq
Deny: /no_k3m9tq
or type: yes k3m9tq  /  no k3m9tq <reason>
Expires 14:05:12; after that, answer at the PC.
```

Nothing is ever approved without you. On a timeout, an error or missing configuration, the hooks stay silent
and Claude Code's normal dialog decides.

## Requirements

- Windows 10 or 11 with PowerShell 7 (`pwsh`). Windows PowerShell 5.1 isn't supported.
- Claude Code with hooks support: the Claude desktop app, the CLI or an IDE extension. Tested with the
  desktop app on Claude Code 2.1.299. The end-of-turn question alerts read the desktop app's "next step"
  box; elsewhere, set `TELEGRAM_TURN_ALERTS=all` (see [Configuration](#configuration)).
- A Telegram account and the Telegram app on your phone.

The scripts use Windows-only pieces (named mutexes, the Recycle Bin). macOS and Linux are untested.

## Setup

### 1. Create your bot

1. In Telegram, open a chat with **@BotFather** and send `/newbot`. Pick a name and a username. BotFather
   replies with the bot token.
2. Send `/setjoingroups`, pick your bot, then **Disable**, so nobody can add it to a group.
3. Turn on two-step verification in Telegram (Settings → Privacy and Security). Anyone who can send
   messages as your Telegram account can approve tool calls.

### 2. Store the token and your chat ID

The hooks read two **User** environment variables. Keep the token out of files, chats and shell history:
this prompt hides your input and nothing is saved to history.

```powershell
$s = Read-Host -AsSecureString 'Bot token'; [Environment]::SetEnvironmentVariable('TELEGRAM_BOT_TOKEN', [Net.NetworkCredential]::new('', $s).Password, 'User'); Remove-Variable s
```

Send your bot any message (for example "hi"), then print your IDs. This prints only to your own terminal:

```powershell
$t = [Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN','User'); (Invoke-RestMethod "https://api.telegram.org/bot$t/getUpdates").result.message | ForEach-Object { "{0} {1} {2}" -f $_.from.id, $_.chat.id, $_.chat.type }; Remove-Variable t
```

You should see two equal numbers and `private`. Store that number:

```powershell
[Environment]::SetEnvironmentVariable('TELEGRAM_CHAT_ID', (Read-Host 'Chat ID'), 'User')
```

Avoid `setx TELEGRAM_BOT_TOKEN "<token>"`: PowerShell saves typed commands, token included, to its history
file. The hooks read the User environment directly, so you don't need to restart Claude after setting these.

### 3. Install the scripts

From a clone of this repo:

```powershell
pwsh -File .\install.ps1
```

It copies `hooks\*.ps1` to `~\.claude\hooks\` and prints a JSON snippet with your paths filled in. It never
edits `settings.json`. If a copy already there differs, it warns; `-Force` replaces it and keeps the old
one as `.bak`.

### 4. Register the hooks

Back up `~\.claude\settings.json`, then merge the printed snippet into it:

- `permissions.ask`: add the eight rules. If you already have a `permissions` block, add an `ask` list next
  to your `allow` list rather than replacing the block.
- `hooks`: add the `PreToolUse`, `PermissionRequest` and `Stop` entries. If you already have hooks, add these
  entries to your existing event lists.

You can take only what you want:

| Feature | Settings it needs |
|---|---|
| Phone approval of permission prompts | `hooks.PermissionRequest` |
| End-of-turn questions and session cards | `hooks.Stop` |
| Push/merge gate | `permissions.ask` + `hooks.PreToolUse`, plus `hooks.PermissionRequest` to answer the gate from the phone |

Claude Code picks up settings changes in running sessions.

### 5. Optional: tell Claude how pushes and merges are confirmed

Append [`examples/CLAUDE.md`](examples/CLAUDE.md) to `~\.claude\CLAUDE.md`. It tells Claude that after you
say "push it" from the phone, it may run the command and let the permission prompt confirm it. Without it,
Claude usually asks again at the PC. See [Pushes and merges](#pushes-and-merges).

### 6. Try it

In a Manual-mode session, ask Claude to run `pwsh -NoProfile -Command "Write-Output hello"` with the Bash
tool. (Read-only commands such as `echo` or `ls` never prompt, so they never reach the phone.) The dialog
appears at the PC, and the same request arrives on your phone. Tap `/yes_…` and the command runs.

## Using it

### Permission prompts

Answer with the tappable `/yes_<id>` or `/no_<id>`, or type `yes <id>` / `no <id> <reason>`. A reason is
passed to Claude. The phone and the PC dialog race, and the first answer wins. If you answer at the PC,
the phone gets "answered at the PC". After 5 minutes the phone gets "Timed out", and the PC dialog stays
open.

The hook only sees calls that would prompt. Calls allowed by your rules or mode, or decided by the auto-mode
classifier, never reach it. In auto mode the classifier allows or denies without a prompt, so the phone hears
nothing. In bypass permissions mode only the push/merge gate prompts.

### End-of-turn questions and session cards

When a turn ends with a question in the desktop app's next-step box, your phone gets the question, the recap
and the box's buttons as `/re_<id>_<n>` commands. Within 30 minutes you can answer:

- tap a button;
- swipe-reply to the alert;
- type `re <id> <answer>`.

The session wakes and continues with your answer, and the phone gets "Sent to Claude". If you type in that
session at the PC first, the wait ends quietly.

If the turn also proposed **new-session cards**, the alert lists their titles. You can't start a card from
the phone: the app starts sessions only on your own words in that chat. Open the app to start it.

**A phone reply is information, not consent.** It reaches Claude as a hook message that Claude Code marks
as not coming from you. "CI is green" or "rebase first" works; a phone reply alone won't get a merge,
push or delete done. That's what the push/merge gate is for.

### Pushes and merges

Ask rules and the gate hook make `git push`, `gh pr merge` and `gh api …/pulls/N/merge` raise a permission
prompt in every mode, including bypass permissions. That prompt goes to your phone like any other, so
merging from the phone takes two taps:

1. Claude asks "Merge #119?" and you tap **Merge now** on the alert.
2. Claude runs `gh pr merge`, the prompt comes to your phone, and you tap **Approve**.

The prompt is decided by Claude Code's permission system, not by Claude reading a message, so it counts as
your approval.

## Configuration

| Setting | Where | Default | Effect |
|---|---|---|---|
| `TELEGRAM_BOT_TOKEN` | User env | required | Bot token |
| `TELEGRAM_CHAT_ID` | User env | required | Your numeric Telegram ID; only replies from it, in your private chat with the bot, count |
| `TELEGRAM_TURN_ALERTS` | User env | `ask` | `ask`: alert when the box has a question or the turn proposed a card. `all`: alert at every turn end (use this outside the desktop app). `off`: no turn alerts |
| `-WindowSeconds` | hook `args` | 300 (approve), 1800 (turn) | How long to wait for your answer. Keep the hook's `timeout` above it |
| `-PollSeconds` | hook `args` | 2 (approve), 4 (turn) | How often to check Telegram while waiting |

Variables are read on every run, from the process environment and then the User environment, so no
restart is needed.

## Turning it off

- **Turn alerts only:** `[Environment]::SetEnvironmentVariable('TELEGRAM_TURN_ALERTS', 'off', 'User')`.
- **All Telegram traffic:** clear `TELEGRAM_CHAT_ID`. The hooks then exit silently and every prompt stays at
  the PC.
- **For good:** remove the entries from `~\.claude\settings.json`. For the gate, also remove the `ask`
  rules and the section in `~\.claude\CLAUDE.md`.
- **All hooks, temporarily:** add `"disableAllHooks": true` to `~\.claude\settings.json`.

## Security and privacy

- **This is a standing grant.** Anyone who can message the bot as your account can approve tool calls. Keep
  the bot out of groups and use Telegram's two-step verification.
- **What leaves your machine:** only calls to `https://api.telegram.org/bot<token>/…`:
  - `sendMessage`: request summaries, turn alerts, confirmations and short status replies;
  - `getUpdates`: polling while something waits for an answer.
- **What a message contains:**
  - Bash and PowerShell: the command and its description, cut to about 300 characters.
  - Edit and Write: only the file path and sizes, never file contents.
  - Turn alerts: the box's question, recap and button labels.
- **Redaction:** all outgoing text has common secret patterns masked: bearer tokens, `sk-`, `ghp_`,
  `github_pat_`, Slack and AWS keys, JWTs, URL passwords, `password=`, `token=` and `api_key=` values, long
  hex or base64 runs, and the values of environment variables named like TOKEN, SECRET, KEY or PASSWORD.
  It's pattern-based, so treat it as best effort.
- **Never a hook auto-allow:** a hook only allows a call after a `yes` from your chat ID that carries that
  request's ID. Unknown, stale or wrong-sender replies are ignored. A recent stale reply gets an "expired"
  or "already answered" answer.
- **Logs** (`~\.claude\hooks\logs\`, monthly) record events, request IDs, tool names and modes. They never
  record commands, message text, the token or the chat ID. Logs older than 90 days go to the Recycle Bin.
- **The gate is a convenience, not a security boundary.** It matches command text, so aliases, scripts
  that push, `sh -c '…'`, or merges through the web UI or an MCP connector aren't caught.

## How it works

- **One bot, many waiters.** Telegram allows one `getUpdates` reader per bot, and reading confirms updates
  for everyone. Every running hook takes the same named mutex, fetches new updates, advances a shared
  cursor in `state\state.json`, and files each valid reply under its request ID. Several sessions and
  subagents can wait at once without stealing each other's answers.
- **Noticing a PC answer.** Claude Code doesn't cancel a permission hook when you answer the dialog. So the
  hook watches the session transcript for a result to its own tool call and stops when one appears. The
  turn hook stops when a new prompt shows up in the transcript.
- **Waking a session.** The Stop hook runs with `async` and `asyncRewake`, so the turn ends normally. On
  your reply it exits with code 2, which wakes the session with your text.
- **Network.** The scripts disable IPv6 for their own process, because IPv6 to `api.telegram.org` can hang
  on some networks. A timed-out poll only costs one interval: unconfirmed updates stay on Telegram for 24
  hours.

## Troubleshooting

- **Nothing arrives on the phone.**
  1. Check that both variables are set: `[bool][Environment]::GetEnvironmentVariable('TELEGRAM_CHAT_ID','User')`.
  2. Check that the action actually prompts. A read-only command, an allow rule, auto mode or bypass mode
     means there's no prompt.
  3. Look at the newest file in `~\.claude\hooks\logs\`.
- **`not-configured` in the log:** a variable is missing, or the chat ID isn't numeric.
- **`send-failed` or `poll-error`:** Telegram calls timed out. Occasional ones are normal; constant ones
  point to a network or proxy issue.
- **The hook never runs at all:** check that `pwsh` is at the path in `settings.json`, and that nothing sets
  `disableAllHooks` or `allowManagedHooksOnly` (managed settings can block user hooks).

## Tests

Offline suites; they use a fake token and fake Telegram updates, and make no network calls:

```powershell
pwsh -File .\tests\approve.tests.ps1
pwsh -File .\tests\telegram-hooks.tests.ps1
pwsh -File .\tests\gate-and-cards.tests.ps1
```

They run the scripts in `hooks\` and write their scratch files under your temp folder.
`approve.tests.ps1` skips its "no configuration" case when real `TELEGRAM_*` variables are set, because the
hooks fall back to them.

## Repo layout

```
hooks/
  telegram-common.ps1        shared: settings, redaction, logging, state file, Telegram polling
  telegram-approve.ps1       PermissionRequest hook
  telegram-turn.ps1          Stop hook (questions, session cards, replies)
  push-merge-gate.ps1        PreToolUse gate for git push / PR merges (no network)
examples/
  settings.template.json     what install.ps1 fills in and prints
  CLAUDE.md                  optional note for ~/.claude/CLAUDE.md
tests/                       offline test suites
install.ps1                  copies hooks/ to ~/.claude/hooks and prints the settings snippet
```
