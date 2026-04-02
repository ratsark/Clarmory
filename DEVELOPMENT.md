# Development

## Build
```bash
# API server (Cloudflare Workers)
cd api/
npm install
npm run build

# No build step for the SKILL.md client
```

## Test
```bash
# Unit/integration tests for the API
cd api/
npm test                    # Vitest against local D1

# End-to-end test (requires wrangler dev running)
./tests/e2e/run.sh          # Scripted HTTP flow
./tests/e2e/agent-test.sh   # Agent-in-the-loop via claude -p
```

## Run
```bash
# Local API server
cd api/
npx wrangler dev            # Starts Workers + D1 locally

# Deploy
cd api/
npx wrangler deploy         # Push to Cloudflare
```

## Validation Strategy

Three layers, each building on the last:

### Layer 1: API Server (automated, fast, cheap)

Standard unit and integration tests against the API using Vitest + Cloudflare's
local D1 test support. Covers:

- **Search**: FTS queries return correct results, ranking tags are applied
  correctly (most-relevant, highest-rated, most-used, rising), results include
  review metadata.
- **Review CRUD**: Create review at code-review stage, update with user-decision
  stage, update with post-use stage. Verify stage-aware aggregations are correct.
- **Version tracking**: Indexing a skill creates a version entry with content hash.
  Re-indexing with changed content creates a new version. Reviews attach to
  specific versions and don't bleed across.
- **Upstream sync**: Cron handler ingests skills from a mock upstream source,
  normalizes metadata, detects version changes.
- **Edge cases**: Duplicate submissions, missing fields, malformed requests,
  security flag elevation.

**"Done" means**: All tests pass. Can be run on the Pi via `npm test`.

### Layer 2: Scripted Integration (automated, medium cost)

A test script that performs the same HTTP calls and file operations the agent
would when following the SKILL.md instructions. Runs against `wrangler dev`.

Covers:
- Search → get results with review enrichment
- Fetch skill content from upstream (mock GitHub repo or local git server)
- Write skill files to the correct location
- Update the Clarmory manifest
- Submit a multi-stage review (code review → post-use)
- Verify the review appears in subsequent search results

**"Done" means**: Script runs end-to-end, all assertions pass. Validates the
API contract that the SKILL.md will rely on.

### Layer 3: Agent-in-the-Loop (semi-automated, higher cost)

A headless Claude Code session (`claude -p`) with the Clarmory skill installed,
given a task designed to trigger the full lifecycle. Runs in two modes:

#### 3a: Controlled (local API, seeded DB)

Tests the full lifecycle in isolation, without external dependencies.

**Setup**:
1. Start `wrangler dev` with a seeded D1 database containing ~10 curated skills
2. Configure the Clarmory SKILL.md to point at the local API
3. Create a temporary project directory for the test agent to work in
4. Seed a mock upstream (local git repo) with the target skill's content

**Test prompt** (example): "Set up an MQTT client in this project that subscribes
to a topic and logs messages. Use Clarmory to find a suitable skill or extension."

#### 3b: Live (production API, real DB)

Tests that our specific test skill remains discoverable and usable against the
production database as it scales. The test skill is permanently seeded in the
live DB. Same test prompt, same checkpoints — but validates that search quality
holds as the index grows (10 skills → 100 → thousands).

This is the canary: if the test skill stops being found, our search or ranking
has regressed.

#### Checkpoints (both modes)

After the session, verify:
- (a) **Searched**: API access logs show a search request from the agent
- (b) **Discovered**: The agent selected the target skill from search results
- (c) **Installed**: The skill/extension files exist at the expected path, manifest
  is updated with version hash and source metadata
- (d) **Used**: The agent's output shows it applied the skill to the task (project
  files created, code written using the skill's guidance)
- (e) **Reviewed**: API contains a review from this agent for this skill, with at
  least code-review and post-use stages populated

**"Done" means**: All five checkpoints pass in both modes. 3a is the functional
test; 3b is the scalability canary.

### Running Validation

Layer 1 runs on every change (fast, free). Layer 2 runs before any deploy.
Layer 3a runs at milestones (new phase complete, major changes to SKILL.md or
API contract). Layer 3b runs after any upstream sync that significantly grows
the index, and periodically as a regression check.
