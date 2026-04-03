#!/usr/bin/env node
/**
 * Fleet-wide hook generator for Claude Code Telegram bots.
 *
 * Generates .claude/settings.local.json for every bot in the fleet from
 * a single configuration object. This ensures consistent hook behavior
 * and makes fleet-wide changes safe and repeatable.
 *
 * Usage:
 *   1. Edit the `bots` object below to match your fleet layout
 *   2. Run: node update-fleet-hooks.js
 *   3. Restart bots to pick up changes
 *
 * What it generates for each bot:
 *   - PreToolUse: startup state load (once), inbox check, mandatory state-save gate
 *   - PostToolUse: mandatory post-reply state save + profile update
 *   - PreCompact: emergency state flush before context compaction
 *   - PostCompact: reindex memory + reload state after compaction
 */

const fs = require('fs');
const path = require('path');

const HOME = process.env.HOME;

// ============================================================
// CONFIGURE YOUR FLEET HERE
// ============================================================
// Each bot needs:
//   dir:        absolute path to working directory
//   state:      path to state file (use ~ for home)
//   profile:    path to user profile file
//   daily:      path to daily notes directory
//   mem:        memory-search agent name
//   inbox:      inbox-check bot name
//   tmpPrefix:  unique prefix for /tmp flag files
//   context:    comma-separated list of context types this bot tracks
//   ack:        if true, adds acknowledge-before-research hook
// ============================================================

const bots = {
  'cos': {
    dir: `${HOME}/COS`,
    state: '~/COS/cos-state.md',
    profile: '~/COS/user-profile.md',
    daily: '~/COS/daily/',
    mem: 'cos',
    inbox: 'cos',
    tmpPrefix: 'cos',
    context: 'action items, decisions, commitments',
    ack: true,
  },
  'vpe-project-a': {
    dir: `${HOME}/ProjectA`,
    state: '~/ProjectA/vpe-state.md',
    profile: '~/ProjectA/user-profile.md',
    daily: '~/ProjectA/daily/',
    mem: 'vpe-a',
    inbox: 'vpe-project-a',
    tmpPrefix: 'vpea',
    context: 'bug details, decisions, code analysis',
    ack: false,
  },
  'vpe-project-b': {
    dir: `${HOME}/ProjectB`,
    state: '~/ProjectB/vpe-state.md',
    profile: '~/ProjectB/user-profile.md',
    daily: '~/ProjectB/daily/',
    mem: 'vpe-b',
    inbox: 'vpe-project-b',
    tmpPrefix: 'vpeb',
    context: 'bug details, decisions, code analysis',
    ack: false,
  },
  // Add more bots as needed:
  // 'devops': { ... },
  // 'cto': { ... },
};

// ============================================================
// HOOK GENERATION — edit below only if changing hook behavior
// ============================================================

for (const [name, bot] of Object.entries(bots)) {
  const settingsPath = path.join(bot.dir, '.claude', 'settings.local.json');

  // Startup command — runs once on first reply after restart
  const startupCmd = [
    `if [ ! -f /tmp/${bot.tmpPrefix}-state-loaded ]; then`,
    `  ~/bin/memory-daily-init ${bot.mem} 2>/dev/null;`,
    `  ~/bin/memory-search ${bot.mem} --index 2>/dev/null;`,
    `  echo '[STARTUP] Read these files FIRST to restore your working memory:`,
    `    (1) ${bot.state}`,
    `    (2) ${bot.profile}`,
    `    (3) ${bot.daily}'$(date +%Y-%m-%d)'.md.`,
    `    You can search past context with: memory-search ${bot.mem} "query"';`,
    `  touch /tmp/${bot.tmpPrefix}-state-loaded;`,
    `fi`,
  ].join(' ');

  // Pre-reply mandatory state save gate
  const preSave = `echo '[MANDATORY STATE SAVE] BEFORE sending this reply: Do you have ANY unsaved analysis, findings, ${bot.context}, or context from this conversation that are NOT yet in ${bot.state}? If YES: STOP. Write them to your state file FIRST using Edit, THEN send this reply. Your conversation can end at any moment — if it is not in your state file, it is LOST. This is not optional.'`;

  // Post-reply mandatory save
  const postSave = `echo '[MANDATORY] You just sent a Telegram reply. Update ${bot.state} NOW with any decisions, action items, ${bot.context}, or context from this exchange. Do NOT skip this — your conversation can reset at any moment and anything not in the state file will be permanently lost. Also update ${bot.profile} if you learned anything new about the user.'`;

  // Build PreToolUse hooks array
  const preToolUse = [
    {
      matcher: 'mcp__plugin_telegram_telegram__reply',
      hooks: [{ type: 'command', command: startupCmd }],
    },
    {
      matcher: 'mcp__plugin_telegram_telegram__reply',
      hooks: [{ type: 'command', command: `~/bin/inbox-check ${bot.inbox} 2>/dev/null || true` }],
    },
    {
      matcher: 'mcp__plugin_telegram_telegram__reply',
      hooks: [{ type: 'command', command: preSave }],
    },
  ];

  // Optional: acknowledge-before-research hook for user-facing bots
  if (bot.ack) {
    preToolUse.push({
      matcher: 'Read|Grep|WebSearch|WebFetch|Glob|mcp__google_workspace__|mcp__claude_ai_Notion__',
      hooks: [
        {
          type: 'command',
          command: "echo '[ACK-CHECK] If the user just sent a new message and you have NOT yet replied acknowledging it, STOP. Send a quick Telegram ack first (e.g. Got it — looking into that now.) before doing any research. Acknowledge-then-Act is mandatory.'",
        },
      ],
    });
  }

  const settings = {
    permissions: {
      allow: ['Bash(*)'],
      deny: [
        'Bash(git push --force*)',
        'Bash(git reset --hard*)',
        'Bash(rm -rf /*)',
        'Bash(rm -rf ~*)',
      ],
      defaultMode: 'dontAsk',
    },
    enableAllProjectMcpServers: true,
    hooks: {
      PreToolUse: preToolUse,
      PostToolUse: [
        {
          matcher: 'mcp__plugin_telegram_telegram__reply',
          hooks: [{ type: 'command', command: postSave }],
        },
      ],
      PreCompact: [
        {
          matcher: '.*',
          hooks: [
            {
              type: 'command',
              command: `echo '[PRE-COMPACTION] Context is about to be compacted. IMMEDIATELY: (1) Save unsaved state to ${bot.state} (2) Update ${bot.profile} with any new learnings about the user (3) Add important notes to ${bot.daily}'$(date +%Y-%m-%d)'.md. This is your LAST CHANCE to persist context.'`,
            },
          ],
        },
      ],
      PostCompact: [
        {
          matcher: '.*',
          hooks: [
            {
              type: 'command',
              command: `~/bin/memory-search ${bot.mem} --index 2>/dev/null; echo '[POST-COMPACTION] Context was just compacted. Re-read: (1) ${bot.state} (2) ${bot.profile} (3) ${bot.daily}'$(date +%Y-%m-%d)'.md to restore your working memory. Search past context with: memory-search ${bot.mem} "query"'`,
            },
          ],
        },
      ],
    },
  };

  // Ensure .claude directory exists
  const claudeDir = path.join(bot.dir, '.claude');
  if (!fs.existsSync(claudeDir)) {
    fs.mkdirSync(claudeDir, { recursive: true });
  }

  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
  console.log(`Updated: ${name} (${settingsPath})`);
}

console.log(`\nAll ${Object.keys(bots).length} bots updated. Restart bots to pick up changes.`);
