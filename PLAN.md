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
   - **Project-local** (strong default): `.claude/skills/<name>/SKILL.md` in the
     repo. Preferred because project-local skills survive context compaction (loaded
     by the framework from disk, not held in conversation history) and are shared
     with collaborators via git.
   - **Global/personal**: `~/.claude/skills/<name>/SKILL.md` — only when user
     explicitly requests. After install, tell the user: "To activate, restart
     Claude Code or run `/skills reload`."
   - **MCP servers**: `.mcp.json` (project) or `~/.mcp.json` (user). Always
     require a Claude Code restart. Write a brief note to `.claude/CLAUDE.md`
     describing the server (survives compaction since CLAUDE.md is always loaded).
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
<!-- Status: done -->

- [x] Test harness: agent-test.sh (wrangler lifecycle, temp project, claude -p)
- [x] Test scenario: MQTT skill search/install/use/review
- [x] Layer 3a: 6/6 checkpoints passing
- [x] Content endpoint added (skills served from D1, no external URL dependency)
- [x] Production deployment: api.clarmory.com live, 37/37 integration against prod
- [ ] Layer 3b passing (live production API — scalability canary)

### Phase 4: Auth & DB Population
<!-- Status: in progress -->

Implement tiered trust auth and populate the DB with real content.

- [x] Import real skills from upstream sources: ~2,700 skills in production
      (awesome-claude-code, GitHub SKILL.md search, GitHub topic search,
      npm registry, Smithery.ai, official MCP servers repo)
- [ ] Tier 1 auth: Ed25519 keypair — agent auto-generates, signs reviews,
      server tracks consistent pseudonymous identity. Zero friction.
- [ ] Tier 2 auth: GitHub OAuth device flow — optional trust upgrade,
      user-initiated, never a gate or blocking prompt. Retroactive upgrade
      of past reviews when linked.
- [ ] POST /auth/link-github — validates GitHub token, links public key
      to GitHub username, batch-upgrades past reviews to github_verified
- [ ] Dual scoring: review_stats computes avg_rating + verified_avg_rating,
      search results include both, prefer verified when 5+ reviews exist
- [ ] IP-based rate limiting on review submission (keep existing)
- [ ] Read endpoints remain public
- [ ] Reject reviews with no auth (keypair is the minimum floor)
- [ ] Update SKILL.md: keypair auto-generation, casual GitHub mention,
      device flow instructions for when user initiates
- [ ] Auth integration tests passing
- [ ] Register GitHub OAuth App (client_id + secret)

### Phase 5: Pre-Release Validation
<!-- Status: not started -->

Thorough review and real-world testing before sharing with others.

- [ ] Full code review: security audit (injection, auth bypass, rate limit
      evasion), scaling review (D1 limits, Worker CPU time, FTS performance
      at 100+ skills), error handling completeness
- [ ] Install Clarmory skill in own environment and use on a real project —
      does the skill activate? Does it find useful things? Does the subagent
      pattern work smoothly? Does it survive compaction?
- [ ] Beta test with friends: share the skill, gather feedback on UX, search
      quality, install friction, review submission flow
- [ ] Fix issues found during testing
- [ ] README with installation instructions and quick-start guide
- [ ] Release checklist passing (tests/release-checklist.md)

### Phase 6: Upstream Sync
<!-- Status: not started -->

Implement the cron-based upstream registry sync (replaces manual import script).

- [ ] Adapter interface for upstream sources
- [ ] First adapter (likely awesome-claude-code or a curated GitHub list)
- [ ] Microsoft APM adapter — APM (github.com/microsoft/apm) is a complementary
      package manager for agent configs (skills, MCP servers, prompts, hooks).
      Distributed git-based model, no central registry API. Index APM-compatible
      packages by scanning repos with apm.yml manifests. APM handles dependency
      management; Clarmory adds the review/quality layer APM lacks.
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
- Deeper APM integration (output apm.yml entries alongside Clarmory manifest,
  support `apm install` as alternative install path)
- Demand signal logging: when agents search and find nothing suitable, log the
  query as an unmet need. Categorize and aggregate these to identify gaps in the
  registry (e.g., "47 agents searched for image annotation tools this week —
  nothing in the catalog"). Could drive prioritization of which skills to index
  or inspire skill authors to fill gaps.

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
- 2026-04-02: Tiered trust for reviews. Tier 1: Ed25519 keypair generated by agent,
  stored at ~/.claude/clarmory/identity.json. Zero friction, consistent pseudonymous
  identity. Tier 2: GitHub OAuth device flow, optional upgrade that can happen at
  any time. Keypair is the primary identity; GitHub is an overlay, never a gate.
- 2026-04-02: Dual review scoring — separate avg_rating (all reviews) and
  verified_avg_rating (GitHub-verified only). Search results include both. When
  enough verified reviews exist (5+), prefer the verified score.
- 2026-04-02: GitHub auth is never a blocking prompt. Agent mentions it in passing
  at natural moments ("you can set up GitHub verification anytime — just ask").
  User initiates when ready. No pause, no gate.
- 2026-04-02: Retroactive trust upgrade — when a user links GitHub to their keypair,
  all past reviews from that public key are upgraded to github_verified. The agent
  signs {public_key, github_username} with the private key to prove ownership.
  POST /auth/link-github validates the GitHub token and batch-updates reviews.
- 2026-04-02: Reviews without any auth (no keypair, no GitHub) are rejected. The
  keypair is zero friction for the agent (auto-generated), so there's no reason
  to accept truly anonymous reviews. Floor is consistent pseudonymous identity.
- 2026-04-02: Microsoft APM is complementary (dependency management), not competing
  (discovery + quality). Added to Phase 6 as upstream adapter target.
- 2026-04-02: 203 skills imported to production DB from awesome-claude-code and
  GitHub SKILL.md search. Production live at api.clarmory.com.
- 2026-04-02: Expanded to ~2,700 skills from 6 sources: npm registry (970 MCP
  packages), Smithery.ai (463 servers), GitHub topics (311 repos), official
  MCP servers repo (6 individual servers), plus existing sources. PulseMCP
  skipped (requires API key, heavy overlap with Smithery/npm). Import script
  at api/scripts/import-new-sources.py with batched wrangler inserts.
