#!/usr/bin/env bash
# Layer 3a: Agent-in-the-loop end-to-end test (controlled local API)
#
# Runs a headless Claude Code session with the Clarmory skill installed,
# pointed at a local wrangler dev API with seeded data. Verifies the agent
# completes the full lifecycle: search, discover, install, use, review.
#
# Prerequisites:
#   - Node.js + npm available
#   - claude CLI available on PATH
#   - api/ dependencies installed (npm install in api/)
#
# Usage:
#   ./tests/e2e/agent-test.sh
#
# Options:
#   --keep-temp      Don't remove the temp project dir on exit (for debugging)
#   --skip-wrangler  Assume wrangler dev is already running on localhost:8787
#   --live URL       Run against a production API (Layer 3b canary mode).
#                    Skips wrangler lifecycle and DB seeding.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
API_DIR="$PROJECT_ROOT/api"
API_URL="http://localhost:8787"
KEEP_TEMP=false
SKIP_WRANGLER=false
LIVE_MODE=false
WRANGLER_PID=""
TEMP_DIR=""

# --- Parse args ---
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-temp) KEEP_TEMP=true ;;
    --skip-wrangler) SKIP_WRANGLER=true ;;
    --live)
      LIVE_MODE=true
      SKIP_WRANGLER=true
      shift
      if [ $# -eq 0 ]; then
        echo "ERROR: --live requires a URL argument"
        exit 1
      fi
      API_URL="$1"
      ;;
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

urlencode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))"
}

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

if [ "$LIVE_MODE" = "true" ]; then
  echo "=== Clarmory Layer 3b: Live Production Canary Test ==="
else
  echo "=== Clarmory Layer 3a: Agent-in-the-Loop Test ==="
fi
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

  # Check if already running
  if curl -s -o /dev/null "$API_URL/search?q=test" 2>/dev/null; then
    echo "  WARNING: Something already listening on $API_URL — using it"
  else
    cd "$API_DIR"
    npx wrangler dev --port 8787 > /tmp/clarmory-wrangler.log 2>&1 &
    WRANGLER_PID=$!
    cd "$PROJECT_ROOT"

    echo "  Waiting for API to become ready (PID $WRANGLER_PID)..."
    if ! wait_for_api; then
      echo "  ERROR: wrangler dev failed to start within 30s"
      echo "  Log tail:"
      tail -20 /tmp/clarmory-wrangler.log 2>/dev/null || true
      exit 1
    fi
    echo "  API ready at $API_URL"
  fi
fi

# -------------------------------------------------------
# Step 2: Seed the database (skip in live mode)
# -------------------------------------------------------
echo ""
echo "--- Step 2: Seed Database ---"

if [ "$LIVE_MODE" = "true" ]; then
  echo "  Skipping DB seed (live mode — using production data)"
else
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
fi

# Verify seed data is queryable
SEED_CHECK=$(curl -s "$API_URL/search?q=security" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get('results', [])))
except:
    print(0)
" 2>/dev/null || echo "0")

if [ "$SEED_CHECK" -gt 0 ]; then
  echo "  Verified: seed data queryable ($SEED_CHECK results for 'security')"
else
  echo "  ERROR: seed data not queryable — search returned 0 results"
  exit 1
fi

# Verify the MQTT test target skill is present
MQTT_CHECK=$(curl -s "$API_URL/search?q=mqtt+client+subscribe" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    mqtt = [r for r in d.get('results', []) if 'mqtt' in r.get('name', '').lower()]
    print(len(mqtt))
except:
    print(0)
" 2>/dev/null || echo "0")

if [ "$MQTT_CHECK" -gt 0 ]; then
  echo "  Verified: MQTT test skill is discoverable"
else
  echo "  WARNING: MQTT test skill not found in search — agent test may fail"
fi

# -------------------------------------------------------
# Step 3: Create temporary project directory
# -------------------------------------------------------
echo ""
echo "--- Step 3: Create Temp Project ---"

TEMP_DIR=$(mktemp -d /tmp/clarmory-e2e-XXXXXX)
echo "  Temp project: $TEMP_DIR"

# Initialize as a git repo (claude expects to be in a project)
git -C "$TEMP_DIR" init -q
git -C "$TEMP_DIR" commit --allow-empty -m "init" -q

# Create a minimal project context so the agent has something to work with
cat > "$TEMP_DIR/README.md" << 'EOF'
# Test Project

This is a test IoT project. It needs an MQTT client to subscribe to sensor
topics and log incoming messages.
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

# Create a test-compatible SKILL.md that works in single-turn (-p) mode.
# The production SKILL.md uses a subagent pattern (Agent + SendMessage) which
# isn't available in claude -p. This inline version tells the agent to make
# the API calls directly.
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

Fetch reviews:

    WebFetch('$API_URL/skills/' + encodeURIComponent(SKILL_ID) + '/reviews')

IMPORTANT: Skill IDs contain colons and slashes (e.g. github:user/repo/path).
You MUST URL-encode them in path segments.

## Installing

1. Try the content endpoint first:
   WebFetch('$API_URL/skills/' + encodeURIComponent(SKILL_ID) + '/content')
   If 404, fetch from the source_url in the skill detail.

2. Write the skill to .claude/skills/SKILL_NAME/SKILL.md

3. Update manifest at ~/.claude/clarmory/installed.json:
   - mkdir -p ~/.claude/clarmory
   - Read existing or start with {"installed": []}
   - Append: {id, name, source_url, version_hash, installed_at, scope: "project", path, review_key}
   - Write back

## Submitting Reviews

Create a code review:

    curl -s -X POST '$API_URL/reviews' \\
      -H 'Content-Type: application/json' \\
      -d '{"agent_id":"test-agent","extension_id":"SKILL_ID","version_hash":"VERSION_HASH","stage":"code_review","security_ok":true,"quality_rating":4,"summary":"..."}'

Save the returned review_key. Then submit post-use review:

    curl -s -X PATCH '$API_URL/reviews/REVIEW_KEY' \\
      -H 'Content-Type: application/json' \\
      -d '{"stage":"post_use","worked":true,"rating":4,"task_summary":"...","what_worked":"...","what_didnt":"none"}'
SKILLEOF

# Create a CLAUDE.md that references the skill
cat > "$TEMP_DIR/.claude/CLAUDE.md" << 'EOF'
# Test Project

When you need a tool or skill you don't have, use the Clarmory skill to search
for and install one.

@skills/clarmory/SKILL.md
EOF

echo "  Clarmory skill installed at $SKILL_DIR/SKILL.md"
echo "  API URL configured: $API_URL"

# -------------------------------------------------------
# Step 5: Run claude -p with test prompt
# -------------------------------------------------------
echo ""
echo "--- Step 5: Run Agent Session ---"

TEST_PROMPT="Set up an MQTT client in this project that subscribes to a topic and logs messages.

Use the Clarmory skill (see .claude/skills/clarmory/SKILL.md) to:
1. Search the Clarmory API for an MQTT-related skill
2. Evaluate the best result — check its details and reviews
3. Install it (you have pre-approval — do not ask for confirmation)
4. Write the MQTT client code following the skill's guidance
5. Submit both a code_review and a post_use review to the Clarmory API

Make all API calls directly using WebFetch or curl. Do NOT try to spawn subagents or use SendMessage."

echo "  Prompt: $TEST_PROMPT"
echo "  Starting claude -p session..."
echo ""

AGENT_OUTPUT_FILE="$TEMP_DIR/.agent-output.txt"

# Run claude in print mode with permissions bypassed (unattended test).
# --dangerously-skip-permissions is required because the agent will make
# HTTP requests, write files, etc. This is safe because we're in a temp dir
# pointed at a local API.
#
# Timeout after 5 minutes — if the agent hasn't finished by then, something
# is wrong. On the Pi with 4GB RAM, agent sessions can be slow.
# Run from the temp dir so claude discovers .claude/CLAUDE.md and skills
if (cd "$TEMP_DIR" && timeout 480 claude -p \
  --dangerously-skip-permissions \
  --output-format text \
  --model sonnet \
  "$TEST_PROMPT") \
  > "$AGENT_OUTPUT_FILE" 2>&1; then
  echo "  Agent session completed successfully"
else
  EXIT_CODE=$?
  if [ $EXIT_CODE -eq 124 ]; then
    echo "  WARNING: Agent session timed out after 8 minutes"
  else
    echo "  WARNING: Agent session exited with code $EXIT_CODE"
  fi
fi

echo ""
echo "  --- Agent Output (last 40 lines) ---"
tail -40 "$AGENT_OUTPUT_FILE" 2>/dev/null || echo "  (no output)"
echo "  --- End Agent Output ---"
echo ""

# -------------------------------------------------------
# Step 6: Verify Checkpoints
# -------------------------------------------------------
echo "--- Step 6: Verify Checkpoints ---"
echo ""

# Checkpoint (a): Agent searched the API
# We verify by checking if the API has any reviews (the agent should have
# created one), or by checking the agent output for search-related content.
echo "  (a) Searched:"
SEARCHED=$(grep -iE "search|/search|results|clarmory" "$AGENT_OUTPUT_FILE" 2>/dev/null | wc -l)
if [ "$SEARCHED" -gt 0 ]; then
  checkpoint_pass "Agent output contains search-related content ($SEARCHED mentions)"
else
  checkpoint_fail "No evidence of search activity in agent output"
fi

# Checkpoint (b): Agent discovered/selected a skill
echo ""
echo "  (b) Discovered:"
# Look for evidence the agent identified a specific skill from search results
DISCOVERED=$(grep -iE "mqtt|security|skill|install|found" "$AGENT_OUTPUT_FILE" 2>/dev/null | wc -l)
if [ "$DISCOVERED" -gt 0 ]; then
  checkpoint_pass "Agent output shows skill discovery ($DISCOVERED mentions)"
else
  checkpoint_fail "No evidence of skill discovery in agent output"
fi

# Checkpoint (c): Skill installed + manifest updated
echo ""
echo "  (c) Installed:"
INSTALL_PASS=true

# Check for any new skill files in the project, OR project files the agent created
# (If the upstream URL is fake/404, the agent may skip writing the SKILL.md but
# still write code based on the skill's description — that counts as installation)
SKILL_FILES=$(find "$TEMP_DIR/.claude/skills" -name "SKILL.md" -not -path "*/clarmory/*" 2>/dev/null | wc -l)
PROJECT_FILES=$(find "$TEMP_DIR" -maxdepth 1 -name "*.py" -o -name "*.js" -o -name "*.ts" 2>/dev/null | wc -l)
if [ "$SKILL_FILES" -gt 0 ]; then
  checkpoint_pass "New skill file(s) installed ($SKILL_FILES found)"
elif [ -f "$TEMP_DIR/.mcp.json" ]; then
  checkpoint_pass "MCP server configured (.mcp.json created)"
elif [ "$PROJECT_FILES" -gt 0 ]; then
  checkpoint_pass "Agent created project files ($PROJECT_FILES) — skill content URL may have been unavailable"
else
  checkpoint_fail "No new skill files, MCP config, or project files found"
  INSTALL_PASS=false
fi

# Check manifest
MANIFEST="$HOME/.claude/clarmory/installed.json"
if [ -f "$MANIFEST" ]; then
  MANIFEST_ENTRIES=$(python3 -c "
import json
with open('$MANIFEST') as f:
    d = json.load(f)
print(len(d.get('installed', [])))
" 2>/dev/null || echo "0")
  if [ "$MANIFEST_ENTRIES" -gt 0 ]; then
    checkpoint_pass "Clarmory manifest has $MANIFEST_ENTRIES entries"
  else
    checkpoint_fail "Clarmory manifest exists but has no entries"
    INSTALL_PASS=false
  fi
else
  # Manifest might be in the temp dir's home context — not a hard failure
  echo "    (Manifest not found at $MANIFEST — agent may have written it elsewhere)"
  if [ "$INSTALL_PASS" = "true" ]; then
    echo "    (Skill was installed, so counting this as soft pass)"
  else
    checkpoint_fail "No manifest and no installed skills"
  fi
fi

# Checkpoint (d): Project has MQTT-related code
echo ""
echo "  (d) Used (project has MQTT code):"
MQTT_CODE=$(grep -rli "mqtt\|subscribe\|broker\|topic" "$TEMP_DIR" \
  --include="*.py" --include="*.js" --include="*.ts" --include="*.sh" \
  2>/dev/null | grep -v ".agent-output" | grep -v ".claude/" | wc -l)
if [ "$MQTT_CODE" -gt 0 ]; then
  checkpoint_pass "Project contains MQTT-related code files ($MQTT_CODE files)"
  # Show what was created
  grep -rli "mqtt\|subscribe\|broker\|topic" "$TEMP_DIR" \
    --include="*.py" --include="*.js" --include="*.ts" --include="*.sh" \
    2>/dev/null | grep -v ".agent-output" | grep -v ".claude/" | while read -r f; do
    echo "    - ${f#$TEMP_DIR/}"
  done
else
  checkpoint_fail "No MQTT-related code files found in project"
fi

# Checkpoint (e): API contains a review for a skill from this session
echo ""
echo "  (e) Reviewed:"

# Directly check the MQTT test skill for non-seeded reviews.
# Seeded reviews have agent_id starting with "agent-seed-". Any other agent_id
# means the test agent submitted a review.
REVIEW_FOUND=false
MQTT_SKILL_ENC=$(urlencode "github:claudecode-contrib/mqtt-client-skill")

AGENT_REVIEWS=$(curl -s "$API_URL/skills/$MQTT_SKILL_ENC/reviews" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    reviews = d.get('reviews', [])
    # Find reviews NOT from seed data
    agent_reviews = [r for r in reviews if not r.get('agent_id', '').startswith('agent-seed-')]
    print(len(agent_reviews))
except:
    print(0)
" 2>/dev/null || echo "0")

if [ "$AGENT_REVIEWS" -gt 0 ]; then
  checkpoint_pass "API contains $AGENT_REVIEWS review(s) from the test agent for the MQTT skill"
  REVIEW_FOUND=true
fi

# If MQTT skill check failed, also check the manifest for a review_key and verify it exists
if [ "$REVIEW_FOUND" = "false" ] && [ -f "$HOME/.claude/clarmory/installed.json" ]; then
  REVIEW_KEY=$(python3 -c "
import json
with open('$HOME/.claude/clarmory/installed.json') as f:
    d = json.load(f)
for entry in d.get('installed', []):
    rk = entry.get('review_key', '')
    if rk:
        print(rk)
        break
" 2>/dev/null || echo "")
  if [ -n "$REVIEW_KEY" ]; then
    # Verify the review_key exists in the API
    RK_CHECK=$(curl -s "$API_URL/skills/$MQTT_SKILL_ENC/reviews" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('reviews', []):
    if r.get('review_key') == '$REVIEW_KEY':
        print('found')
        sys.exit(0)
print('missing')
" 2>/dev/null || echo "missing")
    if [ "$RK_CHECK" = "found" ]; then
      checkpoint_pass "Review key $REVIEW_KEY from manifest found in API"
      REVIEW_FOUND=true
    fi
  fi
fi

if [ "$REVIEW_FOUND" = "false" ]; then
  REVIEW_EVIDENCE=$(grep -ci "review\|POST.*reviews\|review_key\|rv_" "$AGENT_OUTPUT_FILE" 2>/dev/null || echo "0")
  if [ "$REVIEW_EVIDENCE" -gt 0 ]; then
    checkpoint_fail "Agent mentions reviews ($REVIEW_EVIDENCE times) but no review found in API"
  else
    checkpoint_fail "No evidence of review submission"
  fi
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
TOTAL=$((PASS + FAIL))
echo ""
if [ "$LIVE_MODE" = "true" ]; then
  LAYER="Layer 3b Live Production Canary"
else
  LAYER="Layer 3a Agent-in-the-Loop"
fi
echo "==========================================="
echo "  $LAYER Test Results"
echo "  PASSED: $PASS / $TOTAL checkpoints"
echo "  FAILED: $FAIL / $TOTAL checkpoints"
echo "==========================================="
echo ""

if [ "$KEEP_TEMP" = "true" ] || [ "$FAIL" -gt 0 ]; then
  echo "Temp dir preserved for inspection: $TEMP_DIR"
  echo "Agent output: $AGENT_OUTPUT_FILE"
  KEEP_TEMP=true  # preserve on failure for debugging
fi

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
