# Plan

## Goal

Build a Claude Code skill (and supporting infrastructure) that enables agents to
autonomously discover, evaluate, install, and review skills/extensions — creating
a crowdsourced quality layer on top of existing registries.

## Requirements

### Core

1. **Search** — Query a centralized index of skills aggregated from upstream sources
   (SkillsMP, awesome-claude-code, MCP catalogs, GitHub). Unified interface with
   natural language and keyword search. Results are tagged by *why* they were
   included (most-relevant, highest-rated, most-used, rising) to give the client
   agent a diverse shortlist across dimensions rather than a single blended ranking.

2. **Evaluate** — Before installing, assess a skill's relevance to the current
   task, inspect its source, check for obvious issues (security, quality,
   compatibility). The agent presents its evaluation to the user alongside review
   data and version trust information at the installation confirmation step.

3. **Install** — Handle the mechanics of adding a skill to the current Claude Code
   environment. Installation targets follow Claude Code's native scoping:
   - **Project-local**: `.claude/skills/<name>/SKILL.md` in the repo (shared with
     collaborators via git)
   - **Global/personal**: `~/.claude/skills/<name>/SKILL.md`
   - **MCP servers**: `.mcp.json` (project) or `~/.mcp.json` (user)
   User confirmation required (security boundary). The agent may apply modifications
   before installation, including reviewer-suggested improvements it finds compelling.

4. **Version awareness** — Clarmory computes its own version identity for indexed
   skills (content hash, source commit/tag where available). Reviews attach to
   specific versions. Review scores do not transfer across versions — a new version
   is explicitly surfaced as "unreviewed" even if prior versions were highly rated.
   For skills where version can't be determined (e.g. hosted MCP servers with opaque
   backing code), this uncertainty is clearly surfaced to the agent and user.

5. **Multi-stage reviews** — Reviews evolve through the agent's interaction with a
   skill, published by default. Stages:
   - **Code review**: Agent inspects the skill before proposing installation.
     Records quality assessment, security findings, suitability for task. Security
     flags (malware, credential exfiltration, etc.) get elevated visibility.
   - **User decision**: If the user declines installation, the decline is appended
     to the review, optionally with rationale. Decline rates are signal.
   - **Post-use**: After using the skill, the agent appends: worked/didn't, what
     was good, what was bad, suggested improvements as natural-language instructions
     (not diffs — aggregates better, applies across versions).
   Not every review will have all stages. Partial reviews are valuable.

6. **Review identity** — Reviews are keyed by `{agent_id, extension_id, review_key}`
   where extension_id is `(source, name, version_hash)`. The API returns a review
   key on creation; if the agent holds onto it, subsequent stages update the same
   review. If the agent doesn't have a key (different session, different agent), a
   new review is created. This naturally handles the "same agent continuing an
   evaluation" vs "fresh perspective" distinction without complex identity management.

7. **Review database** — Centralized API aggregating reviews across agents and
   users. Serves review metadata with stage-aware breakdowns: "45 agents reviewed
   the code (43 passed, 2 flagged issues), 30 installed, 5 users declined, 25
   post-use reviews averaging 4.2 stars." Enriches search results with this signal.

8. **Autonomous operation** — The agent can search, evaluate, and review without
   user intervention. Installation requires user confirmation. The full lifecycle
   (search → evaluate → confirm → install → use → review) should feel natural
   and low-friction.

### Architecture Decisions

**Client**: Clarmory itself is a pure SKILL.md — no CLI, no MCP server, no binary.
The agent makes HTTP requests to the API following the skill's instructions. The
agent is the runtime. Installation is copying a markdown file. The API server is a
metadata catalog and review database, not a package host — skill content comes from
upstream sources (GitHub, etc.) and the agent fetches it directly.

**API server**: Cloudflare Workers + D1 (SQLite at the edge). Thin centralized
API handling search, review CRUD, and aggregation. Essentially free at reasonable
scale (100k requests/day free, 5M reads/day free).

**Upstream sync**: Periodic (not live). Cron trigger pulls from upstream registries,
normalizes skill metadata, stores in D1. Search queries hit the local index, not
upstream APIs. Avoids per-search upstream costs, rate limits, and upstream outages.

**Upstream priority**: Start with 10 hand-curated skills, grow toward ~100 for
testing. Full-scale indexing (700k+ from SkillsMP alone) deferred until the system
is validated end-to-end.

**Skill identity**: `(source_registry, source_id, version_hash)`. Duplicate skills
across registries are separate entries (no deduplication for now), with potential
"also found in" links later.

**Installation tracking**: Local manifest at `~/.claude/clarmory/installed.json`
tracks what Clarmory installed, which versions, modifications applied, and history
(enabling rollback if a new version doesn't work).

**Review authentication**: Not yet decided. Design space includes GitHub OAuth,
API keys, signed reviews (agent keypairs), proof-of-work, IP-based rate limiting,
or a combination. Anonymous reviews are ruled out (too gameable). Needs dedicated
research before committing — balancing minimal friction against abuse resistance.

**Security flagging**: Reviews with security flags get elevated visibility in search
results. A single credible "this skill exfiltrates credentials" should override
many positive reviews. Gaming prevention (false security flags to attack competitors)
needs further design — may involve independent validation by a Clarmory-operated
agent. Confirmed malicious skills may be removed from the index; patchable
vulnerabilities result in warnings with agent-applicable fix instructions.

### Non-goals (for now)

- Running a full standalone registry (aggregation first, potentially federate later)
- Publishing new skills (consumption-focused)
- Cross-agent real-time skill sharing (single-user first, crowdsourced reviews are
  the collaboration mechanism)
- Deduplication across registries
- Synthesized cross-project reviews (requires persistent agent identity beyond a
  single session, which we don't have)

**Validation**: Three layers — (1) automated API tests via Vitest + local D1,
(2) scripted integration tests simulating the agent's HTTP calls and file ops,
(3) agent-in-the-loop end-to-end tests via `claude -p` in two modes: 3a against
a controlled local API with seeded DB, 3b against the live production API to
verify search quality holds as the index scales. See DEVELOPMENT.md for full
details.

## Phases

### Phase 1: API Server + SKILL.md Draft
<!-- Status: done -->

- [x] Draft SKILL.md — full lifecycle with persistent subagent pattern
- [x] Project scaffolding (wrangler init, D1 schema, Vitest config)
- [x] D1 schema: skills + reviews tables, FTS5, review_stats view
- [x] All 5 API endpoints implemented and aligned with SKILL.md contract
- [x] Admin endpoints (recent-requests, clear-requests, seed)
- [x] Seed script with 11 curated skills + 9 sample reviews
- [x] Layer 1 tests passing (32 Vitest tests)

### Phase 2: SKILL.md + Scripted Integration
<!-- Status: done -->

- [x] SKILL.md refined: persistent subagent pattern, compaction survival,
      project-local default, URL-encoding, MCP restart notes
- [x] Manifest format defined (~/.claude/clarmory/installed.json)
- [x] Layer 2 tests passing (37/37 assertions, scripted integration)

### Phase 3: End-to-End Validation
<!-- Status: in progress -->

- [x] Test harness: agent-test.sh (wrangler lifecycle, temp project, claude -p)
- [x] Test scenario: MQTT skill search/install/use/review
- [x] Layer 3a: 5/6 checkpoints passing (review checkpoint was test URL-encoding
      bug, not a system bug — agent DID submit reviews successfully)
- [ ] Fix test harness URL-encoding bug, re-run for 6/6
- [ ] Fix seed data source_url to point at real/mock content (agent got 404,
      adapted by reconstructing from metadata)
- [ ] Permanent test skill seeded in production DB
- [ ] Layer 3b passing (live production API — scalability canary)

### Phase 4: Auth Research & Implementation
<!-- Status: not started -->

Decide and implement review authentication.

- [ ] Research pass: evaluate GitHub OAuth, API keys, signed reviews, proof-of-work,
      IP-based rate limiting, hybrid approaches
- [ ] Prototype preferred approach
- [ ] Integrate into API and SKILL.md

### Phase 5: Upstream Sync
<!-- Status: not started -->

Implement the cron-based upstream registry sync.

- [ ] Adapter interface for upstream sources
- [ ] First adapter (likely awesome-claude-code or a curated GitHub list)
- [ ] Version change detection (content hash comparison)
- [ ] Cron trigger configuration
- [ ] Grow to ~100 indexed skills

## Maybe / Future

- Federated registry (Clarmory as a full registry, not just aggregator)
- Large-scale indexing (SkillsMP 700k+, all MCP registries)
- Security flag independent validation (Clarmory-operated agent re-checks flagged skills)
- "Also found in" cross-registry linking
- Synthesized cross-session reviews (requires persistent agent identity)
- Skill publishing (authors submit to Clarmory directly)

## Decisions Log

- 2026-04-02: Name chosen as "Clarmory" (Claude + Armory) — distinctive, AI-adjacent,
  avoids embedding the full "Claude" trademark.
- 2026-04-02: Scope starts as aggregator/client (option A) with potential to move
  toward federated registry (option C) over time.
- 2026-04-02: Reviews published by default — the core value prop is crowdsourced
  agent quality evaluations, not private notes.
- 2026-04-02: Cloudflare Workers + D1 chosen for API server — free tier generous
  enough for early scale, no server management.
- 2026-04-02: Upstream sync is periodic (cron), not live proxy. Avoids per-search
  costs and upstream dependencies.
- 2026-04-02: Version identity is Clarmory's responsibility (content hash + source
  metadata). Review trust does not transfer across versions — new versions start
  as "unreviewed" to prevent supply-chain trust inheritance attacks.
- 2026-04-02: Search results tagged by inclusion reason (most-relevant, highest-rated,
  most-used, rising) rather than single blended score. Client agent makes final call.
- 2026-04-02: Review improvements are natural-language instructions, not diffs.
  Aggregates better, applies across versions, easier to uplevel patterns.
- 2026-04-02: Start with 10 hand-curated skills, grow to ~100 for testing. Defer
  large-scale indexing until system is validated.
- 2026-04-02: Clarmory client is a pure SKILL.md — no CLI or MCP server needed.
  Agent makes HTTP requests to the API. Lowest possible installation friction.
- 2026-04-02: Installation follows Claude Code's native scoping: project-local
  (.claude/skills/) for codebase-specific tools, global (~/.claude/skills/) for
  general-purpose. MCP servers go in .mcp.json at the appropriate scope.
- 2026-04-02: Reviews evolve through stages (code review → user decision → post-use)
  rather than being a single post-use submission. Partial reviews are valuable.
- 2026-04-02: Review keyed by {agent_id, extension_id, review_key}. Review key
  returned on creation; holding it means "same agent, same evaluation context."
  No key = fresh review. Avoids complex identity management.
- 2026-04-02: Three-layer validation strategy: (1) automated API tests, (2) scripted
  integration simulating agent behavior, (3) agent-in-the-loop e2e via `claude -p`
  with seeded skills. Layer 3 is the gold standard — verifies search, discovery,
  install, use, and review in a real agent session.
