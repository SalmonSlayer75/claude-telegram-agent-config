# Security Deny Rules

Hardcoded permission boundaries that prevent AI agents from accessing secrets, destroying data, or executing dangerous commands — regardless of what the prompt says.

## The Problem

AI agents with shell access can accidentally (or via prompt injection) execute dangerous commands: reading SSH keys, piping curl output to bash, force-pushing to git, or accessing credential files. The `dontAsk` permission mode that channel bots need gives them broad access, so you need explicit deny rules as guardrails.

## The Solution

Claude Code's `settings.json` supports `deny` rules that override all `allow` rules. These are checked before every tool call — if a deny rule matches, the call is blocked with no way to override from the conversation.

### What We Block

**Destructive git operations:**
- `git push --force` — can overwrite upstream history
- `git reset --hard` — can destroy uncommitted work

**Dangerous shell commands:**
- `rm -rf /` and `rm -rf ~` — catastrophic deletion
- `> /dev/*` — device writes
- `curl|bash`, `wget|bash` — remote code execution
- `ssh`, `scp`, `nc`, `ncat`, `netcat` — network access

**Credential/secret access:**
- `~/.ssh/**` — SSH keys (read, write, edit all blocked)
- `~/.aws/**` — AWS credentials
- `~/.claude/bot-credentials.env` — bot tokens
- `**/.env` — any .env file in any directory

### Setup

Add deny rules to `~/.claude/settings.json` (user-level, applies to all projects) or to a project's `.claude/settings.local.json`:

```json
{
  "permissions": {
    "deny": [
      "Bash(git push --force*)",
      "Bash(git reset --hard*)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)",
      "Read(~/.ssh/**)",
      "Write(~/.ssh/**)",
      "Edit(~/.ssh/**)",
      "Read(**/.env)",
      "Write(**/.env)",
      "Edit(**/.env)",
      "Bash(curl * | bash*)",
      "Bash(ssh *)"
    ]
  }
}
```

See `settings.json.example` for the full recommended set.

### Pattern Syntax

- `Bash(pattern)` — matches bash commands
- `Read(pattern)`, `Write(pattern)`, `Edit(pattern)` — matches file operations
- `*` — wildcard matching
- `**` — recursive directory matching
- Deny rules always take precedence over allow rules

### Customization

Add deny rules for your specific environment:

```json
"Bash(docker rm -f *)",
"Bash(kubectl delete *)",
"Read(~/.kube/config)",
"Bash(aws iam *)",
"Bash(gcloud iam *)"
```

### User-Level vs Project-Level

- **User-level** (`~/.claude/settings.json`) — applies everywhere, good for universal safety rules
- **Project-level** (`.claude/settings.local.json`) — applies only in that project, good for project-specific restrictions

Deny rules from both levels are combined — you can't override a user-level deny at the project level.
