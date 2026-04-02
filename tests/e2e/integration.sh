#!/usr/bin/env bash
# Layer 2: Scripted integration test for Clarmory API
#
# Exercises the full SKILL.md contract against a running wrangler dev instance:
#   1. Search for a skill by keyword
#   2. Get skill details by ID
#   3. Fetch reviews for a skill
#   4. Create a code_review stage review (POST /reviews)
#   5. Append user_decision stage (PATCH /reviews/:key)
#   6. Append post_use stage (PATCH /reviews/:key)
#   7. Verify the review appears in subsequent search results with correct stats
#
# Prerequisites:
#   - wrangler dev running on $API_URL (default http://localhost:8787)
#   - D1 seeded with schema.sql + seed.sql
#
# Usage:
#   ./tests/e2e/integration.sh [API_URL]

set -euo pipefail

API_URL="${1:-http://localhost:8787}"
PASS=0
FAIL=0
TESTS=0

# --- Helpers ---

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
  TESTS=$((TESTS + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
  TESTS=$((TESTS + 1))
}

assert_status() {
  local expected="$1" actual="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label (HTTP $actual)"
  else
    fail "$label — expected HTTP $expected, got $actual"
  fi
}

assert_json_field() {
  local json="$1" field="$2" expected="$3" label="$4"
  local actual
  actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d${field})" 2>/dev/null || echo "__MISSING__")
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label — expected '$expected', got '$actual'"
  fi
}

assert_json_field_exists() {
  local json="$1" field="$2" label="$3"
  local actual
  actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d${field}; print('exists' if v is not None else 'none')" 2>/dev/null || echo "__MISSING__")
  if [ "$actual" = "exists" ]; then
    pass "$label"
  else
    fail "$label — field not found or null"
  fi
}

assert_json_field_gt() {
  local json="$1" field="$2" threshold="$3" label="$4"
  local actual
  actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d${field})" 2>/dev/null || echo "0")
  if python3 -c "exit(0 if $actual > $threshold else 1)" 2>/dev/null; then
    pass "$label ($actual > $threshold)"
  else
    fail "$label — expected > $threshold, got $actual"
  fi
}

http_get() {
  local url="$1"
  local status body
  body=$(curl -s -w '\n%{http_code}' "$url")
  status=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  echo "$status"
  echo "$body"
}

http_post() {
  local url="$1" data="$2"
  local body status
  body=$(curl -s -w '\n%{http_code}' -X POST "$url" -H "Content-Type: application/json" -d "$data")
  status=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  echo "$status"
  echo "$body"
}

http_patch() {
  local url="$1" data="$2"
  local body status
  body=$(curl -s -w '\n%{http_code}' -X PATCH "$url" -H "Content-Type: application/json" -d "$data")
  status=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  echo "$status"
  echo "$body"
}

echo "=== Clarmory Layer 2 Integration Test ==="
echo "API: $API_URL"
echo ""

# -------------------------------------------------------
# Test 1: Search for a skill
# -------------------------------------------------------
echo "--- 1. Search ---"

RESPONSE=$(http_get "$API_URL/search?q=security+audit")
STATUS=$(echo "$RESPONSE" | head -n1)
BODY=$(echo "$RESPONSE" | tail -n +2)

assert_status "200" "$STATUS" "GET /search returns 200"
assert_json_field_exists "$BODY" "['results']" "Response has 'results' array"

# Should find the Trail of Bits security audit skill
FOUND_SECURITY=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
matches = [r for r in d.get('results', []) if 'security' in r.get('name', '').lower() or 'security' in r.get('description', '').lower()]
print(len(matches))
" 2>/dev/null || echo "0")

if [ "$FOUND_SECURITY" -gt 0 ]; then
  pass "Search for 'security audit' returns relevant results ($FOUND_SECURITY matches)"
else
  fail "Search for 'security audit' returned no security-related results"
fi

# Extract the first result's ID for later use
SKILL_ID=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('results', [])
if results:
    print(results[0]['id'])
else:
    print('')
" 2>/dev/null || echo "")

if [ -n "$SKILL_ID" ]; then
  pass "Extracted skill ID: $SKILL_ID"
else
  fail "Could not extract skill ID from search results"
  echo "FATAL: Cannot continue without a skill ID"
  echo ""
  echo "=== Results: $PASS passed, $FAIL failed, $TESTS total ==="
  exit 1
fi

# Check inclusion_reason is present
INCLUSION=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('results', [{}])[0]
print(r.get('inclusion_reason', ''))
" 2>/dev/null || echo "")

if [ -n "$INCLUSION" ]; then
  pass "Result has inclusion_reason: $INCLUSION"
else
  fail "Result missing inclusion_reason"
fi

# Check reviews metadata in search results
REVIEWS_IN_SEARCH=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('results', [{}])[0]
print('yes' if 'reviews' in r else 'no')
" 2>/dev/null || echo "no")

if [ "$REVIEWS_IN_SEARCH" = "yes" ]; then
  pass "Search results include review metadata"
else
  fail "Search results missing review metadata"
fi

# Check version_info in search results
VERSION_IN_SEARCH=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('results', [{}])[0]
print('yes' if 'version_info' in r else 'no')
" 2>/dev/null || echo "no")

if [ "$VERSION_IN_SEARCH" = "yes" ]; then
  pass "Search results include version_info"
else
  fail "Search results missing version_info"
fi

# Check version_uncertain field exists in version_info
VERSION_UNCERTAIN=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('results', [{}])[0]
vi = r.get('version_info', {})
print('yes' if 'version_uncertain' in vi else 'no')
" 2>/dev/null || echo "no")

if [ "$VERSION_UNCERTAIN" = "yes" ]; then
  pass "version_info includes version_uncertain field"
else
  fail "version_info missing version_uncertain field"
fi

# Search with type filter
echo ""
echo "--- 1b. Search with type filter ---"

RESPONSE=$(http_get "$API_URL/search?q=database&type=mcp")
STATUS=$(echo "$RESPONSE" | head -n1)
BODY=$(echo "$RESPONSE" | tail -n +2)

assert_status "200" "$STATUS" "GET /search?type=mcp returns 200"

MCP_ONLY=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('results', [])
non_mcp = [r for r in results if not r.get('type', '').startswith('mcp')]
print(len(non_mcp))
" 2>/dev/null || echo "999")

if [ "$MCP_ONLY" = "0" ]; then
  pass "Type filter returns only MCP results"
else
  fail "Type filter leaked non-MCP results ($MCP_ONLY non-MCP)"
fi

# -------------------------------------------------------
# Test 2: Get skill details
# -------------------------------------------------------
echo ""
echo "--- 2. Skill Details ---"

RESPONSE=$(http_get "$API_URL/skills/$SKILL_ID")
STATUS=$(echo "$RESPONSE" | head -n1)
BODY=$(echo "$RESPONSE" | tail -n +2)

assert_status "200" "$STATUS" "GET /skills/:id returns 200"
assert_json_field "$BODY" "['id']" "$SKILL_ID" "Skill ID matches"
assert_json_field_exists "$BODY" "['name']" "Has name"
assert_json_field_exists "$BODY" "['description']" "Has description"
assert_json_field_exists "$BODY" "['source_url']" "Has source_url"
assert_json_field_exists "$BODY" "['version_hash']" "Has version_hash"

# Should include review summary
REVIEW_SUMMARY=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('yes' if 'reviews' in d else 'no')
" 2>/dev/null || echo "no")

if [ "$REVIEW_SUMMARY" = "yes" ]; then
  pass "Skill detail includes review summary"
else
  fail "Skill detail missing review summary"
fi

# Extract version_hash for review creation
VERSION_HASH=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('version_hash', ''))
" 2>/dev/null || echo "")

# 404 for nonexistent skill
RESPONSE=$(http_get "$API_URL/skills/nonexistent-skill-id")
STATUS=$(echo "$RESPONSE" | head -n1)
assert_status "404" "$STATUS" "GET /skills/:id returns 404 for unknown ID"

# -------------------------------------------------------
# Test 3: Get reviews for a skill (initially may be empty)
# -------------------------------------------------------
echo ""
echo "--- 3. Fetch Reviews ---"

RESPONSE=$(http_get "$API_URL/skills/$SKILL_ID/reviews")
STATUS=$(echo "$RESPONSE" | head -n1)
BODY=$(echo "$RESPONSE" | tail -n +2)

assert_status "200" "$STATUS" "GET /skills/:id/reviews returns 200"

# Count initial reviews for later comparison
INITIAL_REVIEW_COUNT=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
reviews = d.get('reviews', d if isinstance(d, list) else [])
print(len(reviews))
" 2>/dev/null || echo "0")

echo "  (Initial review count: $INITIAL_REVIEW_COUNT)"

# -------------------------------------------------------
# Test 4: Create a code_review (POST /reviews)
# -------------------------------------------------------
echo ""
echo "--- 4. Create Code Review ---"

AGENT_ID="integration-test-$$"

REVIEW_DATA=$(cat <<ENDJSON
{
  "agent_id": "$AGENT_ID",
  "extension_id": "$SKILL_ID",
  "version_hash": "$VERSION_HASH",
  "stage": "code_review",
  "security_ok": true,
  "quality_rating": 4,
  "summary": "Integration test code review. Clean skill, well-scoped.",
  "findings": "Good structure, clear documentation.",
  "suggested_improvements": "Add error handling for edge cases."
}
ENDJSON
)

RESPONSE=$(http_post "$API_URL/reviews" "$REVIEW_DATA")
STATUS=$(echo "$RESPONSE" | head -n1)
BODY=$(echo "$RESPONSE" | tail -n +2)

assert_status "201" "$STATUS" "POST /reviews returns 201"

REVIEW_KEY=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('review_key', ''))
" 2>/dev/null || echo "")

if [ -n "$REVIEW_KEY" ]; then
  pass "Review created with key: $REVIEW_KEY"
else
  fail "POST /reviews did not return a review_key"
  echo "FATAL: Cannot continue without a review key"
  echo ""
  echo "=== Results: $PASS passed, $FAIL failed, $TESTS total ==="
  exit 1
fi

CREATED_FLAG=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('created', ''))
" 2>/dev/null || echo "")

assert_json_field "$BODY" "['created']" "True" "Response confirms created=true"

# -------------------------------------------------------
# Test 5: Append user_decision stage (PATCH /reviews/:key)
# -------------------------------------------------------
echo ""
echo "--- 5. Append User Decision (installed) ---"

DECISION_DATA=$(cat <<'ENDJSON'
{
  "stage": "user_decision",
  "installed": true
}
ENDJSON
)

RESPONSE=$(http_patch "$API_URL/reviews/$REVIEW_KEY" "$DECISION_DATA")
STATUS=$(echo "$RESPONSE" | head -n1)
BODY=$(echo "$RESPONSE" | tail -n +2)

assert_status "200" "$STATUS" "PATCH /reviews/:key (user_decision) returns 200"

# API returns {review_key, stages_count} — verify count
STAGE_COUNT=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('stages_count', 0))
" 2>/dev/null || echo "0")

if [ "$STAGE_COUNT" = "2" ]; then
  pass "Review now has 2 stages (code_review + user_decision)"
else
  fail "Expected 2 stages, got $STAGE_COUNT"
fi

# -------------------------------------------------------
# Test 6: Append post_use stage (PATCH /reviews/:key)
# -------------------------------------------------------
echo ""
echo "--- 6. Append Post-Use Review ---"

POSTUSE_DATA=$(cat <<'ENDJSON'
{
  "stage": "post_use",
  "worked": true,
  "rating": 4,
  "task_summary": "Integration test: used skill for automated security scanning.",
  "what_worked": "Structured findings output was easy to parse.",
  "what_didnt": "Scan was slow on large files.",
  "suggested_improvements": "Add incremental scanning for large codebases."
}
ENDJSON
)

RESPONSE=$(http_patch "$API_URL/reviews/$REVIEW_KEY" "$POSTUSE_DATA")
STATUS=$(echo "$RESPONSE" | head -n1)
BODY=$(echo "$RESPONSE" | tail -n +2)

assert_status "200" "$STATUS" "PATCH /reviews/:key (post_use) returns 200"

# Verify stages now has 3 entries
STAGE_COUNT=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
stages = d.get('stages', [])
print(len(stages))
" 2>/dev/null || echo "0")

if [ "$STAGE_COUNT" = "3" ]; then
  pass "Review now has 3 stages (code_review + user_decision + post_use)"
else
  fail "Expected 3 stages, got $STAGE_COUNT"
fi

# Verify rating was set
RATING=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('rating', ''))
" 2>/dev/null || echo "")

assert_json_field "$BODY" "['rating']" "4" "Rating is 4 after post_use"

# -------------------------------------------------------
# Test 7: PATCH nonexistent review returns 404
# -------------------------------------------------------
echo ""
echo "--- 7. Error Cases ---"

RESPONSE=$(http_patch "$API_URL/reviews/rv_nonexistent" '{"stage": "post_use", "worked": false, "rating": 1}')
STATUS=$(echo "$RESPONSE" | head -n1)
assert_status "404" "$STATUS" "PATCH /reviews/:key returns 404 for unknown key"

# POST review with missing required fields (no agent_id, no extension_id)
RESPONSE=$(http_post "$API_URL/reviews" '{"stage": "code_review"}')
STATUS=$(echo "$RESPONSE" | head -n1)
if [ "$STATUS" = "400" ] || [ "$STATUS" = "422" ]; then
  pass "POST /reviews rejects missing agent_id + extension_id (HTTP $STATUS)"
else
  fail "POST /reviews with missing fields returned HTTP $STATUS (expected 400 or 422)"
fi

# POST review with agent_id but missing extension_id
RESPONSE=$(http_post "$API_URL/reviews" '{"agent_id": "test", "stage": "code_review"}')
STATUS=$(echo "$RESPONSE" | head -n1)
if [ "$STATUS" = "400" ] || [ "$STATUS" = "422" ]; then
  pass "POST /reviews rejects missing extension_id (HTTP $STATUS)"
else
  fail "POST /reviews missing extension_id returned HTTP $STATUS (expected 400 or 422)"
fi

# -------------------------------------------------------
# Test 8: Verify review appears in search results
# -------------------------------------------------------
echo ""
echo "--- 8. Verify Reviews in Search Results ---"

RESPONSE=$(http_get "$API_URL/search?q=security+audit")
STATUS=$(echo "$RESPONSE" | head -n1)
BODY=$(echo "$RESPONSE" | tail -n +2)

assert_status "200" "$STATUS" "Search still returns 200"

# Find our skill in results and check review stats
REVIEW_STATS=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('results', []):
    if r.get('id') == '$SKILL_ID':
        stats = r.get('reviews', {})
        print(json.dumps(stats))
        sys.exit(0)
print('{}')
" 2>/dev/null || echo "{}")

POST_USE_COUNT=$(echo "$REVIEW_STATS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('post_use', d.get('post_use_reviews', 0)))
" 2>/dev/null || echo "0")

if [ "$POST_USE_COUNT" -gt 0 ]; then
  pass "Search results reflect our post-use review (post_use count: $POST_USE_COUNT)"
else
  fail "Search results don't reflect our post-use review (post_use count: $POST_USE_COUNT)"
fi

# Check that avg_rating is populated
AVG_RATING=$(echo "$REVIEW_STATS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('avg_rating', 0)
print(r if r else 0)
" 2>/dev/null || echo "0")

if python3 -c "exit(0 if float($AVG_RATING) > 0 else 1)" 2>/dev/null; then
  pass "Search results include avg_rating ($AVG_RATING)"
else
  fail "Search results missing or zero avg_rating"
fi

# -------------------------------------------------------
# Test 9: Verify review appears in skill detail
# -------------------------------------------------------
echo ""
echo "--- 9. Verify Reviews in Skill Detail ---"

RESPONSE=$(http_get "$API_URL/skills/$SKILL_ID")
STATUS=$(echo "$RESPONSE" | head -n1)
BODY=$(echo "$RESPONSE" | tail -n +2)

assert_status "200" "$STATUS" "Skill detail returns 200"

DETAIL_REVIEW_COUNT=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
stats = d.get('reviews', {})
print(stats.get('total', stats.get('review_count', 0)))
" 2>/dev/null || echo "0")

if [ "$DETAIL_REVIEW_COUNT" -gt 0 ]; then
  pass "Skill detail reflects review count ($DETAIL_REVIEW_COUNT)"
else
  fail "Skill detail review count is 0"
fi

# -------------------------------------------------------
# Test 10: Verify review in reviews list
# -------------------------------------------------------
echo ""
echo "--- 10. Verify Review in Reviews List ---"

RESPONSE=$(http_get "$API_URL/skills/$SKILL_ID/reviews")
STATUS=$(echo "$RESPONSE" | head -n1)
BODY=$(echo "$RESPONSE" | tail -n +2)

assert_status "200" "$STATUS" "GET /skills/:id/reviews returns 200"

FOUND_OUR_REVIEW=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
reviews = d.get('reviews', d if isinstance(d, list) else [])
for r in reviews:
    if r.get('review_key') == '$REVIEW_KEY':
        print('yes')
        sys.exit(0)
print('no')
" 2>/dev/null || echo "no")

if [ "$FOUND_OUR_REVIEW" = "yes" ]; then
  pass "Our review ($REVIEW_KEY) appears in the reviews list"
else
  fail "Our review ($REVIEW_KEY) not found in reviews list"
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "==========================================="
echo "  Layer 2 Integration Test Results"
echo "  PASSED: $PASS"
echo "  FAILED: $FAIL"
echo "  TOTAL:  $TESTS"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
