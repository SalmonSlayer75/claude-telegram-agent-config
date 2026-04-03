# Agent Skills (Claude Code Slash Commands)

These are reusable Claude Code slash commands (placed in `.claude/commands/`) that give your Telegram bot specialized capabilities. They were developed for production use across multiple projects and are designed to be portable — 39 skills across 6 categories.

## How to Use

1. Copy any `.md` file into your project's `.claude/commands/` directory
2. The bot can invoke them with `/command-name` or you can reference them in CLAUDE.md instructions
3. Customize the project-specific references (repo names, file paths) for your codebase

## Categories

### VPE Workflow (`vpe-workflow/`) — 4 skills

Core engineering management workflow — plan, implement, review, ship.

| Skill | What it does |
|-------|-------------|
| `/review-plan` | Reviews an implementation plan before coding starts. Checks for gaps in root cause analysis, scope, security, test plan, and rollback strategy. |
| `/review-pr` | Full PR review with security audit, architecture check, test coverage analysis, and code quality scan. Posts findings with severity ratings (P0/P1/P2). |
| `/review-bugfix` | Bug fix review with higher scrutiny — verifies root cause, checks regression potential, assesses prevention. |
| `/engineering-status` | Current engineering status: open issues, PR status, CI health, recent commits, velocity metrics. |

### Auditors (`auditors/`) — 8 skills

Specialized code review lenses — each focuses on one domain.

| Skill | What it does |
|-------|-------------|
| `/security-reviewer` | Auth, RLS, user scoping, PII handling, prompt injection, secrets in code |
| `/api-auditor` | Auth levels, Zod validation, response shapes, rate limiting, telemetry |
| `/frontend-auditor` | AbortController lifecycle, loading/error states, fetch patterns |
| `/prompt-auditor` | LLM guardrails, injection protection, model selection, cache-first patterns, spending caps |
| `/data-modeler` | Schema audit, RLS policies, FK integrity, migration safety, Zod alignment |
| `/performance-auditor` | N+1 queries, sequential awaits, React re-renders, cache gaps |
| `/a11y-auditor` | WCAG 2.1 AA, keyboard navigation, ARIA, contrast ratios, touch targets |
| `/cost-guardian` | LLM cost tracking, spending analysis, model routing optimization |

### Development (`development/`) — 14 skills

Higher-level engineering skills for building, fixing, and analyzing code.

| Skill | What it does |
|-------|-------------|
| `/architect` | System design review, ADR compliance, pattern consistency |
| `/bug-analyzer` | Root cause analysis with data verification |
| `/deep-reviewer` | Two-pass plan + code review with veto power |
| `/full-audit` | Comprehensive codebase health check across all dimensions |
| `/sprint-planner` | Priority analysis, dependency mapping, sprint decomposition |
| `/test-writer` | Unit, integration, E2E test generation following project standards |
| `/code-architect` | Architecture-level code design — module boundaries, dependency graphs, interface contracts |
| `/code-simplifier` | Identifies over-engineered code and simplifies without losing functionality |
| `/deep-fix` | Systematic root-cause-driven bug resolution — traces the full causal chain |
| `/fix-issue` | Issue triage and implementation — from GitHub issue to working PR |
| `/new-component` | Scaffolds a React component with types, tests, and accessibility |
| `/new-endpoint` | Scaffolds an API route with auth, validation, error handling, and tests |
| `/data-crawler` | Web scraping and data pipeline builder |
| `/prompt-optimizer` | Optimizes LLM prompts for cost, quality, and latency |
| `/metrics-planner` | Defines metrics, KPIs, and instrumentation plans |

### Quality (`quality/`) — 6 skills

Testing, review, and diagnostic tools.

| Skill | What it does |
|-------|-------------|
| `/peer-review` | External-style code review — pretend you're seeing this codebase for the first time |
| `/playbook-auditor` | Audits runbooks and operational playbooks for gaps, stale info, and missing scenarios |
| `/root-cause-triage` | Rapid triage for production issues — classify, identify root cause, recommend action |
| `/run-e2e` | E2E test execution with environment setup and failure analysis |
| `/test-session` | Interactive test session — explores the app like a QA tester looking for bugs |
| `/issue-intelligence` | Analyzes GitHub issues for patterns, duplicates, and priority recommendations |

### UX & Design (`ux-design/`) — 5 skills

User experience, design systems, and content strategy.

| Skill | What it does |
|-------|-------------|
| `/designer` | UI/UX design review — layout, hierarchy, spacing, color, typography, interaction patterns |
| `/heuristic-eval` | Nielsen's 10 usability heuristics evaluation of any interface |
| `/ux-ia-auditor` | Information architecture audit — navigation, labeling, findability, mental models |
| `/ux-writer` | UX writing review — microcopy, error messages, onboarding text, CTAs, tone consistency |
| `/error-ux-auditor` | Error state UX audit — are errors helpful, recoverable, and human-readable? |

### Agent Coordination (`agent-coordination/`) — 2 skills

Multi-agent orchestration patterns for running parallel agent workflows.

| Skill | What it does |
|-------|-------------|
| `/swarm-watchdog` | Monitors swarm agents for hangs, stalls, and missed state transitions. Pull-based polling with configurable thresholds. |

Additional coordination skills available in production but too project-specific for this repo:

| Skill | What it does | Why not included |
|-------|-------------|-----------------|
| `/sprint-pm` | Full sprint PM orchestration — groups issues, spawns agents per group, manages gates | Contains project-specific database refs and role names |
| `/swarm-fix` | Multi-agent bug resolution pipeline (5 agents, 2 approval gates, parallel worktrees) | Contains project-specific tokens and infrastructure refs |
| `/code-executor` | Implementation agent — follows approved spec exactly, no improvisation | Contains project-specific database and staging config |

## Design Principles

All skills follow a common output contract:

**Plan → Implementation Files → Security Review → Tests → Telemetry → Open Questions**

This ensures consistent, thorough output regardless of which skill is invoked. Every skill:
- Cites specific file paths and line numbers
- Rates findings by severity (P0/P1/P2)
- Suggests concrete fixes, not just problems
- Considers security implications
- Flags open questions for human decision
