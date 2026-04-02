# Architecture

## Overview

Clarmory has two components:

```
┌─────────────────────────────────────────────────┐
│                  Agent (client)                  │
│                                                  │
│  ┌────────────┐   ┌──────────┐   ┌───────────┐  │
│  │ SKILL.md   │   │ Manifest │   │ Installed  │  │
│  │ (Clarmory  │   │ (track   │   │ skills &   │  │
│  │  client)   │   │  state)  │   │ MCP svrs   │  │
│  └─────┬──────┘   └──────────┘   └───────────┘  │
│        │ HTTP                                    │
└────────┼─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────┐
│            Clarmory API (CF Workers + D1)        │
│                                                  │
│  ┌─────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ Search  │  │ Reviews  │  │ Skill metadata │  │
│  │ (FTS +  │  │ (CRUD +  │  │ (upstream sync │  │
│  │ ranked) │  │  stages) │  │  + versioning) │  │
│  └─────────┘  └──────────┘  └───────┬────────┘  │
│                                     │ cron       │
└─────────────────────────────────────┼────────────┘
                                      │
         ┌────────────────────────────┼──────┐
         ▼            ▼               ▼      ▼
    ┌─────────┐ ┌──────────┐ ┌──────┐ ┌──────────┐
    │SkillsMP │ │awesome-  │ │GitHub│ │MCP       │
    │         │ │claude-   │ │      │ │registries│
    │         │ │code      │ │      │ │          │
    └─────────┘ └──────────┘ └──────┘ └──────────┘
```

**The agent is the runtime.** The SKILL.md instructs the agent on how to search,
evaluate, install, and review. The agent uses its native tools (Bash, WebFetch,
Write, Edit) to interact with the API and perform installations. No CLI binary
or MCP server is needed for the Clarmory client itself.

**The API is a catalog, not a package host.** It stores skill metadata (name,
description, source URL, version hashes) and reviews. Skill content is fetched
by the agent directly from upstream sources (GitHub repos, etc.).

## Key Decisions

- We use Cloudflare Workers + D1 instead of a traditional server because the free
  tier is generous (100k req/day, 5M reads/day), there's no cold start, and no
  infrastructure to manage.
- We use periodic upstream sync (cron) instead of live proxying because it avoids
  per-search upstream API costs, rate limits, and outage dependencies.
- We use a pure SKILL.md client instead of a CLI/MCP server because it has zero
  installation friction (copy a file) and the agent already has the tools needed
  to make HTTP requests and manage files.
- Reviews are multi-stage (code review → user decision → post-use) instead of
  single-shot because the agent forms opinions at multiple points and partial
  reviews are valuable signal.
- Version identity is content-hash-based and managed by Clarmory, not inherited
  from upstream, because upstream versioning is inconsistent and trust must not
  transfer silently across versions.
- Search returns results tagged by inclusion reason (most-relevant, highest-rated,
  most-used, rising) instead of a single blended score because the client agent
  is better positioned to make the final judgment call.
