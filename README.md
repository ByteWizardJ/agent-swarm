# Agent Swarm

Orchestrate coding agents with automated review, fix, retry, and cleanup loops.

## Features

- Spawn task agents in isolated worktrees and tmux sessions
- Run a 4-lane PR review flow across security, standards, logic, and comment consistency
- Auto-generate fix prompts from review feedback
- Auto-retry crashed or stuck agents with watchdog monitoring
- Clean up completed or failed task workspaces and registry state

## Quick Start

### Prerequisites

- `codex`
- `claude`
- `gh`
- `tmux`
- `python3`
- `openclaw`

### Install

Install `agent-swarm` from ClawHub, or clone this repository into your local skills directory for development.

### Configuration

```bash
export AGENT_SWARM_WORKSPACE="${AGENT_SWARM_WORKSPACE:-$HOME/.openclaw/workspace}"
export AGENT_SWARM_NOTIFY_CHANNEL="telegram"       # or discord, slack, etc.
export AGENT_SWARM_NOTIFY_TARGET="<your-chat-id>"
```

`AGENT_SWARM_WORKSPACE` overrides the shared workspace path. `AGENT_SWARM_NOTIFY_CHANNEL` and `AGENT_SWARM_NOTIFY_TARGET` enable direct notifications. If the notification variables are unset, scripts fall back to `openclaw system event`.

See [SKILL.md](SKILL.md) for full workflow and usage details.

## License

Released under the MIT License. See [LICENSE](LICENSE).
