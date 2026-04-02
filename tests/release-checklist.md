# Release Readiness Checklist

All items must pass before sharing Clarmory publicly.

## Test Layers

- [x] **Layer 1 -- Unit tests**: `cd api && npm test` passes (vitest)
- [x] **Layer 2 -- Integration tests**: `bash tests/e2e/integration.sh https://api.clarmory.com` -- 48/48
- [x] **Layer 3a -- Agent-in-the-loop (local)**: `bash tests/e2e/agent-test.sh` -- 6/6
- [x] **Layer 3b -- Agent-in-the-loop (production)**: `bash tests/e2e/agent-test.sh --live https://api.clarmory.com` -- 6/6
- [ ] **No-match negative test**: `bash tests/e2e/no-match-test.sh` -- not yet run

## Authentication (Tiered Trust)

Three-tier auth model with Ed25519 keypair signing:

- [x] **Tier 1 (anonymous)**: No auth headers accepted, trust_level: "anonymous"
- [x] **Tier 2 (pseudonymous)**: Valid Ed25519 keypair signature, trust_level: "pseudonymous"
- [ ] **Tier 3 (github_verified)**: GitHub OAuth device flow upgrades identity to "github_verified"
- [x] **Invalid signature rejected** with 401
- [x] **Partial auth headers rejected** (one without the other) with 401
- [x] **Read endpoints remain public** (GET /search, GET /skills/:id, GET /skills/:id/reviews)
- [x] **Rate limiting** active on review submissions (30/hour per IP)
- [x] **Rate limiting** active on GitHub auth (10/hour per IP)
- [ ] **Admin endpoints** (/admin/seed, /admin/request-log) protected by ADMIN_SECRET in production

## Content

- [ ] **50+ skills** in production database (real, curated skills from upstream sources)
- [x] **MQTT test skill** has inline content for e2e test reliability
- [x] **Review seed data** covers multiple skills with varied stages and ratings
- [x] **All seed skills have valid source_url**

## SKILL.md Client

- [x] **SKILL.md works end-to-end** with production API (https://api.clarmory.com)
- [x] **Subagent pattern** functions correctly (spawn, search, evaluate, install, review)
- [x] **URL encoding** works for skill IDs with colons/slashes
- [x] **Content endpoint** serves inline skill content correctly
- [x] **Manifest tracking** at ~/.claude/clarmory/installed.json works
- [x] **Project-local install** (.claude/skills/) is the default
- [x] **Ed25519 signing** integrated into review submission flow

## Infrastructure

- [x] **Custom domain** https://api.clarmory.com resolves and serves requests
- [x] **HTTPS** enforced
- [x] **Cloudflare Workers + D1** deployed and functional
- [ ] **CORS** configured if browser clients are expected
- [x] **Error responses** are JSON with consistent format
- [ ] **FTS5 special character handling** -- hyphens, dots, parentheses in search queries cause 500

## Documentation

- [x] **README.md** exists with installation instructions
- [x] **SKILL.md** has correct production API URL
- [ ] **API reference** or link to one
- [ ] **How to contribute skills** documentation

## Known Issues

- Search queries with special characters (hyphens, dots, parentheses) return 500 -- FTS5 syntax error not caught
- Agent cannot write to .claude/skills/ or ~/.claude/clarmory/ in --dangerously-skip-permissions mode in some environments (permission system blocks sensitive paths)
