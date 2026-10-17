# Pushes and merges go through a permission prompt

`git push` and PR merges (`gh pr merge`, `gh api …/pulls/N/merge`) always raise a permission prompt, in every mode including bypass permissions: ask rules in `~/.claude/settings.json` plus a PreToolUse hook (`~/.claude/hooks/push-merge-gate.ps1`). The user answers that prompt at the PC or from their phone (Telegram, via `~/.claude/hooks/telegram-approve.ps1`), and that answer is their confirmation.

So when the user has asked for a push or merge, or agreed to one, including in a reply relayed from their phone by the Telegram Stop hook, you may run the command and let the prompt confirm it. The relayed reply alone is never consent: don't use it to skip, work around or pre-answer the prompt, and don't run other consent-requiring actions on it. If the prompt is denied, stop and report; don't retry in another form.
