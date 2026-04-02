# Release Readiness Checklist

All items must pass before sharing Clarmory publicly.

## Test Layers

- [ ] **Layer 1 — Unit tests**: `cd api && npm test` passes (vitest)
- [ ] **Layer 2 — Integration tests**: `bash tests/e2e/integration.sh https://api.clarmory.com` — 37/37
- [ ] **Layer 3a — Agent-in-the-loop (local)**: `bash tests/e2e/agent-test.sh` — 6/6
  - Agent completes full lifecycle: search, discover, install, use, review
- [ ] **Layer 3b — Agent-in-the-loop (production)**: `bash tests/e2e/agent-test.sh --live https://api.clarmory.com` — 6/6

## Authentication and Security

- [ ] **API key auth enforced** on write endpoints (POST /reviews, PATCH /reviews/:key)
- [ ] **Read endpoints remain public** (GET /search, GET /skills/:id, GET /skills/:id/reviews)
- [ ] **Key registration** works (POST /auth/register)
- [ ] **Invalid/missing keys rejected** with 401
- [ ] **Rate limiting** active on write endpoints
- [ ] **Registration rate limiting** prevents abuse
- [ ] **Admin endpoints** (/admin/seed, /admin/request-log) disabled or auth-gated in production

## Content

- [ ] **50+ skills** in production database (real, curated skills from upstream sources)
- [ ] **All skills have valid source_url** pointing to real upstream content
- [ ] **MQTT test skill** has inline content for e2e test reliability
- [ ] **Review seed data** covers multiple skills with varied stages and ratings

## SKILL.md Client

- [ ] **SKILL.md works end-to-end** with production API (https://api.clarmory.com)
- [ ] **Subagent pattern** functions correctly (spawn, search, evaluate, install, review)
- [ ] **URL encoding** works for skill IDs with colons/slashes
- [ ] **Content endpoint** serves inline skill content correctly
- [ ] **Manifest tracking** at ~/.claude/clarmory/installed.json works
- [ ] **Project-local install** (.claude/skills/) is the default

## Infrastructure

- [ ] **Custom domain** https://api.clarmory.com resolves and serves requests
- [ ] **HTTPS** enforced (no plain HTTP)
- [ ] **CORS** configured if browser clients are expected
- [ ] **Error responses** are JSON with consistent format

## Documentation

- [ ] **README.md** exists with:
  - [ ] What Clarmory is (one paragraph)
  - [ ] Installation instructions (copy SKILL.md)
  - [ ] API reference or link to it
  - [ ] How to contribute skills
- [ ] **SKILL.md** has correct production API URL (no placeholders)
