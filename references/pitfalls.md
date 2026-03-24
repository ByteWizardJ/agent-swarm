# Agent Swarm — Pitfalls & Lessons

Extracted from production use. Read when debugging failures.

## 🔴 Critical

### Codex model compatibility
- Not all Codex model variants support every auth method (e.g., ChatGPT account auth vs API key)
- If Codex exits immediately, check stderr — it's likely a model/auth mismatch
- The `-codex` suffix models may behave differently from their non-suffixed counterparts for review tasks
- Always verify your chosen model works with your auth setup before relying on it in automation

### openclaw message send parameter
- Correct: `openclaw message send --channel <channel> --target <target> -m "message"` or `--message`
- Wrong: `--text` (parameter doesn't exist, silently fails or errors)

### Error swallowing via `2>/dev/null`
- Several scripts pipe stderr to /dev/null
- This hides auth failures, model errors, network issues
- When debugging: temporarily remove `2>/dev/null` to see actual errors

### Codex interactive mode hangs
- `codex "$PROMPT"` (without `exec`) enters interactive mode after completion
- tmux session never exits → watchdog thinks agent is still running
- Always use `codex exec "$PROMPT"`

### Claude CLI output loss
- `--output-format text` only outputs final turn's plain text
- All analysis from tool-use turns is lost
- Fix: `--output-format json` + extract `result` field from JSON
- Prompt must request "write full report in final message"

### Review script silent failure
- `set -e` causes immediate exit on error, but no marker file
- check-agents.sh sees status as "REVIEW IN PROGRESS" forever
- Fix: ERR trap writes `/tmp/review-error-<branch>.txt`
- Timeout detection: 25 min with no process alive → reset

## 🟡 Medium

### Review-fix loop must be closed
- Initial version stopped at REQUEST_CHANGES with no auto-fix
- fix-from-review.sh generates fix prompt from review issues → restarts agent
- Max 3 review rounds before requiring operator intervention

### TASK.md must include file boundaries
- Without explicit scope, agent may modify src/ files during test-only tasks
- Template: "✅ Modify: ..., 🚫 Do NOT modify: ..."

### TASK.md must include build commands
- Without `--skip test script --match-path`, agent runs full compilation (~9 min)
- Always include targeted build + test commands

### Confirmed design decisions in review prompt
- Without listing confirmed decisions, reviewers report them as vulnerabilities
- Reduces false positives significantly

### PR strategy: merge over split
- 3 chained PRs caused massive rebase/conflict overhead
- Prefer single large PR for related changes, one review pass

### Human review is not optional
- Dual AI review passed code with `amountOutMin=0` (sandwich attack vector)
- AI excels at structural issues, misses business-logic attack vectors
- Human review remains the final gate

## 🟢 General

### Notification reliability
- `openclaw system event` is unreliable for delivery
- Primary: `openclaw message send --channel <channel> --target <target>`
- Fallback: system event

### Agent completion notification
- spawn-agent.sh appends notification commands to run-agent.sh
- Also auto-triggers check-agents.sh after completion
- Watchdog provides backup monitoring

### Registry state file
- `agent-registry.json` is the source of truth for agent status
- active-tasks.json is the cross-session view
- Both must be updated at each state transition
