#!/bin/bash
# cleanup.sh — Clean up worktrees and registry entries for completed/failed tasks
#
# Usage: cleanup.sh [--dry-run]

set -euo pipefail

WORKSPACE="${AGENT_SWARM_WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"
REGISTRY="$WORKSPACE/scripts/agent-registry.json"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

if [ ! -f "$REGISTRY" ]; then
  echo "No registry found."
  exit 0
fi

TASKS=$(python3 -c "
import json
with open('${REGISTRY}') as f:
    reg = json.load(f)
for tid, t in reg['tasks'].items():
    if t['status'] in ('done', 'failed'):
        print(f\"{tid}|{t['worktree']}|{t.get('branch','')}|{t['status']}\")
" 2>/dev/null)

if [ -z "$TASKS" ]; then
  echo "No tasks to clean up."
  exit 0
fi

echo "$TASKS" | while IFS='|' read -r TASK_ID WORKTREE BRANCH STATUS; do
  echo "Cleaning: ${TASK_ID} (${STATUS})"

  if $DRY_RUN; then
    echo "  [dry-run] Would remove worktree: ${WORKTREE}"
    echo "  [dry-run] Would kill tmux: agent-${TASK_ID}"
    echo "  [dry-run] Would remove from registry"
    continue
  fi

  # Kill tmux session (if leftover)
  tmux kill-session -t "agent-${TASK_ID}" 2>/dev/null || true

  # Remove worktree (prefer git worktree remove, fallback to trash, last resort rm)
  if [ -d "$WORKTREE" ]; then
    REPO_DIR=$(cd "$WORKTREE" && git rev-parse --git-common-dir 2>/dev/null | sed 's|/\.git$||' || echo "")
    if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR" ]; then
      cd "$REPO_DIR"
      git worktree remove "$WORKTREE" --force 2>/dev/null \
        || trash "$WORKTREE" 2>/dev/null \
        || rm -rf "$WORKTREE"
    else
      trash "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
    fi
    echo "  Removed worktree: ${WORKTREE}"
  fi

  # Clean temp files from task directory (keep TASK.md + PROJECT_CONTEXT.md)
  TASKS_DIR="$WORKSPACE/tasks"
  if [[ "$TASK_ID" == */* ]]; then
    _TASK_NAME="${TASK_ID%%/*}"
    _SUBTASK_NAME="${TASK_ID#*/}"
    TASK_WORKDIR="${TASKS_DIR}/${_TASK_NAME}/subtasks/${_SUBTASK_NAME}"
  else
    TASK_WORKDIR="${TASKS_DIR}/${TASK_ID}"
  fi
  if [ -d "$TASK_WORKDIR" ]; then
    rm -f "$TASK_WORKDIR/run-agent.sh" "$TASK_WORKDIR/audit-codex.md" "$TASK_WORKDIR/audit-claude.md"
    echo "  Cleaned temp files from task dir"
  fi

  # Remove from registry
  python3 -c "
import json
with open('${REGISTRY}') as f:
    reg = json.load(f)
del reg['tasks']['${TASK_ID}']
with open('${REGISTRY}', 'w') as f:
    json.dump(reg, f, indent=2)
"
  echo "  Removed from registry"
done

echo "Cleanup done."
