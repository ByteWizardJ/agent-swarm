#!/bin/bash
# check-agents.sh — Check status of all registered agents (pure bash, no AI calls)
#
# State transitions: running -> completed -> reviewing -> done / failed
# Called by monitor-cron.sh, can also be run manually

set -euo pipefail

WORKSPACE="${AGENT_SWARM_WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$WORKSPACE/scripts/agent-registry.json"

if [ ! -f "$REGISTRY" ]; then
  echo "NO_ACTIVE_TASKS"
  exit 0
fi

TASKS=$(python3 -c "
import json
with open('${REGISTRY}') as f:
    reg = json.load(f)
for tid, t in reg['tasks'].items():
    if t['status'] in ('running', 'retry', 'reviewing'):
        print(tid)
" 2>/dev/null)

if [ -z "$TASKS" ]; then
  echo "NO_ACTIVE_TASKS"
  exit 0
fi

REPORT=""
AT="$SCRIPTS_DIR/active-tasks.py"

for TASK_ID in $TASKS; do
  SAFE_TASK_ID="${TASK_ID//\//-}"

  TASK_INFO=$(python3 -c "
import json
with open('${REGISTRY}') as f:
    reg = json.load(f)
t = reg['tasks']['${TASK_ID}']
print(f\"{t['worktree']}|{t['branch']}|{t['retries']}|{t['maxRetries']}|{t['agent']}|{t['status']}|{t.get('baseBranch','')}|{t.get('baseCommit','')}|{t.get('tmuxSession','agent-${TASK_ID}')}\")
")

  WORKTREE=$(echo "$TASK_INFO" | cut -d'|' -f1)
  BRANCH=$(echo "$TASK_INFO" | cut -d'|' -f2)
  RETRIES=$(echo "$TASK_INFO" | cut -d'|' -f3)
  MAX_RETRIES=$(echo "$TASK_INFO" | cut -d'|' -f4)
  AGENT=$(echo "$TASK_INFO" | cut -d'|' -f5)
  STATUS=$(echo "$TASK_INFO" | cut -d'|' -f6)
  BASE_BRANCH=$(echo "$TASK_INFO" | cut -d'|' -f7)
  BASE_COMMIT=$(echo "$TASK_INFO" | cut -d'|' -f8)
  TMUX_SESSION=$(echo "$TASK_INFO" | cut -d'|' -f9)

  # ===== REVIEWING state: check if review is complete =====
  if [ "$STATUS" = "reviewing" ]; then
    REVIEW_LOG="/tmp/review-${SAFE_TASK_ID}.log"
    SAFE_BRANCH="${BRANCH//\//_}"
    RESULT_FILE="/tmp/review-result-${SAFE_BRANCH}.txt"

    REVIEW_ERROR_FILE="/tmp/review-error-${SAFE_BRANCH}.txt"
    REVIEW_STARTED_AT=$(python3 -c "
import json
with open('${REGISTRY}') as f:
    reg = json.load(f)
print(reg['tasks'].get('${TASK_ID}', {}).get('lastCheckedAt', 0))
" 2>/dev/null || echo "0")
    NOW_TS=$(date +%s)
    REVIEW_AGE=$(( NOW_TS - REVIEW_STARTED_AT ))
    REVIEW_TIMEOUT=1500  # 25 minutes

    # Detect review script failure (error marker file written)
    if [ -f "$REVIEW_ERROR_FILE" ]; then
      ERROR_MSG=$(cat "$REVIEW_ERROR_FILE")
      rm -f "$REVIEW_ERROR_FILE"
      REPORT="${REPORT}🔴 ${TASK_ID}: REVIEW FAILED — ${ERROR_MSG}\n"
      python3 -c "
import json, time
with open('${REGISTRY}') as f:
    reg = json.load(f)
reg['tasks']['${TASK_ID}']['status'] = 'failed'
reg['tasks']['${TASK_ID}']['note'] = 'Review script error: ${ERROR_MSG}'
reg['tasks']['${TASK_ID}']['lastCheckedAt'] = int(time.time())
with open('${REGISTRY}', 'w') as f:
    json.dump(reg, f, indent=2)
"
      continue
    fi

    # Detect review timeout (no process alive + exceeded 25 min)
    if [ "$REVIEW_AGE" -gt "$REVIEW_TIMEOUT" ]; then
      REVIEW_PROCESS_ALIVE=false
      pgrep -f "review-pr.sh.*${WORKTREE}" >/dev/null 2>&1 && REVIEW_PROCESS_ALIVE=true
      tmux has-session -t "review-codex-${SAFE_BRANCH}" 2>/dev/null && REVIEW_PROCESS_ALIVE=true
      tmux has-session -t "review-claude-${SAFE_BRANCH}" 2>/dev/null && REVIEW_PROCESS_ALIVE=true

      if ! $REVIEW_PROCESS_ALIVE; then
        REPORT="${REPORT}🔴 ${TASK_ID}: REVIEW TIMED OUT (${REVIEW_AGE}s, no process alive) — resetting to retry\n"
        python3 -c "
import json, time
with open('${REGISTRY}') as f:
    reg = json.load(f)
t = reg['tasks']['${TASK_ID}']
review_retries = t.get('reviewRetries', 0) + 1
if review_retries > t.get('maxReviewRetries', 3):
    t['status'] = 'failed'
    t['note'] = 'Review timed out after max retries'
else:
    t['status'] = 'running'
    t['note'] = 'Review timed out, will retry on next check'
t['reviewRetries'] = review_retries
t['lastCheckedAt'] = int(time.time())
with open('${REGISTRY}', 'w') as f:
    json.dump(reg, f, indent=2)
"
        continue
      fi
    fi

    if [ -f "$REVIEW_LOG" ] && grep -q "review complete" "$REVIEW_LOG" 2>/dev/null; then
      # Read review conclusion
      REVIEW_STATUS="APPROVE"
      if [ -f "$RESULT_FILE" ]; then
        REVIEW_STATUS=$(cat "$RESULT_FILE")
      fi

      PR_NUM=$(cd "$WORKTREE" 2>/dev/null && gh pr list --head "$BRANCH" --json number -q '.[0].number' 2>/dev/null || echo "")

      if [ "$REVIEW_STATUS" = "REQUEST_CHANGES" ]; then
        # Check reviewRetries
        REVIEW_RETRIES=$(python3 -c "
import json
with open('${REGISTRY}') as f:
    reg = json.load(f)
print(reg['tasks'].get('${TASK_ID}', {}).get('reviewRetries', 0))
" 2>/dev/null || echo "0")
        MAX_REVIEW_RETRIES=3

        if [ "$REVIEW_RETRIES" -lt "$MAX_REVIEW_RETRIES" ]; then
          NEW_REVIEW_RETRIES=$((REVIEW_RETRIES + 1))
          REPORT="${REPORT}🔧 ${TASK_ID}: REVIEW REQUEST_CHANGES — spawning fix agent (review retry ${NEW_REVIEW_RETRIES}/${MAX_REVIEW_RETRIES})\n"
          nohup bash "${SCRIPTS_DIR}/fix-from-review.sh" "$TASK_ID" "$WORKTREE" "$BASE_BRANCH" > "/tmp/fix-${SAFE_TASK_ID}.log" 2>&1 &
        else
          REPORT="${REPORT}🔴 ${TASK_ID}: REVIEW FAILED after ${MAX_REVIEW_RETRIES} review retries — human intervention needed (PR #${PR_NUM})\n"
          python3 "$AT" blocker --id "${TASK_ID}" --blocker "Review retries exhausted, needs human intervention (PR #${PR_NUM})" 2>/dev/null || true
          python3 -c "
import json, time
with open('${REGISTRY}') as f:
    reg = json.load(f)
reg['tasks']['${TASK_ID}']['status'] = 'failed'
reg['tasks']['${TASK_ID}']['note'] = 'Review retries exhausted'
reg['tasks']['${TASK_ID}']['lastCheckedAt'] = int(time.time())
with open('${REGISTRY}', 'w') as f:
    json.dump(reg, f, indent=2)
"
        fi
      else
        # APPROVE — check CI
        CI_OK=true
        if [ -n "$PR_NUM" ]; then
          CI_FAIL=$(gh pr checks "$PR_NUM" 2>/dev/null | grep -c "fail" || echo "0")
          [ "$CI_FAIL" -gt "0" ] && CI_OK=false
        fi

        if $CI_OK; then
          REPORT="${REPORT}🏁 ${TASK_ID}: ALL CHECKS PASSED — PR #${PR_NUM} ready for human review\n"
          python3 "$AT" status --id "${TASK_ID}" --status done --context "PR #${PR_NUM} approved, CI passed" 2>/dev/null || true
          python3 -c "
import json, time
with open('${REGISTRY}') as f:
    reg = json.load(f)
t = reg['tasks']['${TASK_ID}']
t['status'] = 'done'
t['pr'] = ${PR_NUM:-0}
t['completedAt'] = int(time.time())
t['checks'] = {'prCreated': True, 'reviewPassed': True, 'ciPassed': True}
t['note'] = 'All checks passed. Ready to merge.'
with open('${REGISTRY}', 'w') as f:
    json.dump(reg, f, indent=2)
"
        else
          REPORT="${REPORT}⚠️ ${TASK_ID}: REVIEW APPROVED but CI FAILED — PR #${PR_NUM}\n"
        fi
      fi
    else
      REPORT="${REPORT}🔄 ${TASK_ID}: REVIEW IN PROGRESS\n"
    fi
    continue
  fi

  # ===== RUNNING/RETRY state: check tmux session =====
  SESSION_ALIVE=false
  tmux has-session -t "$TMUX_SESSION" 2>/dev/null && SESSION_ALIVE=true

  # Check git status
  NEW_COMMITS=0
  UNCOMMITTED=0
  LAST_COMMIT="none"
  if [ -d "$WORKTREE" ]; then
    cd "$WORKTREE"
    UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    LAST_COMMIT=$(git log --oneline -1 2>/dev/null || echo "none")
    if [ -n "$BASE_COMMIT" ]; then
      NEW_COMMITS=$(git rev-list "${BASE_COMMIT}..HEAD" --count 2>/dev/null || echo "0")
    fi
  fi

  if $SESSION_ALIVE; then
    # tmux alive — check if agent process (codex/claude) is still running in pane
    AGENT_PROCESS_ALIVE=false
    TMUX_PANE_PID=$(tmux list-panes -t "$TMUX_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -n "$TMUX_PANE_PID" ]; then
      # Recursively check pane process tree for codex/claude
      DESCENDANTS=$(pgrep -g "$TMUX_PANE_PID" 2>/dev/null || pstree -p "$TMUX_PANE_PID" 2>/dev/null | grep -oE '[0-9]+' || true)
      for DPID in $DESCENDANTS; do
        CMDLINE=$(ps -p "$DPID" -o command= 2>/dev/null || true)
        if echo "$CMDLINE" | grep -qE "codex|claude"; then
          AGENT_PROCESS_ALIVE=true
          break
        fi
      done
    fi

    if $AGENT_PROCESS_ALIVE; then
      REPORT="${REPORT}✅ ${TASK_ID} (${AGENT}): RUNNING | branch=${BRANCH} | commits=${NEW_COMMITS} | uncommitted=${UNCOMMITTED}\n"
      continue
    fi
    # tmux alive but agent process exited — treat as session dead, fall through
  fi

  # Session dead
  if [ "$NEW_COMMITS" -gt "0" ]; then
    # Has new commits — completed normally, trigger review
    REPORT="${REPORT}🏁 ${TASK_ID} (${AGENT}): COMPLETED | commits=${NEW_COMMITS} | last=${LAST_COMMIT}\n"
    python3 "$AT" status --id "${TASK_ID}" --status active --context "Agent completed, entering review (${NEW_COMMITS} commits)" 2>/dev/null || true

    python3 -c "
import json, time
with open('${REGISTRY}') as f:
    reg = json.load(f)
reg['tasks']['${TASK_ID}']['status'] = 'reviewing'
reg['tasks']['${TASK_ID}']['lastCheckedAt'] = int(time.time())
with open('${REGISTRY}', 'w') as f:
    json.dump(reg, f, indent=2)
"
    # Auto-start review (background)
    if [ -n "$BASE_BRANCH" ]; then
      REPORT="${REPORT}   -> Auto-starting PR review (base=${BASE_BRANCH})\n"
      nohup bash "${SCRIPTS_DIR}/review-pr.sh" "$WORKTREE" "$BASE_BRANCH" "$TASK_ID" > "/tmp/review-${SAFE_TASK_ID}.log" 2>&1 &
    fi

  else
    # No new commits — abnormal exit, attempt retry
    NEW_RETRIES=$((RETRIES + 1))
    if [ "$NEW_RETRIES" -le "$MAX_RETRIES" ]; then
      REPORT="${REPORT}⚠️ ${TASK_ID} (${AGENT}): EXITED (uncommitted=${UNCOMMITTED}) — auto-retrying (${NEW_RETRIES}/${MAX_RETRIES})\n"
      bash "${SCRIPTS_DIR}/retry-agent.sh" "$TASK_ID" 2>/dev/null || true
    else
      REPORT="${REPORT}🔴 ${TASK_ID} (${AGENT}): FAILED after ${MAX_RETRIES} retries\n"
      python3 "$AT" blocker --id "${TASK_ID}" --blocker "Agent failed after ${MAX_RETRIES} retries, needs human intervention" 2>/dev/null || true
      python3 -c "
import json, time
with open('${REGISTRY}') as f:
    reg = json.load(f)
reg['tasks']['${TASK_ID}']['status'] = 'failed'
reg['tasks']['${TASK_ID}']['lastCheckedAt'] = int(time.time())
with open('${REGISTRY}', 'w') as f:
    json.dump(reg, f, indent=2)
"
    fi
  fi

done

echo -e "$REPORT"
