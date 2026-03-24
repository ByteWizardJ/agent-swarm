---
name: agent-swarm
description: "Orchestrate coding agents (Codex/Claude) for multi-step development workflows: spawn task agents, monitor progress, dual-AI PR review, auto-fix from review, retry on failure, cleanup. Use when: (1) spawning Codex/Claude agents for coding tasks, (2) reviewing PRs with dual AI auditors, (3) fixing code from review feedback, (4) checking agent status, (5) cleaning up completed tasks. NOT for: simple one-liner edits (just edit), reading code (use read tool), thread-bound ACP harness requests (use sessions_spawn with runtime:acp)."
---

# Agent Swarm

Orchestrate Codex/Claude coding agents with automated review, fix, and retry loops.

## Configuration

- `AGENT_SWARM_WORKSPACE` — Override the workspace directory used for registry, task state, and task folders. Default: auto-detect via `OPENCLAW_WORKSPACE`, then `~/.openclaw/workspace`.
- `AGENT_SWARM_NOTIFY_CHANNEL` — Notification channel for `openclaw message send` (for example: `telegram`, `discord`, `slack`).
- `AGENT_SWARM_NOTIFY_TARGET` — Notification target for the selected channel (for example: chat ID or channel ID).
- `AGENT_SWARM_CODEX_MODEL` — Model for task execution (default: `gpt-5.3-codex`).
- `AGENT_SWARM_REVIEW_MODEL` — Model for Codex-based PR reviews (default: `gpt-5.4`).
- `AGENT_SWARM_CLAUDE_MODEL` — Claude model for security audit reviews (default: `claude-opus-4-6`).
- `AGENT_SWARM_SONNET_MODEL` — Claude model for comment consistency reviews (default: `claude-sonnet-4-6`).

## Prerequisites

- `codex` CLI (for task execution and reviews)
- `claude` CLI (for reviews)
- `gh` CLI (authenticated, for PR creation/commenting)
- `tmux` (agent sessions run in tmux)
- `python3` (registry/task management)

## Quick Reference

| Script | Purpose |
|--------|---------|
| `spawn-agent.sh` | Launch a coding agent in tmux |
| `review-pr.sh` | Dual-AI PR review (Claude + Codex) |
| `check-agents.sh` | Check all agent statuses, auto-trigger review/retry |
| `fix-from-review.sh` | Generate fix prompt from review → restart agent |
| `retry-agent.sh` | Retry a failed agent in the same worktree |
| `agent-watchdog.sh` | Background monitor, auto-retry on crash |
| `active-tasks.py` | Manage active-tasks.json (upsert/status/blocker/attempt) |
| `cleanup.sh` | Remove worktrees + registry entries for done/failed tasks |

All scripts are in this skill's `scripts/` directory. Resolve paths against this directory.

## State Files (external to skill)

- **Agent Registry**: `$WORKSPACE/scripts/agent-registry.json` — tracks all agent runs
- **Active Tasks**: `$WORKSPACE/memory/active-tasks.json` — cross-session task tracking
- **Task Directories**: `$WORKSPACE/tasks/<task-id>/` — per-task persistent storage

## Task Directory Structure (Lean)

Principle: store only the documents required for agent-to-agent handoff, not process artifacts.

```text
$WORKSPACE/tasks/
  my-project-xxx/
  ├── TASK.md                      # top-level task overview, links, and subtask map
  └── subtasks/
      ├── 01-backend/
      │   ├── TASK.md              # agent input prompt (overwritten in place)
      │   ├── PROJECT_CONTEXT.md   # project context copied from the repo
      │   ├── run-agent.sh         # tmux entrypoint (auto-generated)
      │   ├── audit-codex.md       # temporary review output from Codex
      │   └── audit-claude.md      # temporary review output from Claude
      ├── 02-backend/
      │   └── ...
      └── 03-frontend/
          └── ...
```

- **Top-level `TASK.md`** — overall task description: objective, subtask breakdown, and the repo/branch for each subtask. Created by the main session when the task starts.
- **Subtask `TASK.md`** — the execution prompt for a specific agent. Written by `spawn-agent.sh`.

### Auto-generated (managed by scripts, overwritten in place)

- `TASK.md` — the agent input prompt, later re-read by `fix-from-review.sh`
- `PROJECT_CONTEXT.md` — project context copied from the repo root
- `run-agent.sh` — tmux entrypoint
- `audit-*.md` — temporary review output

### Create only after operator confirmation

- Design docs — maintain a single in-place file, no versioned copies
- Any other additional `.md` files

### No longer auto-generated

- `README.md` (not consumed by agents)
- Prompt archives (`spawn-01/02`)
- Review report archives (already preserved in PR comments)

### Task ID Format

Scripts use compound task ID: `<task>/<subtask>` (for example: `my-project/01-backend`).

## Workflow: Standard Path

```text
1. Prepare    -> Create worktree + write TASK.md
2. Spawn      -> spawn-agent.sh launches Codex in tmux
3. Monitor    -> agent-watchdog.sh auto-monitors (or manual check-agents.sh)
4. Review     -> check-agents.sh auto-triggers review-pr.sh on completion
5. Fix loop   -> REQUEST_CHANGES -> fix-from-review.sh -> re-review (max 3 rounds)
6. Done       -> APPROVE + CI pass -> notify the operator
7. Cleanup    -> cleanup.sh removes worktrees + registry entries
```

### Step 1: Prepare Worktree + Prompt

```bash
# Create worktree from base branch
cd /path/to/repo
git worktree add -b feature/my-task /tmp/my-task base-branch

# Write task prompt using the TASK.md v2 template
cp <SKILL_DIR>/templates/TASK.md /tmp/my-task-prompt.md
# Edit the template: fill in objective, constraints, build commands, file boundaries

# Copy the appropriate REVIEW_CONTEXT template to the worktree
cp <SKILL_DIR>/templates/REVIEW_CONTEXT.md /tmp/my-task/REVIEW_CONTEXT.md
# Edit it: set project_type, diff_scope, architecture context, confirmed decisions
```

**TASK.md v2 template** (`templates/TASK.md`): includes reference implementation snippets, security/design constraints, confirmed decisions, build instructions, and file boundaries. Higher-quality prompts reduce review rounds significantly.

**REVIEW_CONTEXT.md**: placed in the worktree root, read by `review-pr.sh` to determine project type and audit methodology. Templates available for different project types:
- `templates/REVIEW_CONTEXT.md` — generic
- `templates/REVIEW_CONTEXT-backend.md` — backend projects
- `templates/REVIEW_CONTEXT-frontend.md` — frontend projects

**For multi-layer projects** (contract → backend → frontend), also copy `templates/CROSS_LAYER_INTERFACE.md` to your project docs. Each layer fills its section after completion; downstream developers read before starting.

**Safety gate**: before spawning, output the full TASK.md content and spawn command for operator review. This allows catching issues before the agent runs.

**TASK.md best practices:**

- Include explicit file boundaries (what to touch, what not to)
- Include build/test commands (avoid full compilation)
- Paste reference implementation snippets directly (not just file paths)
- List confirmed design decisions (reduces review false positives)
- `spawn-agent.sh` auto-appends the "commit all changes" instruction

### Step 2: Spawn Agent

```bash
bash <SKILL_DIR>/scripts/spawn-agent.sh <task-id> <worktree-path> <prompt-file> <base-branch>
```

What `spawn-agent.sh` does:

1. Creates task directory `tasks/<task>/subtasks/<subtask>/`
2. Copies `TASK.md` + `PROJECT_CONTEXT.md` to the task directory
3. Generates `run-agent.sh` in the task directory
4. Launches Codex in tmux session `agent-<task-id>` (the agent runs in the worktree and reads the prompt from the task directory)
5. Registers in `agent-registry.json` + `active-tasks.json`
6. Starts the background watchdog

### Step 3: Monitor

**Automatic** (preferred): `agent-watchdog.sh` runs in the background and checks every 5 minutes.

**Manual check:**

```bash
bash <SKILL_DIR>/scripts/check-agents.sh
```

**tmux direct inspection:**

```bash
tmux attach -t agent-<task-id>    # view live output
tmux capture-pane -t agent-<task-id> -p | tail -50  # peek without attaching
```

### Step 4-5: Review + Fix Loop

Triggered automatically by `check-agents.sh` when the agent completes (has new commits).

**Manual review trigger:**

```bash
bash <SKILL_DIR>/scripts/review-pr.sh <worktree-path> <base-branch>
```

Review flow (4-lane parallel, reads `REVIEW_CONTEXT.md` from worktree for project-specific audit methodology):

1. Push branch + create PR
2. Launch 4 reviewers in parallel tmux sessions:
   - Lane 1: Security audit (Claude Opus 4.6)
   - Lane 2: Security audit (Codex GPT-5.4) — same prompt, cross-validation
   - Lane 3: Standards + Logic compliance (Codex GPT-5.4) — checks coding standards, design intent, functional correctness, test coverage
   - Lane 4: Comment consistency (Sonnet 4.6) — verifies comments match implementation
3. Wait up to 20 minutes for all to complete
4. Aggregate results -> post as PR comment (no scoring/filtering, direct output)
5. If `REQUEST_CHANGES` -> auto-spawn fix agent (max 3 rounds)
6. If `APPROVE` -> check CI -> mark done

### Step 6: Cleanup

```bash
bash <SKILL_DIR>/scripts/cleanup.sh
bash <SKILL_DIR>/scripts/cleanup.sh --dry-run
```

## Workflow: Review-Only Path

When code is already written (by a developer or by an agent outside this workflow):

```text
1. Ensure changes are committed in the worktree
2. Skip spawn -> go directly to review-pr.sh
3. Review + fix loop proceeds as normal
```

The main session should not be the default place for direct code writing. This path is for code already produced manually or by another workflow.

## Model Selection Rules

| Role | Default Model | Notes |
|------|---------------|-------|
| Task execution | Codex (latest) | Configured in `spawn-agent.sh` |
| PR review Lane 1 | Claude (Opus-class) | Security audit; uses `--dangerously-skip-permissions` |
| PR review Lane 2 | Codex/GPT (reasoning-class) | Security cross-validation |
| PR review Lane 3 | Codex/GPT (reasoning-class) | Standards + logic compliance |
| PR review Lane 4 | Claude (Sonnet-class) | Comment consistency |
| Fix from review | Codex (latest) | Same as task execution |

Models are configured at the top of each script. Adjust to match your available models and auth setup.

## PROJECT_CONTEXT.md

Each task directory should include a `PROJECT_CONTEXT.md` describing the target project. This file lives in the task workspace (not in the project repo itself) to avoid polluting the codebase.

Contents:

- Architecture overview, tech stack
- `project_type: solidity|backend|frontend` (controls review audit methodology)
- `diff_scope: src/` (controls which files get reviewed)
- Known pitfalls, security model

Generate a template by scanning a project:

```bash
bash <SKILL_DIR>/scripts/init-project-context.sh /path/to/repo
```

This auto-detects project type, diff scope, and directory structure, then writes a `PROJECT_CONTEXT.md` template. Move it into your task directory before spawning agents. `spawn-agent.sh` will copy it from the task workspace into the agent's working context.

## Notification

If `AGENT_SWARM_NOTIFY_CHANNEL` and `AGENT_SWARM_NOTIFY_TARGET` are both set, scripts notify via:

```bash
openclaw message send --channel "$AGENT_SWARM_NOTIFY_CHANNEL" --target "$AGENT_SWARM_NOTIFY_TARGET" -m "message"
```

Otherwise they fall back to:

```bash
openclaw system event --text "message" --mode now
```

⚠️ The message-send parameter is `-m/--message`, not `--text`.

## Retry Logic

| Level | Max Retries | Trigger |
|-------|-------------|---------|
| Agent execution | 3 | No new commits when tmux exits |
| Review rounds | 3 | `REQUEST_CHANGES` from review |
| Stuck detection | — | >60 min without new commit -> force kill + retry |

## Known Pitfalls

See `references/pitfalls.md` for the full list of lessons learned from production use.

Key ones:

1. **`gpt-5.4-codex` doesn't work** with ChatGPT auth -> use `gpt-5.4` for reviews
2. **`2>/dev/null` swallows errors** -> remove when debugging
3. **`codex` (no `exec`)** hangs in interactive mode -> always use `codex exec`
4. **Claude `-p` loses tool-use output** -> use `--output-format json` + extract `result`
5. **Review script silent failure** -> ERR trap writes an error marker file
6. **Operator review still needed** -> AI misses business-logic attacks (for example, `amountOutMin=0`)
