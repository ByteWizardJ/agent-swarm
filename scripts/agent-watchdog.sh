#!/bin/bash
# agent-watchdog.sh — Zero-token background monitoring loop
# Started by spawn-agent.sh in the background to watch a single agent tmux session
# Detect exit -> auto-retry (up to maxRetries) -> notify if retries are exhausted
#
# Usage: agent-watchdog.sh <task-id> [check-interval-seconds]

set -euo pipefail

TASK_ID="${1:?Usage: agent-watchdog.sh <task-id>}"
INTERVAL="${2:-300}"  # Default: check every 5 minutes
WORKSPACE="${AGENT_SWARM_WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$WORKSPACE/scripts/agent-registry.json"
SAFE_TASK_ID="${TASK_ID//\//-}"
LOG_FILE="/tmp/agent-watchdog-${SAFE_TASK_ID}.log"
TMUX_SESSION="agent-${SAFE_TASK_ID}"

log() {
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >> "$LOG_FILE"
}

notify() {
    local msg="$1"
    local channel="${AGENT_SWARM_NOTIFY_CHANNEL:-}"
    local target="${AGENT_SWARM_NOTIFY_TARGET:-}"
    if [[ -n "$target" && -n "$channel" ]]; then
        openclaw message send --channel "$channel" --target "$target" -m "$msg" 2>/dev/null \
          || openclaw system event --text "$msg" --mode now 2>/dev/null
    else
        openclaw system event --text "$msg" --mode now 2>/dev/null
    fi
}

log "Watchdog started for task ${TASK_ID}, interval=${INTERVAL}s"

while true; do
    sleep "$INTERVAL"

    # Read registry state
    TASK_STATUS=$(python3 -c "
import json, os
reg_path = '${REGISTRY}'
if not os.path.exists(reg_path):
    print('missing')
    exit()
with open(reg_path) as f:
    reg = json.load(f)
t = reg.get('tasks', {}).get('${TASK_ID}')
if not t:
    print('missing')
else:
    print(t.get('status', 'unknown'))
" 2>/dev/null)

    # Task is complete, failed, or missing -> exit watchdog
    if [[ "$TASK_STATUS" =~ ^(done|failed|reviewed|missing)$ ]]; then
        log "Task ${TASK_ID} status=${TASK_STATUS}, watchdog exiting"
        exit 0
    fi

    # Check whether the tmux session is still alive
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        # Detect likely stuck loops: session is alive but there is no new commit for over 60 minutes
        WORKTREE=$(python3 -c "
import json
with open('${REGISTRY}') as f: reg = json.load(f)
print(reg.get('tasks', {}).get('${TASK_ID}', {}).get('worktree', ''))
" 2>/dev/null)

        if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
            LAST_COMMIT_AGE=$(cd "$WORKTREE" && \
                git log -1 --format="%ct" 2>/dev/null || echo "0")
            NOW_TS=$(date +%s)
            AGE_MINS=$(( (NOW_TS - LAST_COMMIT_AGE) / 60 ))
            STARTED_AT=$(python3 -c "
import json
with open('${REGISTRY}') as f: reg = json.load(f)
print(reg.get('tasks', {}).get('${TASK_ID}', {}).get('startedAt', 0))
" 2>/dev/null)
            RUNNING_MINS=$(( (NOW_TS - STARTED_AT) / 60 ))

            # Only start checking for no-progress after the agent has run for 30+ minutes
            if [ "$RUNNING_MINS" -gt 30 ] && [ "$AGE_MINS" -gt 60 ]; then
                log "STUCK DETECTED: session alive but no commit in ${AGE_MINS}min"
                # Kill the stuck session so the retry flow can take over
                tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
                notify "⚠️ Task ${TASK_ID}: agent appears stuck (${AGE_MINS} minutes without progress), force-stopped and retry triggered"
                # Do not continue here; let the retry logic below take over
            else
                log "Session ${TMUX_SESSION} running ok (${AGE_MINS}min since last commit, running ${RUNNING_MINS}min)"
                continue
            fi
        else
            log "Session ${TMUX_SESSION} still running, ok"
            continue
        fi
    fi

    # Session is gone; read retry counters
    RETRY_INFO=$(python3 -c "
import json
with open('${REGISTRY}') as f:
    reg = json.load(f)
t = reg.get('tasks', {}).get('${TASK_ID}', {})
print(f\"{t.get('retries', 0)}|{t.get('maxRetries', 3)}|{t.get('status', 'unknown')}\")
" 2>/dev/null)

    RETRIES=$(echo "$RETRY_INFO" | cut -d'|' -f1)
    MAX_RETRIES=$(echo "$RETRY_INFO" | cut -d'|' -f2)
    CURRENT_STATUS=$(echo "$RETRY_INFO" | cut -d'|' -f3)

    # If the task is already done or failed, the agent exited normally and updated state
    if [[ "$CURRENT_STATUS" =~ ^(done|failed|reviewed)$ ]]; then
        log "Task ${TASK_ID} completed normally (status=${CURRENT_STATUS})"
        exit 0
    fi

    log "Session ${TMUX_SESSION} dead. retries=${RETRIES}/${MAX_RETRIES}"

    if [ "$RETRIES" -lt "$MAX_RETRIES" ]; then
        # Auto-retry
        log "Auto-retrying task ${TASK_ID} (attempt $((RETRIES + 1))/${MAX_RETRIES})"
        bash "${SCRIPTS_DIR}/retry-agent.sh" "${TASK_ID}" >> "$LOG_FILE" 2>&1 && {
            log "Retry launched successfully"
        } || {
            log "Retry failed to launch"
            # Mark failed and notify
            python3 -c "
import json, time
with open('${REGISTRY}') as f: reg = json.load(f)
reg['tasks']['${TASK_ID}']['status'] = 'failed'
reg['tasks']['${TASK_ID}']['lastCheckedAt'] = int(time.time())
with open('${REGISTRY}', 'w') as f: json.dump(reg, f, indent=2)
" 2>/dev/null
            notify "⚠️ Task ${TASK_ID}: retry launch failed, needs manual handling"
            exit 1
        }
    else
        # Retry limit exceeded; mark failed and notify
        log "Max retries (${MAX_RETRIES}) exceeded for task ${TASK_ID}"
        python3 -c "
import json, time
with open('${REGISTRY}') as f: reg = json.load(f)
reg['tasks']['${TASK_ID}']['status'] = 'failed'
reg['tasks']['${TASK_ID}']['lastCheckedAt'] = int(time.time())
with open('${REGISTRY}', 'w') as f: json.dump(reg, f, indent=2)
" 2>/dev/null
        notify "🔴 Task ${TASK_ID} failed after ${MAX_RETRIES} retries and needs operator intervention. Log: ${LOG_FILE}"
        exit 1
    fi
done
