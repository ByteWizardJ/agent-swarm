#!/bin/bash
# spawn-agent.sh — Single entry point for spawning coding agents
#
# Usage: spawn-agent.sh <task-id> <worktree-path> <prompt-file> <base-branch>
#
# Task execution agent is always Codex
# Override models via env: AGENT_SWARM_CODEX_MODEL, AGENT_SWARM_CLAUDE_MODEL
# Review is handled by review-pr.sh (Claude Opus + Codex dual AI)
#
# Prerequisites:
#   - Worktree is created and ready (with build cache synced)
#   - Prompt file is written
#
# What it does:
#   1. Generates run-agent.sh (avoids nested quoting issues)
#   2. Launches agent in tmux
#   3. Registers task in agent-registry.json
#   4. Notifies on completion/failure via openclaw system event

set -euo pipefail

TASK_ID="${1:?Usage: spawn-agent.sh <task-id> <worktree-path> <prompt-file> <base-branch>}"
WORKTREE="${2:?Missing worktree path}"
PROMPT_FILE="${3:?Missing prompt file}"
BASE_BRANCH="${4:?Missing base branch}"
AGENT="codex"  # Task execution always uses Codex
WORKSPACE="${AGENT_SWARM_WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$WORKSPACE/scripts"
TASKS_DIR="$WORKSPACE/tasks"
REGISTRY="${DATA_DIR}/agent-registry.json"

# --- Parse compound task ID: <task>/<subtask> or plain <task-id> ---
if [[ "$TASK_ID" == */* ]]; then
  TASK_NAME="${TASK_ID%%/*}"
  SUBTASK_NAME="${TASK_ID#*/}"
  TMUX_SESSION="agent-${TASK_NAME}-${SUBTASK_NAME}"
else
  TASK_NAME="$TASK_ID"
  SUBTASK_NAME=""
  TMUX_SESSION="agent-${TASK_ID//\//-}"
fi

SAFE_TASK_ID="${TASK_ID//\//-}"

# --- Task workspace: tasks/<task>/subtasks/<subtask>/ (minimal: only TASK.md + PROJECT_CONTEXT.md) ---
if [ -n "$SUBTASK_NAME" ]; then
  TASK_WORKDIR="${TASKS_DIR}/${TASK_NAME}/subtasks/${SUBTASK_NAME}"
else
  TASK_WORKDIR="${TASKS_DIR}/${TASK_NAME}"
fi
mkdir -p "$TASK_WORKDIR"

# --- Validate ---
if [ ! -d "$WORKTREE" ]; then
  echo "ERROR: Worktree not found: $WORKTREE"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "ERROR: tmux session $TMUX_SESSION already exists. Kill it first."
  exit 1
fi

# --- Copy prompt to task workspace (overwrite in place, no versioning) ---
cp "$PROMPT_FILE" "$TASK_WORKDIR/TASK.md"

# --- Copy PROJECT_CONTEXT.md to task workspace ---
REPO_ROOT=$(cd "$WORKTREE" && git rev-parse --show-toplevel 2>/dev/null || echo "$WORKTREE")
PROJECT_CTX=""
for ctx_candidate in "${WORKTREE}/PROJECT_CONTEXT.md" "${REPO_ROOT}/PROJECT_CONTEXT.md"; do
  if [ -f "$ctx_candidate" ]; then
    cp "$ctx_candidate" "$TASK_WORKDIR/PROJECT_CONTEXT.md"
    PROJECT_CTX="$TASK_WORKDIR/PROJECT_CONTEXT.md"
    echo "Copied PROJECT_CONTEXT.md to task workspace"
    break
  fi
done

if [ -z "$PROJECT_CTX" ]; then
  echo "⚠️  WARNING: No PROJECT_CONTEXT.md found in worktree or repo root."
  echo "   Generate one: bash ${SCRIPTS_DIR}/init-project-context.sh ${REPO_ROOT}"
fi

# --- Inject PROJECT_CONTEXT.md reference into TASK.md ---
if [ -n "$PROJECT_CTX" ]; then
  TASK_CONTENT=$(cat "$TASK_WORKDIR/TASK.md")
  cat > "$TASK_WORKDIR/TASK.md" << TASK_INJECT
IMPORTANT: Read ${TASK_WORKDIR}/PROJECT_CONTEXT.md first for project background, architecture, known pitfalls, and security model.

${TASK_CONTENT}
TASK_INJECT
  echo "Injected PROJECT_CONTEXT.md reference into TASK.md"
fi

# --- Generate runner script in task workspace ---
RUNNER="${TASK_WORKDIR}/run-agent.sh"

cat > "$RUNNER" << 'RUNNER_HEADER'
#!/bin/bash
RUNNER_HEADER

cat >> "$RUNNER" << RUNNER_BODY
cd "${WORKTREE}"

PROMPT="\$(cat "${TASK_WORKDIR}/TASK.md")

When completely finished, commit all changes with a descriptive commit message."

RUNNER_BODY

if [ "$AGENT" = "codex" ]; then
  cat >> "$RUNNER" << 'RUNNER_CODEX'
codex exec \
  --dangerously-bypass-approvals-and-sandbox \
  -m ${AGENT_SWARM_CODEX_MODEL:-gpt-5.3-codex} \
  -c model_reasoning_effort=high \
  "$PROMPT"
RUNNER_CODEX
elif [ "$AGENT" = "claude" ]; then
  cat >> "$RUNNER" << 'RUNNER_CLAUDE'
claude --model ${AGENT_SWARM_CLAUDE_MODEL:-claude-opus-4-6} -p "$PROMPT"
RUNNER_CLAUDE
else
  echo "ERROR: Unknown agent: $AGENT"
  exit 1
fi

cat >> "$RUNNER" << RUNNER_FOOTER

EXIT_CODE=\$?
notify() {
  local msg="\$1"
  local channel="\${AGENT_SWARM_NOTIFY_CHANNEL:-}"
  local target="\${AGENT_SWARM_NOTIFY_TARGET:-}"
  if [[ -n "\$target" && -n "\$channel" ]]; then
    openclaw message send --channel "\$channel" --target "\$target" -m "\$msg" 2>/dev/null \
      || openclaw system event --text "\$msg" --mode now 2>/dev/null
  else
    openclaw system event --text "\$msg" --mode now 2>/dev/null
  fi
}

# --- Update PROJECT_CONTEXT.md handoff ---
if [ -f "${TASK_WORKDIR}/PROJECT_CONTEXT.md" ]; then
  TASK_TITLE=\$(head -5 "${TASK_WORKDIR}/TASK.md" | grep -v '^IMPORTANT:' | grep -v '^$' | head -1 | sed 's/^#* *//')
  HANDOFF_TIME=\$(date '+%Y-%m-%d %H:%M')
  python3 -c "
import re
ctx_path = '${TASK_WORKDIR}/PROJECT_CONTEXT.md'
with open(ctx_path) as f:
    content = f.read()
handoff = '''<!-- handoff:start -->
## Last Handoff
- Agent: Codex (${TASK_ID})
- Time: \${HANDOFF_TIME}
- Task: \${TASK_TITLE}
- Result: exit code \${EXIT_CODE}
- Next: check agent output and review
<!-- handoff:end -->'''
content = re.sub(
    r'<!-- handoff:start -->.*?<!-- handoff:end -->',
    handoff, content, flags=re.DOTALL)
with open(ctx_path, 'w') as f:
    f.write(content)
print('Handoff updated in PROJECT_CONTEXT.md')
" 2>/dev/null || true
fi

if [ \$EXIT_CODE -eq 0 ]; then
  notify "✅ Agent ${TASK_ID} finished successfully"
else
  notify "⚠️ Agent ${TASK_ID} EXITED with code \$EXIT_CODE"
fi

# Auto-trigger status check + review flow
sleep 3
bash "${SCRIPTS_DIR}/check-agents.sh" > "/tmp/check-${SAFE_TASK_ID}.log" 2>&1 || true
RUNNER_FOOTER

chmod +x "$RUNNER"

# --- Launch in tmux ---
tmux new-session -d -s "$TMUX_SESSION" "bash ${RUNNER}; exec bash"
echo "Agent launched: tmux session=$TMUX_SESSION, worktree=$WORKTREE"

# --- Register task ---
TIMESTAMP=$(date +%s)
BRANCH=$(cd "$WORKTREE" && git branch --show-current 2>/dev/null || echo "unknown")
BASE_COMMIT=$(cd "$WORKTREE" && git rev-parse HEAD 2>/dev/null || echo "")

python3 -c "
import json
reg_path = '${REGISTRY}'
with open(reg_path) as f:
    reg = json.load(f)
existing = reg['tasks'].get('${TASK_ID}', {})
reg['tasks']['${TASK_ID}'] = {
    'status': 'running',
    'agent': '${AGENT}',
    'tmuxSession': '${TMUX_SESSION}',
    'worktree': '${WORKTREE}',
    'branch': '${BRANCH}',
    'retries': 0,
    'maxRetries': 3,
    'reviewRetries': existing.get('reviewRetries', 0),
    'maxReviewRetries': 3,
    'baseBranch': '${BASE_BRANCH}',
    'baseCommit': '${BASE_COMMIT}',
    'startedAt': ${TIMESTAMP},
    'lastCheckedAt': ${TIMESTAMP}
}
with open(reg_path, 'w') as f:
    json.dump(reg, f, indent=2)
print('Task registered: ${TASK_ID}')
"

# --- Sync to active-tasks.json ---
TASK_TITLE=$(head -5 "$TASK_WORKDIR/TASK.md" 2>/dev/null | grep -v '^IMPORTANT:' | grep -v '^$' | head -1 | sed 's/^#* *//')
python3 "${SCRIPTS_DIR}/active-tasks.py" upsert \
  --id "${TASK_ID}" \
  --title "${TASK_TITLE:-${TASK_ID}}" \
  --project "$(basename "$(cd "$WORKTREE" && git rev-parse --show-toplevel 2>/dev/null || echo "$WORKTREE")")" \
  --context "Agent ${AGENT} running in tmux ${TMUX_SESSION}" \
  --next "wait for agent completion" \
  --owner "${AGENT}" \
  --files "${WORKTREE}" \
  2>/dev/null || true

# --- Start background watchdog (zero-token, shell-only monitoring) ---
nohup bash "${SCRIPTS_DIR}/agent-watchdog.sh" "${TASK_ID}" 300 \
    >> "/tmp/agent-watchdog-${SAFE_TASK_ID}.log" 2>&1 &
WATCHDOG_PID=$!
echo "Watchdog started: pid=${WATCHDOG_PID}, log=/tmp/agent-watchdog-${SAFE_TASK_ID}.log"
