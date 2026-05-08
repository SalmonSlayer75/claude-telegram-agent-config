# Shared Libraries

Shell libraries sourced by multiple fleet scripts. Place these in `~/bin/lib/`.

## Files

### auto-resume-paths.sh
Single source of truth for per-bot auto-resume artifact directories. Maps bot names to filesystem paths. Supports both centralized (`~/.claude/state/<bot>/`) and project-tree (`~/<BotDir>/state/auto-resume/`) layouts. Migrate bots one at a time by updating the mapping.

### page-telegram.sh
Validated Telegram message sender. Checks HTTP 200 + JSON `ok:true`. On HTTP 400 (Markdown parse errors), retries once without `parse_mode`. Writes forensic `PAGE_FAILED` sentinel files on failure for post-incident analysis.

## Usage

```bash
source "$HOME/bin/lib/auto-resume-paths.sh"
dir=$(auto_resume_state_dir "mybot")

source "$HOME/bin/lib/page-telegram.sh"
page_telegram "$BOT_TOKEN" "$CHAT_ID" "Alert: something happened"
```
