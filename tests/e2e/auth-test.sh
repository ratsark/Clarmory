#!/usr/bin/env bash
# Layer 2: Tiered trust auth and rate limiting integration tests
#
# Tests the two-tier auth system:
#   Tier 1 (anonymous): Ed25519 keypair — public key as identity, signed requests
#   Tier 2 (verified):  GitHub token — linked to real GitHub account
#
# Auth contract:
#   Headers: X-Clarmory-Public-Key (base64), X-Clarmory-Signature (base64)
#   Signature covers raw request body bytes
#   Missing headers -> 401, invalid signature -> 401
#   Identity auto-registered on first use (trust_level: "anonymous")
#
# Prerequisites:
#   - API running at $API_URL with tiered auth deployed
#   - DB seeded (schema + seed data)
#   - python3 with 'cryptography' module
#
# Usage:
#   ./tests/e2e/auth-test.sh [API_URL]

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

urlencode() {
  python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))"
}

http_status() {
  curl -s -o /dev/null -w '%{http_code}' "$@"
}

http_get() {
  local url="$1"; shift
  local body status
  body=$(curl -s -w '\n%{http_code}' "$url" "$@")
  status=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  echo "$status"
  echo "$body"
}

# --- Ed25519 key management ---

# Generate keypair. Sets PUB_KEY_B64 and PRIV_KEY_HEX.
generate_keypair() {
  local output
  output=$(python3 -c "
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
import base64

key = Ed25519PrivateKey.generate()
pub = key.public_key()
pub_bytes = pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
priv_bytes = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
print(base64.b64encode(pub_bytes).decode())
print(priv_bytes.hex())
")
  PUB_KEY_B64=$(echo "$output" | sed -n '1p')
  PRIV_KEY_HEX=$(echo "$output" | sed -n '2p')
}

# Sign a payload with the current PRIV_KEY_HEX. Returns base64 signature.
sign_body() {
  local payload="$1"
  python3 -c "
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
import base64, sys

key = Ed25519PrivateKey.from_private_bytes(bytes.fromhex('$PRIV_KEY_HEX'))
sig = key.sign(sys.argv[1].encode())
print(base64.b64encode(sig).decode())
" "$payload"
}

# POST with Ed25519 signature
signed_post() {
  local url="$1" data="$2"
  local sig
  sig=$(sign_body "$data")
  curl -s -w '\n%{http_code}' -X POST "$url" \
    -H "Content-Type: application/json" \
    -H "X-Clarmory-Public-Key: $PUB_KEY_B64" \
    -H "X-Clarmory-Signature: $sig" \
    -d "$data"
}

# PATCH with Ed25519 signature
signed_patch() {
  local url="$1" data="$2"
  local sig
  sig=$(sign_body "$data")
  curl -s -w '\n%{http_code}' -X PATCH "$url" \
    -H "Content-Type: application/json" \
    -H "X-Clarmory-Public-Key: $PUB_KEY_B64" \
    -H "X-Clarmory-Signature: $sig" \
    -d "$data"
}

# POST without auth
unsigned_post() {
  local url="$1" data="$2"
  curl -s -w '\n%{http_code}' -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "$data"
}

# PATCH without auth
unsigned_patch() {
  local url="$1" data="$2"
  curl -s -w '\n%{http_code}' -X PATCH "$url" \
    -H "Content-Type: application/json" \
    -d "$data"
}

# Parse status from curl output (last line)
get_status() {
  echo "$1" | tail -n1
}

# Parse body from curl output (all but last line)
get_body() {
  echo "$1" | sed '$d'
}

SKILL_ID="github:claudecode-contrib/mqtt-client-skill"
SKILL_ID_ENC=$(urlencode "$SKILL_ID")
VERSION_HASH="f1e2d3c4"

echo "=== Clarmory Tiered Trust Auth Tests ==="
echo "API: $API_URL"
echo ""

# -------------------------------------------------------
# Prereq: Check python3 has cryptography module
# -------------------------------------------------------
if ! python3 -c "from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey" 2>/dev/null; then
  echo "ERROR: python3 'cryptography' module required. Install with: pip install cryptography"
  exit 1
fi

# Generate a test keypair for this run
generate_keypair
echo "Test public key: ${PUB_KEY_B64:0:16}..."
echo ""

# -------------------------------------------------------
# Test 1: Read endpoints remain public (no auth)
# -------------------------------------------------------
echo "--- 1. Read Endpoints Remain Public ---"

STATUS=$(http_status "$API_URL/search?q=mqtt")
if [ "$STATUS" = "200" ]; then
  pass "GET /search works without auth"
else
  fail "GET /search returned $STATUS without auth (expected 200)"
fi

STATUS=$(http_status "$API_URL/skills/$SKILL_ID_ENC")
if [ "$STATUS" = "200" ]; then
  pass "GET /skills/:id works without auth"
else
  fail "GET /skills/:id returned $STATUS without auth (expected 200)"
fi

STATUS=$(http_status "$API_URL/skills/$SKILL_ID_ENC/reviews")
if [ "$STATUS" = "200" ]; then
  pass "GET /skills/:id/reviews works without auth"
else
  fail "GET /skills/:id/reviews returned $STATUS without auth (expected 200)"
fi

# =======================================================
# TIER 1: Anonymous (no auth headers)
# =======================================================
echo ""
echo "========================================"
echo "  TIER 1: Anonymous (no auth)"
echo "========================================"

# -------------------------------------------------------
# Test 2: Submit review without auth headers (should 201, anonymous)
# -------------------------------------------------------
echo ""
echo "--- 2. Review Without Auth Headers (should 201, anonymous) ---"

NOAUTH_BODY="{\"agent_id\":\"no-auth\",\"extension_id\":\"$SKILL_ID\",\"version_hash\":\"$VERSION_HASH\",\"stage\":\"code_review\",\"security_ok\":true,\"quality_rating\":3,\"summary\":\"No auth test\"}"

RESPONSE=$(unsigned_post "$API_URL/reviews" "$NOAUTH_BODY")
STATUS=$(get_status "$RESPONSE")
BODY=$(get_body "$RESPONSE")

if [ "$STATUS" = "201" ]; then
  pass "POST /reviews without auth returns 201"
else
  fail "POST /reviews without auth returned $STATUS (expected 201)"
fi

NOAUTH_TRUST=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('trust_level', ''))
" 2>/dev/null || echo "")

if [ "$NOAUTH_TRUST" = "anonymous" ]; then
  pass "Unauthenticated review has trust_level: anonymous"
else
  fail "Expected trust_level 'anonymous', got '$NOAUTH_TRUST'"
fi

# -------------------------------------------------------
# Test 3: Submit review with invalid signature (should 401)
# -------------------------------------------------------
echo ""
echo "--- 3. Invalid Signature (should 401) ---"

BAD_SIG_BODY="{\"agent_id\":\"bad-sig\",\"extension_id\":\"$SKILL_ID\",\"version_hash\":\"$VERSION_HASH\",\"stage\":\"code_review\",\"security_ok\":true,\"quality_rating\":3,\"summary\":\"Bad signature test\"}"

RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$API_URL/reviews" \
  -H "Content-Type: application/json" \
  -H "X-Clarmory-Public-Key: $PUB_KEY_B64" \
  -H "X-Clarmory-Signature: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
  -d "$BAD_SIG_BODY")
STATUS=$(get_status "$RESPONSE")

if [ "$STATUS" = "401" ]; then
  pass "Invalid signature rejected (401)"
else
  fail "Invalid signature returned $STATUS (expected 401)"
fi

# =======================================================
# TIER 2: Pseudonymous (valid keypair)
# =======================================================
echo ""
echo "========================================"
echo "  TIER 2: Pseudonymous (keypair signed)"
echo "========================================"

# -------------------------------------------------------
# Test 4: Submit review with valid keypair (should 201, pseudonymous)
# -------------------------------------------------------
echo ""
echo "--- 4. Signed Review (Tier 2 pseudonymous) ---"

REVIEW_BODY="{\"agent_id\":\"auth-test\",\"extension_id\":\"$SKILL_ID\",\"version_hash\":\"$VERSION_HASH\",\"stage\":\"code_review\",\"security_ok\":true,\"quality_rating\":4,\"summary\":\"Tier 2 pseudonymous auth test\"}"

RESPONSE=$(signed_post "$API_URL/reviews" "$REVIEW_BODY")
STATUS=$(get_status "$RESPONSE")
BODY=$(get_body "$RESPONSE")

if [ "$STATUS" = "201" ]; then
  pass "POST /reviews with valid signature returns 201"
else
  fail "POST /reviews with valid signature returned $STATUS (expected 201)"
  echo "  Response: $BODY"
fi

TRUST_LEVEL=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('trust_level', ''))
" 2>/dev/null || echo "")

if [ "$TRUST_LEVEL" = "pseudonymous" ]; then
  pass "Review has trust_level: pseudonymous"
else
  fail "Expected trust_level 'pseudonymous', got '$TRUST_LEVEL'"
fi

REVIEW_KEY_T1=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('review_key', ''))
" 2>/dev/null || echo "")

if [ -n "$REVIEW_KEY_T1" ]; then
  pass "Tier 2 review created: $REVIEW_KEY_T1"
else
  fail "Tier 1 review did not return review_key"
fi

# -------------------------------------------------------
# Test 5: Same public key = same identity across reviews
# -------------------------------------------------------
echo ""
echo "--- 5. Same Key = Same Identity ---"

REVIEW_BODY_2="{\"agent_id\":\"auth-test\",\"extension_id\":\"$SKILL_ID\",\"version_hash\":\"$VERSION_HASH\",\"stage\":\"code_review\",\"security_ok\":true,\"quality_rating\":5,\"summary\":\"Second review same keypair\"}"

RESPONSE=$(signed_post "$API_URL/reviews" "$REVIEW_BODY_2")
STATUS=$(get_status "$RESPONSE")
BODY=$(get_body "$RESPONSE")

if [ "$STATUS" = "201" ]; then
  pass "Second review with same keypair accepted"
else
  fail "Second review with same keypair returned $STATUS (expected 201)"
fi

REVIEW_KEY_T1B=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('review_key', ''))
" 2>/dev/null || echo "")

# Fetch reviews and verify both have the same public_key
if [ -n "$REVIEW_KEY_T1" ] && [ -n "$REVIEW_KEY_T1B" ]; then
  REVIEWS_RESP=$(http_get "$API_URL/skills/$SKILL_ID_ENC/reviews")
  REVIEWS_BODY=$(get_body "$REVIEWS_RESP")

  SAME_IDENTITY=$(echo "$REVIEWS_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
reviews = d.get('reviews', [])
keys = {}
for r in reviews:
    rk = r.get('review_key', '')
    if rk in ('$REVIEW_KEY_T1', '$REVIEW_KEY_T1B'):
        keys[rk] = r.get('public_key', '')
vals = list(keys.values())
if len(vals) == 2 and vals[0] and vals[0] == vals[1]:
    print('yes')
elif len(vals) < 2:
    print('unknown')
else:
    print('no')
" 2>/dev/null || echo "unknown")

  if [ "$SAME_IDENTITY" = "yes" ]; then
    pass "Both reviews share same public key identity"
  elif [ "$SAME_IDENTITY" = "unknown" ]; then
    echo "    (Could not verify — reviews may not expose public_key in list)"
  else
    fail "Reviews from same keypair have different identities"
  fi
fi

# -------------------------------------------------------
# Test 6: PATCH review without auth (should 200, anonymous)
# -------------------------------------------------------
echo ""
echo "--- 6. PATCH Without Auth (should 200, anonymous) ---"

if [ -n "$REVIEW_KEY_T1" ]; then
  PATCH_BODY='{"stage":"user_decision","installed":true}'
  RESPONSE=$(unsigned_patch "$API_URL/reviews/$REVIEW_KEY_T1" "$PATCH_BODY")
  STATUS=$(get_status "$RESPONSE")

  if [ "$STATUS" = "200" ]; then
    pass "PATCH /reviews/:key without auth returns 200 (anonymous)"
  else
    fail "PATCH /reviews/:key without auth returned $STATUS (expected 200)"
  fi
else
  fail "Skipped — no review_key from previous test"
fi

# -------------------------------------------------------
# Test 7: PATCH review with valid signature (should 200)
# -------------------------------------------------------
echo ""
echo "--- 7. PATCH With Valid Signature (should 200) ---"

if [ -n "$REVIEW_KEY_T1" ]; then
  PATCH_BODY='{"stage":"post_use","worked":true,"rating":4,"task_summary":"auth test","what_worked":"signing works","what_didnt":"nothing"}'
  RESPONSE=$(signed_patch "$API_URL/reviews/$REVIEW_KEY_T1" "$PATCH_BODY")
  STATUS=$(get_status "$RESPONSE")

  if [ "$STATUS" = "200" ]; then
    pass "PATCH /reviews/:key with valid signature returns 200"
  else
    fail "PATCH /reviews/:key with valid signature returned $STATUS (expected 200)"
  fi
else
  fail "Skipped — no review_key from previous test"
fi

# -------------------------------------------------------
# Test 8: Partial auth headers (one without the other → 401)
# -------------------------------------------------------
echo ""
echo "--- 8. Partial Auth Headers (should 401) ---"

PARTIAL_BODY="{\"agent_id\":\"partial\",\"extension_id\":\"$SKILL_ID\",\"version_hash\":\"$VERSION_HASH\",\"stage\":\"code_review\",\"security_ok\":true,\"quality_rating\":3,\"summary\":\"Partial headers test\"}"

# Public key without signature
RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$API_URL/reviews" \
  -H "Content-Type: application/json" \
  -H "X-Clarmory-Public-Key: $PUB_KEY_B64" \
  -d "$PARTIAL_BODY")
STATUS=$(get_status "$RESPONSE")

if [ "$STATUS" = "401" ]; then
  pass "Public key without signature returns 401"
else
  fail "Public key without signature returned $STATUS (expected 401)"
fi

# Signature without public key
PARTIAL_SIG=$(sign_body "$PARTIAL_BODY")
RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$API_URL/reviews" \
  -H "Content-Type: application/json" \
  -H "X-Clarmory-Signature: $PARTIAL_SIG" \
  -d "$PARTIAL_BODY")
STATUS=$(get_status "$RESPONSE")

if [ "$STATUS" = "401" ]; then
  pass "Signature without public key returns 401"
else
  fail "Signature without public key returned $STATUS (expected 401)"
fi

# =======================================================
# TIER 3: GitHub Verified Auth
# =======================================================
echo ""
echo "========================================"
echo "  TIER 3: GitHub Verified Auth"
echo "========================================"

# -------------------------------------------------------
# Test 9: Invalid GitHub token does not upgrade trust
# -------------------------------------------------------
echo ""
echo "--- 9. Invalid GitHub Token ---"

GH_VERIFY_BODY="{\"github_token\":\"ghp_invalidtoken000000000000000000fake\",\"public_key\":\"$PUB_KEY_B64\"}"

RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$API_URL/auth/github/verify" \
  -H "Content-Type: application/json" \
  -d "$GH_VERIFY_BODY")
STATUS=$(get_status "$RESPONSE")

if [ "$STATUS" = "401" ] || [ "$STATUS" = "400" ]; then
  pass "Invalid GitHub token rejected ($STATUS)"
else
  fail "Invalid GitHub token returned $STATUS (expected 401 or 400)"
fi

echo ""
echo "  NOTE: Full Tier 3 verification requires a real GitHub token."
echo "  To test: export CLARMORY_TEST_GH_TOKEN=ghp_... and re-run."

if [ -n "${CLARMORY_TEST_GH_TOKEN:-}" ]; then
  echo "  Real GitHub token detected — testing verified auth..."

  GH_REAL_BODY="{\"github_token\":\"$CLARMORY_TEST_GH_TOKEN\",\"public_key\":\"$PUB_KEY_B64\"}"

  RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$API_URL/auth/github/verify" \
    -H "Content-Type: application/json" \
    -d "$GH_REAL_BODY")
  STATUS=$(get_status "$RESPONSE")
  BODY=$(get_body "$RESPONSE")

  GH_REAL_TRUST=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('trust_level', ''))
" 2>/dev/null || echo "")

  if [ "$STATUS" = "200" ] && [ "$GH_REAL_TRUST" = "github_verified" ]; then
    pass "Real GitHub token upgrades to trust_level: github_verified"
  else
    fail "Real GitHub token: status=$STATUS trust=$GH_REAL_TRUST (expected 200 + github_verified)"
  fi

  # Verify subsequent review gets github_verified trust
  GH_REVIEW="{\"agent_id\":\"gh-verified\",\"extension_id\":\"$SKILL_ID\",\"version_hash\":\"$VERSION_HASH\",\"stage\":\"code_review\",\"security_ok\":true,\"quality_rating\":5,\"summary\":\"GitHub verified review\"}"
  RESPONSE=$(signed_post "$API_URL/reviews" "$GH_REVIEW")
  STATUS=$(get_status "$RESPONSE")
  BODY=$(get_body "$RESPONSE")

  POST_TRUST=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('trust_level', ''))
" 2>/dev/null || echo "")

  if [ "$POST_TRUST" = "github_verified" ]; then
    pass "Review after GitHub verification has trust_level: github_verified"
  else
    fail "Expected github_verified, got '$POST_TRUST'"
  fi
else
  echo "  Skipping real GitHub token test (CLARMORY_TEST_GH_TOKEN not set)"
fi

# =======================================================
# DUAL SCORING
# =======================================================
echo ""
echo "========================================"
echo "  DUAL SCORING"
echo "========================================"

# -------------------------------------------------------
# Test 10: Search results include dual ratings
# -------------------------------------------------------
echo ""
echo "--- 10. Dual Scoring in Search Results ---"

RESPONSE=$(http_get "$API_URL/search?q=mqtt")
STATUS=$(get_status "$RESPONSE")
BODY=$(get_body "$RESPONSE")

if [ "$STATUS" = "200" ]; then
  pass "Search returns 200"
else
  fail "Search returned $STATUS"
fi

HAS_AVG=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('results', []):
    reviews = r.get('reviews', {})
    if 'avg_rating' in reviews:
        print('yes')
        sys.exit(0)
print('no')
" 2>/dev/null || echo "no")

if [ "$HAS_AVG" = "yes" ]; then
  pass "Search results include avg_rating"
else
  fail "Search results missing avg_rating"
fi

HAS_VERIFIED_AVG=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('results', []):
    reviews = r.get('reviews', {})
    if 'verified_avg_rating' in reviews:
        print('yes')
        sys.exit(0)
print('no')
" 2>/dev/null || echo "no")

if [ "$HAS_VERIFIED_AVG" = "yes" ]; then
  pass "Search results include verified_avg_rating"
else
  fail "Search results missing verified_avg_rating"
fi

# -------------------------------------------------------
# Test 11: Skill detail shows trust level breakdown
# -------------------------------------------------------
echo ""
echo "--- 11. Trust Level Breakdown in Skill Detail ---"

RESPONSE=$(http_get "$API_URL/skills/$SKILL_ID_ENC")
STATUS=$(get_status "$RESPONSE")
BODY=$(get_body "$RESPONSE")

if [ "$STATUS" = "200" ]; then
  pass "Skill detail returns 200"
else
  fail "Skill detail returned $STATUS"
fi

HAS_BREAKDOWN=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
reviews = d.get('reviews', {})
has_it = any(k for k in reviews if 'verified' in k.lower() or 'anonymous' in k.lower() or 'trust' in k.lower())
print('yes' if has_it else 'no')
" 2>/dev/null || echo "no")

if [ "$HAS_BREAKDOWN" = "yes" ]; then
  pass "Skill detail includes trust level breakdown"
else
  fail "Skill detail missing trust level breakdown"
fi

# =======================================================
# RATE LIMITING
# =======================================================
echo ""
echo "========================================"
echo "  RATE LIMITING"
echo "========================================"

# -------------------------------------------------------
# Test 12: IP rate limiting on review submissions (30/hour)
# -------------------------------------------------------
echo ""
echo "--- 12. Review Submission Rate Limiting ---"

echo "  Submitting reviews rapidly (limit: 30/hour)..."
RATE_LIMITED=false
for i in $(seq 1 35); do
  RL_BODY="{\"agent_id\":\"ratelimit-$i\",\"extension_id\":\"$SKILL_ID\",\"version_hash\":\"$VERSION_HASH\",\"stage\":\"code_review\",\"security_ok\":true,\"quality_rating\":3,\"summary\":\"Rate limit test $i\"}"
  RL_SIG=$(sign_body "$RL_BODY")
  STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/reviews" \
    -H "Content-Type: application/json" \
    -H "X-Clarmory-Public-Key: $PUB_KEY_B64" \
    -H "X-Clarmory-Signature: $RL_SIG" \
    -d "$RL_BODY")
  if [ "$STATUS" = "429" ]; then
    RATE_LIMITED=true
    pass "Rate limited after $i review submissions (HTTP 429)"
    break
  fi
done

if [ "$RATE_LIMITED" = "false" ]; then
  fail "No rate limiting observed after 35 rapid review submissions"
fi

# -------------------------------------------------------
# Test 13: GitHub auth rate limiting (10/hour)
# -------------------------------------------------------
echo ""
echo "--- 13. GitHub Auth Rate Limiting ---"

echo "  Sending rapid GitHub verify requests (limit: 10/hour)..."
GH_RATE_LIMITED=false
for i in $(seq 1 15); do
  STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/auth/github/verify" \
    -H "Content-Type: application/json" \
    -d "{\"github_token\":\"ghp_fake$i\",\"public_key\":\"$PUB_KEY_B64\"}")
  if [ "$STATUS" = "429" ]; then
    GH_RATE_LIMITED=true
    pass "GitHub auth rate limited after $i requests (HTTP 429)"
    break
  fi
done

if [ "$GH_RATE_LIMITED" = "false" ]; then
  fail "No rate limiting on GitHub auth after 15 rapid requests"
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "==========================================="
echo "  Tiered Trust Auth Test Results"
echo "  PASSED: $PASS"
echo "  FAILED: $FAIL"
echo "  TOTAL:  $TESTS"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
