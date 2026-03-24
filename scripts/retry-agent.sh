#!/bin/bash
# retry-agent.sh — Restart an agent that exited abnormally
#
# Usage: retry-agent.sh <task-id>
#
# Reads task info from registry, restarts agent in the same worktree.
# TASK.md already exists in worktree, reuses it directly.

set -euo pipefail

TASK_ID="${1:?Usage: retry-agent.sh <task-id>}"
WORKSPACE="${AGENT_SWARM_WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$WORKSPACE/scripts/agent-registry.json"

# Read task info
TASK_INFO=$(python3 -c "
import json
with open('${REGISTRY}') as f:
    reg = json.load(f)
t = reg['tasks']['${TASK_ID}']
print(f\"{t['worktree']}|{t['retries']}|{t['maxRetries']}|{t['agent']}\")
")

WORKTREE=$(echo "$TASK_INFO" | cut -d'|' -f1)
RETRIES=$(echo "$TASK_INFO" | cut -d'|' -f2)
MAX_RETRIES=$(echo "$TASK_INFO" | cut -d'|' -f3)
AGENT=$(echo "$TASK_INFO" | cut -d'|' -f4)

TMUX_SESSION="agent-${TASK_ID//\//-}"
NEW_RETRIES=$((RETRIES + 1))

# --- Resolve task workspace directory ---
TASKS_DIR="$WORKSPACE/tasks"
if [[ "$TASK_ID" == */* ]]; then
  _TASK_NAME="${TASK_ID%%/*}"
  _SUBTASK_NAME="${TASK_ID#*/}"
  TASK_WORKDIR="${TASKS_DIR}/${_TASK_NAME}/subtasks/${_SUBTASK_NAME}"
else
  TASK_WORKDIR="${TASKS_DIR}/${TASK_ID}"
fi

if [ "$NEW_RETRIES" -gt "$MAX_RETRIES" ]; then
  echo "ERROR: Max retries ($MAX_RETRIES) exceeded for task $TASK_ID"
  exit 1
fi

# Kill leftover session
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Check TASK.md exists in task workspace
if [ ! -f "$TASK_WORKDIR/TASK.md" ]; then
  echo "ERROR: No TASK.md in $TASK_WORKDIR"
  exit 1
fi

# Regenerate runner in task workspace
RUNNER="${TASK_WORKDIR}/run-agent.sh"

cat > "$RUNNER" << 'RUNNER_HEADER'
#!/bin/bash
RUNNER_HEADER

cat >> "$RUNNER" << RUNNER_BODY
cd "${WORKTREE}"

PROMPT="\$(cat "${TASK_WORKDIR}/TASK.md")

NOTE: This is retry attempt ${NEW_RETRIES}. Previous attempt exited without completing.
Check git status and git diff to see what's already done. Continue from where it left off.
When completely finished, commit all changes with a descriptive commit message."

RUNNER_BODY

cat >> "$RUNNER" << 'RUNNER_CODEX'
codex exec \
  --dangerously-bypass-approvals-and-sandbox \
  -m ${AGENT_SWARM_CODEX_MODEL:-gpt-5.3-codex} \
  -c model_reasoning_effort=high \
  "$PROMPT"
RUNNER_CODEX

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
if [ \$EXIT_CODE -eq 0 ]; then
  notify "✅ Agent ${TASK_ID} finished (retry ${NEW_RETRIES})"
else
  notify "⚠️ Agent ${TASK_ID} EXITED on retry ${NEW_RETRIES} (code \$EXIT_CODE)"
fi
RUNNER_FOOTER

chmod +x "$RUNNER"

# Launch
tmux new-session -d -s "$TMUX_SESSION" "bash ${RUNNER}; exec bash"

# Update registry
python3 -c "
import json, time
with open('${REGISTRY}') as f:
    reg = json.load(f)
reg['tasks']['${TASK_ID}']['status'] = 'retry'
reg['tasks']['${TASK_ID}']['retries'] = ${NEW_RETRIES}
reg['tasks']['${TASK_ID}']['lastCheckedAt'] = int(time.time())
with open('${REGISTRY}', 'w') as f:
    json.dump(reg, f, indent=2)
"

# Sync active-tasks.json
python3 "${SCRIPTS_DIR}/active-tasks.py" status \
  --id "${TASK_ID}" --status active \
  --context "Retry attempt ${NEW_RETRIES}/${MAX_RETRIES}" \
  2>/dev/null || true

echo "Agent ${TASK_ID} retried (attempt ${NEW_RETRIES}/${MAX_RETRIES})"
