#!/bin/bash
# init-project-context.sh — Generate PROJECT_CONTEXT.md for a project
#
# Usage: init-project-context.sh [project-path]
#        Defaults to current directory if no path given.

set -euo pipefail

PROJECT_DIR="${1:-.}"
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)
OUTPUT="${PROJECT_DIR}/PROJECT_CONTEXT.md"

if [ -f "$OUTPUT" ]; then
  echo "PROJECT_CONTEXT.md already exists at: $OUTPUT"
  echo "Edit it directly or delete it to regenerate."
  exit 0
fi

# --- Auto-detect project info ---
PROJECT_NAME=$(basename "$PROJECT_DIR")

# Detect project type
PROJECT_TYPE="general"
if ls "$PROJECT_DIR"/foundry.toml 2>/dev/null | grep -q .; then
  PROJECT_TYPE="solidity"
elif ls "$PROJECT_DIR"/package.json 2>/dev/null | grep -q .; then
  if grep -q '"react"' "$PROJECT_DIR/package.json" 2>/dev/null; then
    PROJECT_TYPE="frontend"
  else
    PROJECT_TYPE="backend-node"
  fi
elif ls "$PROJECT_DIR"/requirements.txt "$PROJECT_DIR"/pyproject.toml 2>/dev/null | grep -q . 2>/dev/null; then
  PROJECT_TYPE="backend-python"
elif ls "$PROJECT_DIR"/Cargo.toml 2>/dev/null | grep -q .; then
  PROJECT_TYPE="rust"
elif ls "$PROJECT_DIR"/go.mod 2>/dev/null | grep -q .; then
  PROJECT_TYPE="go"
fi

# Detect diff scope
case "$PROJECT_TYPE" in
  solidity)       DIFF_SCOPE="src/" ;;
  frontend)       DIFF_SCOPE="src/ components/ pages/ app/" ;;
  backend-node)   DIFF_SCOPE="src/ lib/ routes/ controllers/" ;;
  backend-python) DIFF_SCOPE="web_api/ cron/ lib/ model/" ;;
  rust)           DIFF_SCOPE="src/" ;;
  go)             DIFF_SCOPE="./" ;;
  *)              DIFF_SCOPE="src/" ;;
esac

# Map to review project type
case "$PROJECT_TYPE" in
  solidity)                    REVIEW_TYPE="solidity" ;;
  frontend)                    REVIEW_TYPE="frontend" ;;
  backend-node|backend-python) REVIEW_TYPE="backend" ;;
  *)                           REVIEW_TYPE="general" ;;
esac

# Detect top-level directories for architecture section
DIRS=$(ls -d "$PROJECT_DIR"/*/ 2>/dev/null | xargs -I{} basename {} | grep -v -E '^(node_modules|\.git|__pycache__|\.venv|out|cache|dist|build|target)$' | head -10)
DIRS_LIST=""
for d in $DIRS; do
  DIRS_LIST="${DIRS_LIST}
- \`${d}/\`: TODO — describe purpose"
done

cat > "$OUTPUT" << EOF
# ${PROJECT_NAME} — Project Context

## Overview
TODO — One-line description of what this project does.
Tech: TODO — language, framework, key dependencies.

## Architecture
${DIRS_LIST}

## Code Standards
- TODO — formatting, linting, test requirements
- Commits: atomic, \`fix/feat/refactor/docs/test\` prefixes

## Known Pitfalls
- TODO — document gotchas as you discover them

## Security Model
- owner/admin roles are trusted — do not report their privileged actions
- Focus on unprivileged user escalation paths
- TODO — project-specific security concerns

## Review Config
diff_scope: ${DIFF_SCOPE}
project_type: ${REVIEW_TYPE}

<!-- handoff:start -->
## Last Handoff
- Agent: (none)
- Time: —
- Task: —
- Result: —
- Next: —
<!-- handoff:end -->
EOF

echo "✅ Created: $OUTPUT"
echo "   Type detected: $PROJECT_TYPE"
echo "   Edit the TODO sections, then you're good to go."
