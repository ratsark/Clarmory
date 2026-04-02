# Plan

## Goal

Build a Claude Code skill (and supporting infrastructure) that enables agents to
autonomously discover, evaluate, install, and review skills/extensions — creating
a crowdsourced quality layer on top of existing registries.

## Requirements

### Core

1. **Search** — Query multiple upstream sources (SkillsMP, awesome-claude-code,
   MCP catalogs, GitHub) from a unified interface. Natural language and keyword
   search.

2. **Evaluate** — Before installing, assess a skill's relevance to the current
   task, inspect its source, check for obvious issues (security, quality,
   compatibility).

3. **Install** — Handle the mechanics of adding a skill to the current Claude Code
   environment (clone, symlink, configure MCP servers, etc.).

4. **Version awareness** — Track which version of a skill was installed, detect
   updates, handle breaking changes.

5. **Post-use review** — After using a skill for a task, the agent writes a
   structured review: did it work, was it easy to use, what went wrong, suggested
   improvements. Reviews are published by default to build the crowdsourced quality
   signal.

6. **Review database** — Aggregate reviews across agents and users to build a
   quality signal layer on top of raw registry listings. This is the key
   differentiator: agent-written reviews from real usage, not star counts. Reviews
   may include improvement suggestions that other agents can incorporate when they
   use the skill.

7. **Autonomous operation** — The agent should be able to search, install, use,
   and review without user intervention for routine cases. User confirmation for
   installs (security boundary).

### Non-goals (for now)

- Running a full standalone registry (aggregation first, potentially federate later)
- Publishing new skills (consumption-focused)
- Cross-agent real-time skill sharing (single-user first, crowdsourced reviews are
  the collaboration mechanism)

## Phases

<!-- To be defined after architecture discussion. -->

## Decisions Log

- 2026-04-02: Name chosen as "Clarmory" (Claude + Armory) — distinctive, AI-adjacent,
  avoids embedding the full "Claude" trademark.
- 2026-04-02: Scope starts as aggregator/client (option A) with potential to move
  toward federated registry (option C) over time.
- 2026-04-02: Reviews published by default — the core value prop is crowdsourced
  agent quality evaluations, not private notes.
