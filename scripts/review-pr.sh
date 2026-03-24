#!/bin/bash
# review-pr.sh — 4-lane parallel PR review
#
# Lane 1: Security audit (Claude Opus)
# Lane 2: Security audit (Codex GPT-5.4) — same prompt, cross-validation
# Lane 3: Standards + Logic compliance (Codex GPT-5.4) — new prompt
# Lane 4: Comment consistency (Sonnet) — new prompt
#
# Usage: review-pr.sh <worktree-path> <base-branch> [task-id]
#
# What it does:
#   1. Push branch and create PR (if not exists)
#   2. Launch 4 reviewers in parallel
#   3. Aggregate results and post as PR comment
#   4. Notify on completion

set -uo pipefail

WORKTREE="${1:?Usage: review-pr.sh <worktree-path> <base-branch> [task-id]}"
BASE="${2:?Missing base branch}"
REVIEW_TASK_ID="${3:-}"
WORKSPACE="${AGENT_SWARM_WORKSPACE:-${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}}"
TASKS_DIR="$WORKSPACE/tasks"
SAFE_BRANCH_FOR_ERR=""

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

# Write error marker for check-agents.sh to detect
_on_error() {
  local exit_code=$?
  if [ -n "$SAFE_BRANCH_FOR_ERR" ]; then
    echo "review error: exit code $exit_code" > "/tmp/review-error-${SAFE_BRANCH_FOR_ERR}.txt"
  fi
  exit $exit_code
}
trap _on_error ERR

cd "$WORKTREE"
BRANCH=$(git branch --show-current)
SAFE_BRANCH="${BRANCH//\//_}"
SAFE_BRANCH_FOR_ERR="$SAFE_BRANCH"

# Ensure base branch exists on remote
if ! git ls-remote --heads origin "$BASE" | grep -q "$BASE"; then
  echo "Pushing base branch $BASE to remote..."
  git push origin "$BASE" 2>/dev/null || true
fi

# Push feature branch
git push -u origin "$BRANCH" 2>/dev/null || git push 2>/dev/null

# Get or create PR
PR_NUM=$(gh pr list --head "$BRANCH" --json number -q '.[0].number' 2>/dev/null)
if [ -z "$PR_NUM" ]; then
  PR_URL=$(gh pr create --base "$BASE" --head "$BRANCH" --fill 2>/dev/null)
  PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')
fi
echo "PR: #${PR_NUM}"

REVIEW_CODEX="/tmp/review-codex-${SAFE_BRANCH}.md"
REVIEW_CLAUDE="/tmp/review-claude-${SAFE_BRANCH}.md"
REVIEW_COMPLIANCE="/tmp/review-compliance-${SAFE_BRANCH}.md"
REVIEW_COMMENTS="/tmp/review-comments-${SAFE_BRANCH}.md"
CODEX_TASK_FILE="/tmp/review-task-codex-${SAFE_BRANCH}.txt"
CLAUDE_TASK_FILE="/tmp/review-task-claude-${SAFE_BRANCH}.txt"
COMPLIANCE_TASK_FILE="/tmp/review-task-compliance-${SAFE_BRANCH}.txt"
COMMENTS_TASK_FILE="/tmp/review-task-comments-${SAFE_BRANCH}.txt"

# --- Review workspace: task dir if available, else /tmp ---
if [ -n "$REVIEW_TASK_ID" ]; then
  if [[ "$REVIEW_TASK_ID" == */* ]]; then
    _TASK_NAME="${REVIEW_TASK_ID%%/*}"
    _SUBTASK_NAME="${REVIEW_TASK_ID#*/}"
    REVIEW_WORKDIR="${TASKS_DIR}/${_TASK_NAME}/subtasks/${_SUBTASK_NAME}"
  else
    REVIEW_WORKDIR="${TASKS_DIR}/${REVIEW_TASK_ID}"
  fi
else
  REVIEW_WORKDIR="/tmp/review-${SAFE_BRANCH}"
fi
mkdir -p "${REVIEW_WORKDIR}"

# --- Force clean cache to ensure fresh review every time ---
rm -f "${REVIEW_WORKDIR}/audit-codex.md" "${REVIEW_WORKDIR}/audit-claude.md"
rm -f "${REVIEW_WORKDIR}/audit-compliance.md" "${REVIEW_WORKDIR}/audit-comments.md"
rm -f "${REVIEW_CODEX}" "${REVIEW_CLAUDE}" "${REVIEW_CODEX}.json" "${REVIEW_CLAUDE}.json"
rm -f "${REVIEW_CODEX}.done" "${REVIEW_CLAUDE}.done"
rm -f "${REVIEW_COMPLIANCE}" "${REVIEW_COMPLIANCE}.done"
rm -f "${REVIEW_COMMENTS}" "${REVIEW_COMMENTS}.json" "${REVIEW_COMMENTS}.done"

# --- Build shared prompt from template + project config ---
# Priority: task dir PROJECT_CONTEXT.md > worktree > REVIEW_CONTEXT.md > defaults
if [ -f "${REVIEW_WORKDIR}/PROJECT_CONTEXT.md" ]; then
  PROJECT_CONTEXT_FILE="${REVIEW_WORKDIR}/PROJECT_CONTEXT.md"
else
  PROJECT_CONTEXT_FILE="${WORKTREE}/PROJECT_CONTEXT.md"
fi
REVIEW_CONTEXT_FILE="${WORKTREE}/REVIEW_CONTEXT.md"
REVIEW_CONTEXT=""
PROJECT_CONTEXT_BLOCK=""

if [ -f "$PROJECT_CONTEXT_FILE" ]; then
  # Use PROJECT_CONTEXT.md as primary source (new unified format)
  PROJECT_CONTEXT_BLOCK=$(cat "$PROJECT_CONTEXT_FILE")
  # Also check for legacy REVIEW_CONTEXT.md for backward compat
  if [ -f "$REVIEW_CONTEXT_FILE" ]; then
    REVIEW_CONTEXT=$(cat "$REVIEW_CONTEXT_FILE")
  fi
elif [ -f "$REVIEW_CONTEXT_FILE" ]; then
  # Fallback to legacy REVIEW_CONTEXT.md
  REVIEW_CONTEXT=$(cat "$REVIEW_CONTEXT_FILE")
fi

# Detect diff scope and project type (check PROJECT_CONTEXT.md first, then REVIEW_CONTEXT.md)
read -r DIFF_SCOPE PROJECT_TYPE <<< $(python3 -c "
import os
# Check PROJECT_CONTEXT.md first, then REVIEW_CONTEXT.md
for ctx_path in ['${PROJECT_CONTEXT_FILE}', '${REVIEW_CONTEXT_FILE}']:
    scope = None
    ptype = None
    if os.path.exists(ctx_path):
        with open(ctx_path) as f:
            for line in f:
                s = line.strip()
                if s.startswith('diff_scope:'):
                    scope = s.split(':', 1)[1].strip()
                elif s.startswith('project_type:'):
                    ptype = s.split(':', 1)[1].strip().lower()
        if scope or ptype:
            break
print(scope or 'src/', ptype or 'solidity')
" 2>/dev/null)

# Generate changed files checklist to prevent early-stop
CHANGED_FILES=$(cd "$WORKTREE" && git diff --name-only "${BASE}...${BRANCH}" -- ${DIFF_SCOPE} 2>/dev/null | sort)
CHANGED_FILES_COUNT=$(echo "$CHANGED_FILES" | grep -c '.' || echo "0")
CHANGED_FILES_CHECKLIST=""
if [ "$CHANGED_FILES_COUNT" -gt 0 ]; then
  CHANGED_FILES_CHECKLIST="## Mandatory File Checklist

You MUST analyze every file in this list. Do not stop after finding the first vulnerability. Check off each file as you complete it. Only write your conclusion after ALL files are reviewed.

Changed files (${CHANGED_FILES_COUNT} total):
$(echo "$CHANGED_FILES" | while read -r f; do echo "- [ ] \`${f}\`"; done)

⚠️ Anti-early-stop rule: After finding a vulnerability, CONTINUE to the next unchecked file. Your audit is NOT complete until every file above is checked.
"
fi

# Generate project-type-specific audit methodology (steps 4-5)
case "$PROJECT_TYPE" in
  solidity)
    AUDIT_METHODOLOGY_BODY='4. Trace cross-contract call chains: for each external/public function changed, follow all callers and callees across files. Pay special attention to:
   - Reentrancy paths (state changes after external calls)
   - Access control on state-mutating functions
   - Value flow (ETH/token transfers, approve/transferFrom chains)
   - Integer overflow/underflow and precision loss
   - Oracle/price manipulation vectors
   - Front-running and MEV exposure (amountOutMin, permissionless triggers)
5. For each finding, verify it is actually exploitable under real conditions:
   - Check the Solidity compiler version — >=0.8.x has checked arithmetic (no silent overflow/underflow)
   - Check if reentrancy guards, access control, or other protections already exist in the call path
   - Check if the PoC assumptions hold (e.g., msg.sender constraints, contract state prerequisites)
   - If the exploit requires conditions that cannot occur in practice, downgrade or discard the finding
   - Reference: OpenZeppelin EVMBench audit found 4/120 "high severity" bugs were unexploitable due to compiler version assumptions and existing guards'
    ;;
  backend)
    AUDIT_METHODOLOGY_BODY='4. Trace request handling chains: for each API endpoint changed, follow the full path from request to response. Pay special attention to:
   - Authentication and authorization bypass (missing or incorrect permission checks)
   - SQL injection and ORM misuse (raw queries, unsanitized parameters)
   - Race conditions (concurrent writes, TOCTOU)
   - Input validation (missing bounds checks, type coercion, malformed data)
   - Sensitive data exposure (logging secrets, leaking internal state in responses)
   - Business logic flaws (incorrect state transitions, off-by-one in pagination/limits)
5. For each finding, verify it is actually exploitable:
   - Check if middleware/framework already provides protection (CSRF, rate limiting, etc.)
   - Check if the vulnerable code path is actually reachable from an external request
   - If the exploit requires internal/admin access that is trusted, downgrade or discard'
    ;;
  frontend)
    AUDIT_METHODOLOGY_BODY='4. Trace data flow: for each component/page changed, follow user input from UI to API call and back. Pay special attention to:
   - XSS vectors (unsanitized user input rendered in DOM, dangerouslySetInnerHTML)
   - Incorrect API integration (wrong endpoint, missing error handling, stale data)
   - Authentication state bugs (token handling, protected route bypass, session leaks)
   - Wallet/blockchain interaction bugs (wrong contract address source, incorrect ABI, hardcoded addresses)
   - State management issues (race conditions in async calls, stale closures, missing loading/error states)
   - Sensitive data in client code (API keys, private keys, secrets in bundle)
5. For each finding, verify it is actually exploitable:
   - Check if the framework already sanitizes (React escapes by default, etc.)
   - Check if CSP headers or other browser protections mitigate the issue
   - If the issue only affects development mode or requires physical device access, downgrade'
    ;;
  *)
    AUDIT_METHODOLOGY_BODY='4. Trace data and control flow through all changed code. Pay special attention to:
   - Input validation and sanitization
   - Authentication and authorization checks
   - Error handling and edge cases
   - Resource management (memory leaks, file handle leaks, connection pools)
   - Concurrency issues (race conditions, deadlocks)
5. For each finding, verify it is actually exploitable under real conditions.'
    ;;
esac

AUDITOR_ROLE="code auditor"
case "$PROJECT_TYPE" in
  solidity) AUDITOR_ROLE="smart contract auditor" ;;
  backend)  AUDITOR_ROLE="backend security auditor" ;;
  frontend) AUDITOR_ROLE="frontend security auditor" ;;
esac

SHARED_PROMPT="You are an expert security researcher and ${AUDITOR_ROLE}.

Your goal is to audit the code changes in this PR and produce a thorough vulnerability report. Focus on vulnerabilities that could directly or indirectly lead to: loss of user or platform assets, unauthorized access or privilege escalation, denial of service to critical functions, or violation of core protocol invariants.

## Environment

Working directory: ${WORKTREE} (checked out to branch ${BRANCH})
Base branch: ${BASE}
Diff scope: ${DIFF_SCOPE}

## Trust Model

Assume privileged roles (owner/admin/governance) are trusted and not malicious. Do not report issues that require their malicious action. Do report issues where unprivileged users can escalate or bypass access control.

## Audit Methodology

1. Run \`git diff ${BASE}...${BRANCH} -- ${DIFF_SCOPE}\` to see all changes in this PR.
2. If a README.md or design doc exists in the working directory, read it for scope boundaries, project description, and suggested entry points.
3. Read every modified source file in full — do not skim. Understand the complete logic before judging.
${AUDIT_METHODOLOGY_BODY}
6. Capture every distinct issue you uncover. Thoroughness and accuracy are valued over brevity. However, be careful to only surface real vulnerabilities — false positives waste human review time.

You only get one autonomous run. Do not pause for confirmation, ask questions, or mention future steps. Continue working until your audit is genuinely complete.

${CHANGED_FILES_CHECKLIST}

## Incremental Output

Write findings incrementally to \`\${HOME}/submission/audit.md\` as you go, so progress is preserved if the session is interrupted. Append each finding as you discover it. When your audit is complete, finalize the report with the Summary Table and Conclusion at the end of that file.

Your final chat reply should contain only: the Summary Table and the conclusion line (APPROVE or REQUEST_CHANGES). The full report lives in \`\${HOME}/submission/audit.md\`.

"

# Append project context (unified PROJECT_CONTEXT.md or legacy REVIEW_CONTEXT.md)
if [ -n "$PROJECT_CONTEXT_BLOCK" ]; then
  SHARED_PROMPT="${SHARED_PROMPT}## Project Context

Read the following project context carefully. It contains architecture, known pitfalls, security model, and code standards that are critical for your review.

${PROJECT_CONTEXT_BLOCK}

"
elif [ -n "$REVIEW_CONTEXT" ]; then
  SHARED_PROMPT="${SHARED_PROMPT}## Project-Specific Review Context

${REVIEW_CONTEXT}

"
fi

# Append output requirements
SHARED_PROMPT="${SHARED_PROMPT}## Output Requirements

⚠️ IMPORTANT: Your final reply must contain the complete audit report. Do not output analysis during tool calls — consolidate everything into the last message.

For each vulnerability, provide:
- **Title**: concise, sentence case (not title case)
- **Severity**: 🔴 Critical (loss of funds, broken invariants) / 🟡 Warning (risk under specific conditions) / 🟢 Info (code quality, gas, best practice)
- **Location**: file path, line_start - line_end
- **Root cause**: why the vulnerability exists
- **Impact**: what an attacker can achieve, with concrete scenario
- **Proof of concept**: attack steps or code snippet demonstrating the exploit
- **Remediation**: specific fix suggestion with code if possible

After all findings, provide:

### Summary Table

| # | Severity | Title | File | Lines |
|---|----------|-------|------|-------|
| 1 | 🔴 | ... | ... | ... |

### Conclusion

Final line must be exactly one of: \`APPROVE\` or \`REQUEST_CHANGES\`

Rules:
- Output \`REQUEST_CHANGES\` if there is ANY 🔴 Critical finding.
- Output \`APPROVE\` if there are only 🟡 Warning and/or 🟢 Info findings (or no findings).
- Output in English."

# Write reviewer-specific prompts with distinct audit file paths
CODEX_PROMPT="${SHARED_PROMPT//\$\{HOME\}\/submission\/audit.md/${REVIEW_WORKDIR}/audit-codex.md}"
CLAUDE_PROMPT="${SHARED_PROMPT//\$\{HOME\}\/submission\/audit.md/${REVIEW_WORKDIR}/audit-claude.md}"

echo "$CODEX_PROMPT" > "$CODEX_TASK_FILE"
echo "$CLAUDE_PROMPT" > "$CLAUDE_TASK_FILE"

# --- Lane 3: Standards + Logic Compliance prompt ---
COMPLIANCE_PROMPT="You are an expert code reviewer focused on standards compliance and logical correctness.

You are NOT doing security auditing — a separate auditor handles that. Your job is to verify that the code changes follow project standards, actually implement what was intended, and do not introduce functional regressions.

## Environment

Working directory: ${WORKTREE} (checked out to branch ${BRANCH})
Base branch: ${BASE}
Diff scope: ${DIFF_SCOPE}

## Audit Methodology

1. Run \`git diff ${BASE}...${BRANCH} -- ${DIFF_SCOPE}\` to see all changes.
2. For each changed file, read the FULL file (not just the diff), plus any related tests and direct callers/callees. Diff-only review misses invariants and usage context.
3. Read PROJECT_CONTEXT.md (if exists) for project coding standards, architecture patterns, and conventions.
4. Determine design intent using this fallback chain (first available wins):
   a. TASK.md in the working directory
   b. Existing test expectations for the changed code
   c. PR title and commit messages (\`git log ${BASE}..${BRANCH} --oneline\`)
   d. Neighboring code patterns and public interface contracts
5. For each changed file, check the following dimensions:

### A. Coding Standards Compliance
- Naming conventions (variables, functions, contracts, events, errors)
- File/directory structure conventions defined in PROJECT_CONTEXT.md
- Import ordering, module organization
- Anti-patterns explicitly called out in PROJECT_CONTEXT.md
- Consistent error handling patterns across the codebase

### B. Design Intent Verification
- Does the implementation match the intended design (per fallback chain above)?
- Are all stated requirements actually implemented? (missing features)
- Are \"confirmed design decisions\" preserved and not contradicted?
- Are there undocumented behavioral changes that look unintentional?

### C. Functional Correctness (non-security)
- Off-by-one errors, incorrect boundary conditions
- Wrong operator or inverted condition
- State transitions that don't match the documented or tested flow
- Return values that don't match caller expectations
- NOTE: If a finding is primarily about exploitability or attack vectors, omit it — the security auditor covers that. Only report functional bugs that would cause incorrect behavior regardless of adversarial intent.

### D. Test Coverage
- If logic was added or changed, were corresponding tests added or updated?
- Do test names and descriptions match what they actually test?
- Are edge cases from design constraints covered in tests?

### E. Code Quality (strict scope)
Only report code quality issues when they create concrete maintainability or correctness risk — not mere preference:
- Dead code introduced (unused imports, unreachable branches, commented-out code left without explanation)
- Copy-paste artifacts where divergence would cause bugs
- Magic numbers in business logic (thresholds, fees, limits) without named constants
- Inconsistent patterns within the same PR that will confuse future maintainers

## What NOT to Report
- Security vulnerabilities or exploitability analysis (handled by security auditor)
- Pre-existing issues not introduced in this PR
- Stylistic preferences not defined in PROJECT_CONTEXT.md
- Purely mechanical issues enforced by CI (formatting, import sorting, type errors caught by compiler/linter)
- Speculative concerns without concrete evidence from code, tests, or docs

## Confidence Rule

Only report findings you can back with specific evidence (a code snippet, a TASK.md quote, a test expectation, a PROJECT_CONTEXT.md rule). If you are unsure, omit the finding. Silence is better than noise.

Do not report multiple findings for the same root cause — consolidate them.

You only get one autonomous run. Do not pause for confirmation, ask questions, or mention future steps. Continue working until your review is genuinely complete.

${CHANGED_FILES_CHECKLIST}

## Output

Write findings incrementally to \`${REVIEW_WORKDIR}/audit-compliance.md\` as you go.

For each finding:
- **Title**: concise description
- **Severity**: 🟡 Warning (real issue) / 🟢 Info (improvement suggestion)
- **Category**: Standards | Intent Mismatch | Functional Bug | Test Gap | Code Quality
- **Location**: file path, line range
- **Evidence**: source of truth (TASK.md quote, test name, PROJECT_CONTEXT.md rule, code pattern)
- **Expected**: what the standard/intent says
- **Actual**: what the code does
- **Remediation**: specific fix

After all findings, provide:

### Summary Table

| # | Severity | Category | Title | File | Lines |
|---|----------|----------|-------|------|-------|

### Conclusion

APPROVE or REQUEST_CHANGES

Rules:
- REQUEST_CHANGES if there is any 🟡 Warning with Category = Intent Mismatch, Functional Bug, or Test Gap where new logic has zero test coverage.
- APPROVE for all other cases (Standards / Code Quality / partial test gaps are informational).

Output in English."

# Append project context to compliance prompt
if [ -n "$PROJECT_CONTEXT_BLOCK" ]; then
  COMPLIANCE_PROMPT="${COMPLIANCE_PROMPT}

## Project Context

Read the following project context carefully. It contains architecture, known pitfalls, and code standards.

${PROJECT_CONTEXT_BLOCK}"
elif [ -n "$REVIEW_CONTEXT" ]; then
  COMPLIANCE_PROMPT="${COMPLIANCE_PROMPT}

## Project-Specific Review Context

${REVIEW_CONTEXT}"
fi

echo "$COMPLIANCE_PROMPT" > "$COMPLIANCE_TASK_FILE"

# --- Lane 4: Comment Consistency prompt ---
COMMENTS_PROMPT="You are a code reviewer specialized in verifying consistency between code comments and actual implementation.

Your sole focus: do the comments accurately describe what the code does? This is a narrow, focused review — do not look for bugs, security issues, or style problems.

## Environment

Working directory: ${WORKTREE} (checked out to branch ${BRANCH})
Base branch: ${BASE}
Diff scope: ${DIFF_SCOPE}

## Audit Methodology

1. Run \`git diff ${BASE}...${BRANCH} -- ${DIFF_SCOPE}\` to see all changes.
2. For each changed file, read the full file (not just the diff) to understand context.
3. Check comments in the following scope (do NOT review comments unrelated to the PR's changes):
   - Comments on lines changed in the diff
   - Doc comments (NatSpec, JSDoc, docstrings) for any symbol whose signature or behavior changed
   - Adjacent comments whose truth value changed as a result of the PR (e.g., a comment says \"this list has max 3 items\" but the PR changed the limit to 5)

4. For each in-scope comment, check against these dimensions:

### A. Stale Comments
- Comment describes old behavior that the PR changed, but the comment wasn't updated
- Parameter descriptions that no longer match the actual parameters
- @dev/@notice/@param/@return annotations that are now wrong
- TODO/FIXME comments for things that were already fixed in this PR

### B. Misleading Comments
- Comment says \"does X\" but code actually does Y
- Comment says \"returns X\" but function returns something different
- Comment describes a constraint that the code doesn't enforce
- Comment references a variable/function that was renamed or removed

### C. Dead Comments
- Commented-out code blocks with no explanation of why they're kept
- Comments referencing removed functionality

## Important: Do Not Assume Which Side Is Wrong

When comment and code disagree, report the MISMATCH. Do not automatically assume the code is correct and the comment is wrong — sometimes the comment documents the intended behavior and the code is buggy. State both sides and let the human reviewer decide.

## What NOT to Report
- Missing comments on self-explanatory code (do not demand comments everywhere)
- Missing rationale comments on straightforward logic
- Comment style/formatting preferences
- Security vulnerabilities or bugs (handled by security auditor)
- Pre-existing comment issues on lines not affected by the PR
- Typos in comments (unless they change meaning)
- Speculative concerns — only report mismatches you can demonstrate with a quote and a code reference

## Confidence Rule

Only report findings with concrete evidence: quote the comment, cite the code. If you are uncertain whether a mismatch exists, omit it.

Do not report multiple findings for the same root cause.

You only get one autonomous run. Do not pause for confirmation, ask questions, or mention future steps. Continue working until your review is genuinely complete.

${CHANGED_FILES_CHECKLIST}

## Output

Write findings incrementally to \`${REVIEW_WORKDIR}/audit-comments.md\` as you go.

For each finding:
- **Title**: concise description
- **Severity**: 🟡 Warning (comment actively contradicts code behavior) / 🟢 Info (stale or dead)
- **Category**: Stale | Misleading | Dead
- **Location**: file path, line range
- **Comment says**: quote the comment verbatim
- **Code does**: describe actual behavior with code reference
- **Suggestion**: updated comment text, \"remove\", or \"verify intent — comment and code disagree\"

After all findings, provide:

### Summary Table

| # | Severity | Category | Title | File | Lines |
|---|----------|----------|-------|------|-------|

### Conclusion

APPROVE or REQUEST_CHANGES

Rules:
- REQUEST_CHANGES only if there are 🟡 Misleading findings on: public API doc comments, financial/accounting semantics, protocol assumptions, or user-visible behavior descriptions.
- APPROVE for all other cases.

Output in English."

echo "$COMMENTS_PROMPT" > "$COMMENTS_TASK_FILE"

# --- Launch four reviewers in parallel ---
echo "Starting Codex review (Lane 2: Security)..."
tmux new-session -d -s "review-codex-${SAFE_BRANCH}" \
  "cd ${WORKTREE} && codex exec --dangerously-bypass-approvals-and-sandbox -m ${AGENT_SWARM_REVIEW_MODEL:-gpt-5.4} -c model_reasoning_effort=high -o ${REVIEW_CODEX} \"\$(cat ${CODEX_TASK_FILE})\" 2>/dev/null; touch ${REVIEW_CODEX}.done"

echo "Starting Claude review (Lane 1: Security)..."
# Use --output-format json to get full output (text mode loses analysis from tool use turns)
# Then extract all text blocks with python3
tmux new-session -d -s "review-claude-${SAFE_BRANCH}" \
  "cd ${WORKTREE} && claude --model ${AGENT_SWARM_CLAUDE_MODEL:-claude-opus-4-6} --dangerously-skip-permissions --output-format json -p \"\$(cat ${CLAUDE_TASK_FILE})\" > ${REVIEW_CLAUDE}.json 2>/tmp/claude-review-stderr-${SAFE_BRANCH}.txt; python3 -c \"
import json, sys
try:
    with open('${REVIEW_CLAUDE}.json') as f:
        data = json.load(f)
    result = data.get('result', '')
    if result:
        print(result)
    else:
        # fallback: extract text blocks from content
        for block in data.get('content', []):
            if isinstance(block, dict) and block.get('type') == 'text':
                print(block['text'])
except Exception as e:
    print(f'Error parsing JSON: {e}', file=sys.stderr)
\" > ${REVIEW_CLAUDE} 2>>/tmp/claude-review-stderr-${SAFE_BRANCH}.txt; touch ${REVIEW_CLAUDE}.done"

echo "Starting Compliance review (Lane 3: Standards + Logic)..."
tmux new-session -d -s "review-compliance-${SAFE_BRANCH}" \
  "cd ${WORKTREE} && codex exec --dangerously-bypass-approvals-and-sandbox -m ${AGENT_SWARM_REVIEW_MODEL:-gpt-5.4} -c model_reasoning_effort=high -o ${REVIEW_COMPLIANCE} \"\$(cat ${COMPLIANCE_TASK_FILE})\" 2>/dev/null; touch ${REVIEW_COMPLIANCE}.done"

echo "Starting Comments review (Lane 4: Comment Consistency)..."
tmux new-session -d -s "review-comments-${SAFE_BRANCH}" \
  "cd ${WORKTREE} && claude --model ${AGENT_SWARM_SONNET_MODEL:-claude-sonnet-4-6} --dangerously-skip-permissions --output-format json -p \"\$(cat ${COMMENTS_TASK_FILE})\" > ${REVIEW_COMMENTS}.json 2>/tmp/comments-review-stderr-${SAFE_BRANCH}.txt; python3 -c \"
import json, sys
try:
    with open('${REVIEW_COMMENTS}.json') as f:
        data = json.load(f)
    result = data.get('result', '')
    if result:
        print(result)
    else:
        for block in data.get('content', []):
            if isinstance(block, dict) and block.get('type') == 'text':
                print(block['text'])
except Exception as e:
    print(f'Error parsing JSON: {e}', file=sys.stderr)
\" > ${REVIEW_COMMENTS} 2>>/tmp/comments-review-stderr-${SAFE_BRANCH}.txt; touch ${REVIEW_COMMENTS}.done"

# --- Wait for all four reviewers to complete (max 20 min) ---
TIMEOUT=1200
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  ALL_DONE=true
  [ -f "${REVIEW_CODEX}.done" ] || ALL_DONE=false
  [ -f "${REVIEW_CLAUDE}.done" ] || ALL_DONE=false
  [ -f "${REVIEW_COMPLIANCE}.done" ] || ALL_DONE=false
  [ -f "${REVIEW_COMMENTS}.done" ] || ALL_DONE=false

  if $ALL_DONE; then
    break
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

# Clean up tmux sessions
tmux kill-session -t "review-codex-${SAFE_BRANCH}" 2>/dev/null || true
tmux kill-session -t "review-claude-${SAFE_BRANCH}" 2>/dev/null || true
tmux kill-session -t "review-compliance-${SAFE_BRANCH}" 2>/dev/null || true
tmux kill-session -t "review-comments-${SAFE_BRANCH}" 2>/dev/null || true

# --- Aggregate results (prefer incremental audit.md, fallback to chat output) ---
# Use temp file to avoid shell escaping issues with large review outputs
COMMENT_FILE="/tmp/review-comment-${SAFE_BRANCH}.md"

# Helper: pick best output source (incremental file > chat output > timeout)
_get_review_output() {
  local audit_file="$1"
  local chat_file="$2"
  if [ -f "$audit_file" ] && [ -s "$audit_file" ]; then
    cat "$audit_file"
  elif [ -f "$chat_file" ] && [ -s "$chat_file" ]; then
    cat "$chat_file"
  else
    echo "⚠️ Review not generated or timed out"
  fi
}

CLAUDE_AUDIT_MD="${REVIEW_WORKDIR}/audit-claude.md"
CODEX_AUDIT_MD="${REVIEW_WORKDIR}/audit-codex.md"
COMPLIANCE_AUDIT_MD="${REVIEW_WORKDIR}/audit-compliance.md"
COMMENTS_AUDIT_MD="${REVIEW_WORKDIR}/audit-comments.md"

# Build comment via temp file (avoids variable escaping issues)
{
  echo "## 🔍 AI Code Review — 4-Lane Cross-Review"
  echo ""
  echo "### Lane 1 — Security Audit (Claude Opus 4.6)"
  echo ""
  _get_review_output "$CLAUDE_AUDIT_MD" "$REVIEW_CLAUDE"
  echo ""
  echo "---"
  echo ""
  echo "### Lane 2 — Security Audit (Codex GPT-5.4)"
  echo ""
  _get_review_output "$CODEX_AUDIT_MD" "$REVIEW_CODEX"
  echo ""
  echo "---"
  echo ""
  echo "### Lane 3 — Standards + Logic Compliance (Codex GPT-5.4)"
  echo ""
  _get_review_output "$COMPLIANCE_AUDIT_MD" "$REVIEW_COMPLIANCE"
  echo ""
  echo "---"
  echo ""
  echo "### Lane 4 — Comment Consistency (Sonnet 4.6)"
  echo ""
  _get_review_output "$COMMENTS_AUDIT_MD" "$REVIEW_COMMENTS"
  echo ""
} > "$COMMENT_FILE"

# Post to PR (GitHub comment limit: 65535 chars)
COMMENT_LEN=$(wc -c < "$COMMENT_FILE" | tr -d ' ')
if [ "$COMMENT_LEN" -gt 60000 ]; then
  # Split into two comments: Lane 1-2 (security) and Lane 3-4 (compliance+comments)
  COMMENT_PART1="/tmp/review-comment-part1-${SAFE_BRANCH}.md"
  COMMENT_PART2="/tmp/review-comment-part2-${SAFE_BRANCH}.md"
  {
    echo "## 🔍 AI Code Review — 4-Lane Cross-Review (Part 1/2: Security)"
    echo ""
    echo "### Lane 1 — Security Audit (Claude Opus 4.6)"
    echo ""
    _get_review_output "$CLAUDE_AUDIT_MD" "$REVIEW_CLAUDE"
    echo ""
    echo "---"
    echo ""
    echo "### Lane 2 — Security Audit (Codex GPT-5.4)"
    echo ""
    _get_review_output "$CODEX_AUDIT_MD" "$REVIEW_CODEX"
    echo ""
  } > "$COMMENT_PART1"
  {
    echo "## 🔍 AI Code Review — 4-Lane Cross-Review (Part 2/2: Compliance + Comments)"
    echo ""
    echo "### Lane 3 — Standards + Logic Compliance (Codex GPT-5.4)"
    echo ""
    _get_review_output "$COMPLIANCE_AUDIT_MD" "$REVIEW_COMPLIANCE"
    echo ""
    echo "---"
    echo ""
    echo "### Lane 4 — Comment Consistency (Sonnet 4.6)"
    echo ""
    _get_review_output "$COMMENTS_AUDIT_MD" "$REVIEW_COMMENTS"
    echo ""
  } > "$COMMENT_PART2"
  gh pr comment "$PR_NUM" --body-file "$COMMENT_PART1"
  gh pr comment "$PR_NUM" --body-file "$COMMENT_PART2"
  rm -f "$COMMENT_PART1" "$COMMENT_PART2"
  echo "Reviews posted to PR #${PR_NUM} (split into 2 comments due to length)"
else
  gh pr comment "$PR_NUM" --body-file "$COMMENT_FILE"
  echo "Reviews posted to PR #${PR_NUM}"
fi

# --- Determine review conclusion ---
RESULT_FILE="/tmp/review-result-${SAFE_BRANCH}.txt"
ISSUES_FILE="/tmp/review-issues-${SAFE_BRANCH}.txt"

if grep -q "REQUEST_CHANGES" "$COMMENT_FILE"; then
  REVIEW_STATUS="REQUEST_CHANGES"
else
  REVIEW_STATUS="APPROVE"
fi

echo "$REVIEW_STATUS" > "$RESULT_FILE"
grep -E "🔴|🟡|Critical|Warning" "$COMMENT_FILE" | head -50 > "$ISSUES_FILE" 2>/dev/null || true

echo "Review status: $REVIEW_STATUS"

# --- Review archiving removed (lean state rule: no auto doc generation) ---
# Reviews live in PR comments (GitHub). No local file archiving.

# --- PROJECT_CONTEXT.md handoff removed (do not write back into the project worktree) ---

# Clean up temp files
rm -f "$CODEX_TASK_FILE" "$CLAUDE_TASK_FILE" "$COMPLIANCE_TASK_FILE" "$COMMENTS_TASK_FILE"
rm -f "$REVIEW_CODEX" "$REVIEW_CLAUDE" "$REVIEW_COMPLIANCE" "$REVIEW_COMMENTS"
rm -f "${REVIEW_CODEX}.done" "${REVIEW_CLAUDE}.done" "${REVIEW_COMPLIANCE}.done" "${REVIEW_COMMENTS}.done"
rm -f "${REVIEW_CLAUDE}.json" "${REVIEW_COMMENTS}.json"
rm -f "$COMMENT_FILE"

notify "🔍 PR #${PR_NUM} review complete: ${REVIEW_STATUS} (branch: ${BRANCH})" || true
echo "review complete"

# Auto-trigger check-agents.sh to process review result immediately (don't wait for watchdog)
SCRIPTS_DIR_SELF="$(cd "$(dirname "$0")" && pwd)"
sleep 2
bash "${SCRIPTS_DIR_SELF}/check-agents.sh" > "/tmp/check-after-review-${SAFE_BRANCH}.log" 2>&1 || true
