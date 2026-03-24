#!/bin/bash
# fix-from-review.sh — Generate fix prompt from review issues and restart Codex agent
#
# Usage: fix-from-review.sh <task-id> <worktree> <base-branch>
#
# Called automatically by check-agents.sh when review conclusion is REQUEST_CHANGES

set -euo pipefail

TASK_ID="${1:?Usage: fix-from-review.sh <task-id> <worktree> <base-branch>}"
WORKTREE="${2:?Missing worktree}"
BASE_BRANCH="${3:?Missing base branch}"
WORKSPACE="${AGENT_SWARM_WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$WORKSPACE/scripts/agent-registry.json"

cd "$WORKTREE"
BRANCH=$(git branch --show-current)
SAFE_BRANCH="${BRANCH//\//_}"

# --- Resolve task workspace directory ---
TASKS_DIR="$WORKSPACE/tasks"
if [[ "$TASK_ID" == */* ]]; then
  _TASK_NAME="${TASK_ID%%/*}"
  _SUBTASK_NAME="${TASK_ID#*/}"
  TASK_WORKDIR="${TASKS_DIR}/${_TASK_NAME}/subtasks/${_SUBTASK_NAME}"
else
  TASK_WORKDIR="${TASKS_DIR}/${TASK_ID}"
fi

# Get PR number
PR_NUM=$(gh pr list --head "$BRANCH" --json number -q '.[0].number' 2>/dev/null)
if [ -z "$PR_NUM" ]; then
  echo "ERROR: No PR found for branch $BRANCH"
  exit 1
fi

# Check if reviewRetries exceeded
REVIEW_RETRIES=$(python3 -c "
import json
with open('${REGISTRY}') as f:
    reg = json.load(f)
print(reg['tasks'].get('${TASK_ID}', {}).get('reviewRetries', 0))
" 2>/dev/null || echo "0")

MAX_REVIEW_RETRIES=3
if [ "$REVIEW_RETRIES" -ge "$MAX_REVIEW_RETRIES" ]; then
  echo "ERROR: Max review retries ($MAX_REVIEW_RETRIES) exceeded for task $TASK_ID"
  exit 1
fi

# Read review comments (prefer issues file, fallback to PR)
ISSUES_FILE="/tmp/review-issues-${SAFE_BRANCH}.txt"
if [ -f "$ISSUES_FILE" ] && [ -s "$ISSUES_FILE" ]; then
  ISSUES=$(cat "$ISSUES_FILE")
else
  ISSUES=$(gh pr view "$PR_NUM" --comments 2>/dev/null | grep -E "🔴|🟡" | head -30 || echo "See PR #${PR_NUM} for details")
fi

# Read full review context (latest comment)
REVIEW_CONTEXT=$(gh pr view "$PR_NUM" --comments 2>/dev/null | tail -300 || echo "")

# Read original TASK.md from task workspace (strip PROJECT_CONTEXT injection prefix)
ORIGINAL_TASK=$(cat "$TASK_WORKDIR/TASK.md" 2>/dev/null | sed '/^IMPORTANT: Read /d' | sed '/^$/N;/^\n$/d' || echo "")

NEW_RETRIES=$((REVIEW_RETRIES + 1))

# Read PROJECT_CONTEXT.md from task workspace
PROJECT_CTX_FILE="${TASK_WORKDIR}/PROJECT_CONTEXT.md"
PROJECT_CTX_INSTRUCTION=""
if [ -f "$PROJECT_CTX_FILE" ]; then
  PROJECT_CTX_INSTRUCTION="IMPORTANT: Read ${PROJECT_CTX_FILE} first for project background, architecture, known pitfalls, and code standards."
fi

# Detect project type from PROJECT_CONTEXT.md
FIX_ROLE="fix engineer"
if [ -f "$PROJECT_CTX_FILE" ]; then
  DETECTED_TYPE=$(grep '^project_type:' "$PROJECT_CTX_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ')
  case "$DETECTED_TYPE" in
    solidity) FIX_ROLE="Solidity fix engineer" ;;
    backend)  FIX_ROLE="backend fix engineer" ;;
    frontend) FIX_ROLE="frontend fix engineer" ;;
  esac
fi

# Build fix prompt (replace / in TASK_ID to avoid path issues)
SAFE_TASK_ID="${TASK_ID//\//-}"
FIX_PROMPT_FILE="/tmp/fix-prompt-${SAFE_TASK_ID}.md"
cat > "$FIX_PROMPT_FILE" << PROMPT_EOF
${PROJECT_CTX_INSTRUCTION}

You are a ${FIX_ROLE}. This is fix attempt #${NEW_RETRIES}.
Based on AI Code Review feedback, fix the following security issues.

## Original Task
${ORIGINAL_TASK}

## Key Issues Found in Review
${ISSUES}

## Full Review Context
${REVIEW_CONTEXT}

## Fix Requirements
1. Must fix all 🔴 Critical issues
2. Fix high-risk 🟡 Warning issues (prioritize access control, reentrancy, CEI violations)
3. 🟢 Info can be ignored
4. Do not break existing tests
5. After fixing, run the build/test commands from the original task or PROJECT_CONTEXT.md
PROMPT_EOF

echo "Fix prompt written: $FIX_PROMPT_FILE"

# --- Fix prompt archiving removed (lean state rule: no auto doc generation) ---

# Update registry: reset to running, increment reviewRetries
python3 -c "
import json, time
with open('${REGISTRY}') as f:
    reg = json.load(f)
t = reg['tasks']['${TASK_ID}']
t['status'] = 'running'
t['reviewRetries'] = ${NEW_RETRIES}
t['retries'] = 0
t['lastCheckedAt'] = int(time.time())
with open('${REGISTRY}', 'w') as f:
    json.dump(reg, f, indent=2)
print('Registry updated: reviewRetries=${NEW_RETRIES}')
"

# Clean old review result files
rm -f "/tmp/review-result-${SAFE_BRANCH}.txt"
rm -f "/tmp/review-${SAFE_TASK_ID}.log"

# Spawn fix agent
bash "${SCRIPTS_DIR}/spawn-agent.sh" \
  "$TASK_ID" \
  "$WORKTREE" \
  "$FIX_PROMPT_FILE" \
  "$BASE_BRANCH"

# Sync active-tasks.json
python3 "${SCRIPTS_DIR}/active-tasks.py" attempt \
  --id "${TASK_ID}" --action "fix from review" --result "retry ${NEW_RETRIES}/${MAX_REVIEW_RETRIES}" \
  2>/dev/null || true

echo "Fix agent spawned for task $TASK_ID (review retry ${NEW_RETRIES}/${MAX_REVIEW_RETRIES})"
