#!/usr/bin/env bash
# Layer 3a: Agent-in-the-loop negative test — no suitable skill found
#
# Verifies the agent handles the "no match" path gracefully when searching
# for a skill that doesn't exist in the catalog. The agent should:
#   - Search the Clarmory API
#   - NOT install any irrelevant skills
#   - Report that no suitable skill was found
#   - NOT leave orphaned reviews
#   - Continue with alternative approaches or report inability
#
# Prerequisites:
#   - Node.js + npm available
#   - claude CLI available on PATH
#   - wrangler dev running on localhost:8787 (or use --skip-wrangler)
#
# Usage:
#   ./tests/e2e/no-match-test.sh [--keep-temp] [--skip-wrangler]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
API_DIR="$PROJECT_ROOT/api"
API_URL="http://localhost:8787"
KEEP_TEMP=false
SKIP_WRANGLER=false
WRANGLER_PID=""
TEMP_DIR=""

# --- Parse args ---
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-temp) KEEP_TEMP=true ;;
    --skip-wrangler) SKIP_WRANGLER=true ;;
  esac
  shift
done

# --- Cleanup ---
cleanup() {
  echo ""
  echo "--- Cleanup ---"

  if [ -n "$WRANGLER_PID" ] && kill -0 "$WRANGLER_PID" 2>/dev/null; then
    echo "  Stopping wrangler dev (PID $WRANGLER_PID)..."
    kill "$WRANGLER_PID" 2>/dev/null || true
    wait "$WRANGLER_PID" 2>/dev/null || true
  fi

  if [ "$KEEP_TEMP" = "false" ] && [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    echo "  Removing temp dir: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
  elif [ -n "$TEMP_DIR" ]; then
    echo "  Keeping temp dir for debugging: $TEMP_DIR"
  fi
}
trap cleanup EXIT

# --- Helpers ---
PASS=0
FAIL=0

checkpoint_pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

checkpoint_fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

wait_for_api() {
  local max_wait=30
  local waited=0
  while [ $waited -lt $max_wait ]; do
    if curl -s -o /dev/null -w '%{http_code}' "$API_URL/search?q=test" 2>/dev/null | grep -q '200'; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

echo "=== Clarmory No-Match Negative Test ==="
echo "Project root: $PROJECT_ROOT"
echo "API URL: $API_URL"
echo ""

# -------------------------------------------------------
# Step 1: Start wrangler dev (or verify it's running)
# -------------------------------------------------------
echo "--- Step 1: API Server ---"

if [ "$SKIP_WRANGLER" = "true" ]; then
  echo "  Skipping wrangler start (--skip-wrangler)"
  if ! curl -s -o /dev/null "$API_URL/search?q=test" 2>/dev/null; then
    echo "  ERROR: wrangler dev not reachable at $API_URL"
    exit 1
  fi
  echo "  Verified: wrangler dev is running at $API_URL"
else
  echo "  Starting wrangler dev..."

  if curl -s -o /dev/null "$API_URL/search?q=test" 2>/dev/null; then
    echo "  WARNING: Something already listening on $API_URL — using it"
  else
    cd "$API_DIR"
    npx wrangler dev --port 8787 > /tmp/clarmory-wrangler-nomatch.log 2>&1 &
    WRANGLER_PID=$!
    cd "$PROJECT_ROOT"

    echo "  Waiting for API to become ready (PID $WRANGLER_PID)..."
    if ! wait_for_api; then
      echo "  ERROR: wrangler dev failed to start within 30s"
      tail -20 /tmp/clarmory-wrangler-nomatch.log 2>/dev/null || true
      exit 1
    fi
    echo "  API ready at $API_URL"
  fi
fi

# -------------------------------------------------------
# Step 2: Seed the database
# -------------------------------------------------------
echo ""
echo "--- Step 2: Seed Database ---"

echo "  Seeding via POST $API_URL/admin/seed ..."
SEED_RESULT=$(curl -s -X POST "$API_URL/admin/seed")
SEED_OK=$(echo "$SEED_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if d.get('seeded') else 'false')
except:
    print('false')
" 2>/dev/null || echo "false")

if [ "$SEED_OK" = "true" ]; then
  echo "  Database seeded successfully via API"
else
  echo "  ERROR: Seeding via API failed: $SEED_RESULT"
  exit 1
fi

# Clear request log for clean baseline
curl -s -X POST "$API_URL/admin/clear-requests" > /dev/null

# Record manifest state before the test
MANIFEST="$HOME/.claude/clarmory/installed.json"
PRE_MANIFEST_COUNT=0
if [ -f "$MANIFEST" ]; then
  PRE_MANIFEST_COUNT=$(python3 -c "
import json
with open('$MANIFEST') as f:
    d = json.load(f)
print(len(d.get('installed', [])))
" 2>/dev/null || echo "0")
fi
echo "  Pre-test manifest entries: $PRE_MANIFEST_COUNT"

# -------------------------------------------------------
# Step 3: Create temporary project directory
# -------------------------------------------------------
echo ""
echo "--- Step 3: Create Temp Project ---"

TEMP_DIR=$(mktemp -d /tmp/clarmory-nomatch-XXXXXX)
echo "  Temp project: $TEMP_DIR"

git -C "$TEMP_DIR" init -q
git -C "$TEMP_DIR" commit --allow-empty -m "init" -q

cat > "$TEMP_DIR/README.md" << 'EOF'
# Test Project

This is a test project for quantum circuit simulation.
EOF

git -C "$TEMP_DIR" add -A
git -C "$TEMP_DIR" commit -m "add readme" -q

echo "  Git repo initialized with README.md"

# -------------------------------------------------------
# Step 4: Install Clarmory SKILL.md pointing at local API
# -------------------------------------------------------
echo ""
echo "--- Step 4: Install Clarmory Skill ---"

SKILL_DIR="$TEMP_DIR/.claude/skills/clarmory"
mkdir -p "$SKILL_DIR"

cat > "$SKILL_DIR/SKILL.md" << SKILLEOF
---
description: "Find, evaluate, install, and review Claude Code skills and extensions."
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, WebFetch
---

# Clarmory — Skill Discovery and Installation

Search the Clarmory API to find skills, install them, and submit reviews.

**API base**: $API_URL

## Searching

Use WebFetch or curl to search:

    WebFetch('$API_URL/search?q=QUERY')

Results include skill IDs, descriptions, ratings, and version info.

## Evaluating

Fetch details:

    WebFetch('$API_URL/skills/' + encodeURIComponent(SKILL_ID))

IMPORTANT: Skill IDs contain colons and slashes (e.g. github:user/repo/path).
You MUST URL-encode them in path segments.

## Installing

1. Try the content endpoint first:
   WebFetch('$API_URL/skills/' + encodeURIComponent(SKILL_ID) + '/content')
   If 404, fetch from the source_url in the skill detail.

2. Write the skill to .claude/skills/SKILL_NAME/SKILL.md

3. Update manifest at ~/.claude/clarmory/installed.json

## Important: No-Match Handling

If no search results are relevant to the task, do NOT install an irrelevant skill.
Report that no suitable skill was found and proceed with alternative approaches
or report that you cannot complete the task without the required tooling.
SKILLEOF

cat > "$TEMP_DIR/.claude/CLAUDE.md" << 'EOF'
# Test Project

When you need a tool or skill you don't have, use the Clarmory skill to search
for and install one.

@skills/clarmory/SKILL.md
EOF

echo "  Clarmory skill installed at $SKILL_DIR/SKILL.md"
echo "  API URL configured: $API_URL"

# -------------------------------------------------------
# Step 5: Run claude -p with a niche task prompt
# -------------------------------------------------------
echo ""
echo "--- Step 5: Run Agent Session (niche task) ---"

TEST_PROMPT="Use the Clarmory skill (see .claude/skills/clarmory/SKILL.md) to find a skill for quantum circuit simulation and qubit state visualization.

Search the Clarmory API for a quantum computing skill. If no suitable skill is found in the results, report that no match was found. Do NOT install any skill that is not specifically about quantum computing or circuit simulation — installing an unrelated skill would be worse than installing nothing.

Make all API calls directly using WebFetch or curl. Do NOT try to spawn subagents or use SendMessage."

echo "  Prompt: (quantum circuit simulation search)"
echo "  Starting claude -p session..."
echo ""

AGENT_OUTPUT_FILE="$TEMP_DIR/.agent-output.txt"

if (cd "$TEMP_DIR" && timeout 300 claude -p \
  --dangerously-skip-permissions \
  --output-format text \
  --model sonnet \
  "$TEST_PROMPT") \
  > "$AGENT_OUTPUT_FILE" 2>&1; then
  echo "  Agent session completed successfully"
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "  WARNING: Agent session timed out after 5 minutes"
  else
    echo "  WARNING: Agent session exited with code $EXIT_CODE"
  fi
fi

echo ""
echo "  --- Agent Output (last 30 lines) ---"
tail -30 "$AGENT_OUTPUT_FILE" 2>/dev/null || echo "  (no output)"
echo "  --- End Agent Output ---"
echo ""

# -------------------------------------------------------
# Step 6: Verify Checkpoints
# -------------------------------------------------------
echo "--- Step 6: Verify Checkpoints ---"
echo ""

# Checkpoint (a): Agent searched the API
echo "  (a) Searched:"
REQUEST_LOG=$(curl -s "$API_URL/admin/request-log?path=/search" 2>/dev/null || echo "[]")
SEARCH_COUNT=$(echo "$REQUEST_LOG" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    entries = d.get('entries', d if isinstance(d, list) else [])
    print(len(entries))
except:
    print(0)
" 2>/dev/null || echo "0")

SEARCH_IN_OUTPUT=$(grep -ciE "search|clarmory|no.*result|no.*match|no.*found" "$AGENT_OUTPUT_FILE" 2>/dev/null || echo "0")

if [ "$SEARCH_COUNT" -gt 0 ]; then
  checkpoint_pass "API request log shows $SEARCH_COUNT search request(s)"
elif [ "$SEARCH_IN_OUTPUT" -gt 0 ]; then
  checkpoint_pass "Agent output mentions search activity ($SEARCH_IN_OUTPUT mentions)"
else
  checkpoint_fail "No evidence of search activity"
fi

# Checkpoint (b): Agent did NOT install any skills
echo ""
echo "  (b) Did NOT install:"

# Check for new skill files (excluding the clarmory skill itself)
NEW_SKILLS=$(find "$TEMP_DIR/.claude/skills" -name "SKILL.md" -not -path "*/clarmory/*" 2>/dev/null | wc -l)

if [ "$NEW_SKILLS" -eq 0 ]; then
  checkpoint_pass "No new skill files installed"
else
  checkpoint_fail "Agent installed $NEW_SKILLS skill file(s) — should not have installed anything"
  find "$TEMP_DIR/.claude/skills" -name "SKILL.md" -not -path "*/clarmory/*" 2>/dev/null | while read -r f; do
    echo "    - ${f#$TEMP_DIR/}"
  done
fi

# Check manifest wasn't updated
POST_MANIFEST_COUNT=0
if [ -f "$MANIFEST" ]; then
  POST_MANIFEST_COUNT=$(python3 -c "
import json
with open('$MANIFEST') as f:
    d = json.load(f)
print(len(d.get('installed', [])))
" 2>/dev/null || echo "0")
fi

if [ "$POST_MANIFEST_COUNT" -le "$PRE_MANIFEST_COUNT" ]; then
  checkpoint_pass "Manifest not updated (before: $PRE_MANIFEST_COUNT, after: $POST_MANIFEST_COUNT)"
else
  checkpoint_fail "Manifest grew from $PRE_MANIFEST_COUNT to $POST_MANIFEST_COUNT entries"
fi

# Checkpoint (c): Agent reported no suitable skill found
echo ""
echo "  (c) Reported no match:"

NO_MATCH_EVIDENCE=$(grep -ciE "no.*suitable|no.*match|no.*found|not.*found|no.*relevant|no.*quantum|doesn.t.*exist|couldn.t.*find|unable.*find|no.*skill.*for" "$AGENT_OUTPUT_FILE" 2>/dev/null || echo "0")

if [ "$NO_MATCH_EVIDENCE" -gt 0 ]; then
  checkpoint_pass "Agent reported no suitable skill ($NO_MATCH_EVIDENCE mentions)"
else
  checkpoint_fail "No evidence agent reported missing skill"
fi

# Checkpoint (d): No orphaned reviews
echo ""
echo "  (d) No orphaned reviews:"

REVIEW_REQUESTS=$(curl -s "$API_URL/admin/request-log?method=POST&path=/reviews" 2>/dev/null || echo "[]")
REVIEW_POST_COUNT=$(echo "$REVIEW_REQUESTS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    entries = d.get('entries', d if isinstance(d, list) else [])
    # Count only POST /reviews (not PATCH)
    posts = [e for e in entries if e.get('method') == 'POST' and e.get('path') == '/reviews']
    print(len(posts))
except:
    print(0)
" 2>/dev/null || echo "0")

if [ "$REVIEW_POST_COUNT" -eq 0 ]; then
  checkpoint_pass "No review submissions (clean no-match)"
else
  # Check if the reviews mention unsuitability — that's acceptable
  REVIEW_IN_OUTPUT=$(grep -ciE "review.*unsuitable\|not.*suitable\|no.*match.*review\|decline" "$AGENT_OUTPUT_FILE" 2>/dev/null || echo "0")
  if [ "$REVIEW_IN_OUTPUT" -gt 0 ]; then
    checkpoint_pass "Agent submitted $REVIEW_POST_COUNT review(s) but noted unsuitability"
  else
    checkpoint_fail "Agent submitted $REVIEW_POST_COUNT review(s) for an irrelevant skill"
  fi
fi

# Checkpoint (e): Agent handled gracefully (continued or reported inability)
echo ""
echo "  (e) Graceful handling:"

GRACEFUL=$(grep -ciE "alternative|instead|without|manual|cannot|can.t|proceed|unfortunately|not available" "$AGENT_OUTPUT_FILE" 2>/dev/null || echo "0")

if [ "$GRACEFUL" -gt 0 ]; then
  checkpoint_pass "Agent handled gracefully ($GRACEFUL mentions of alternatives/limitations)"
else
  # Even if no explicit alternative, not installing is itself graceful
  if [ "$NEW_SKILLS" -eq 0 ]; then
    checkpoint_pass "Agent refrained from installing — graceful by omission"
  else
    checkpoint_fail "No evidence of graceful handling"
  fi
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
TOTAL=$((PASS + FAIL))
echo ""
echo "==========================================="
echo "  No-Match Negative Test Results"
echo "  PASSED: $PASS / $TOTAL checkpoints"
echo "  FAILED: $FAIL / $TOTAL checkpoints"
echo "==========================================="
echo ""

if [ "$KEEP_TEMP" = "true" ] || [ "$FAIL" -gt 0 ]; then
  echo "Temp dir preserved for inspection: $TEMP_DIR"
  echo "Agent output: $AGENT_OUTPUT_FILE"
  KEEP_TEMP=true
fi

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
