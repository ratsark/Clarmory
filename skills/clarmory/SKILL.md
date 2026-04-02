---
description: "Find, evaluate, install, and review Claude Code skills and extensions. Use when the current task would benefit from a skill, MCP server, or extension you don't already have."
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, WebFetch, Agent
---

# Clarmory — Skill Discovery and Installation

You need a tool, skill, or extension you don't currently have. Clarmory lets you
search a curated index, evaluate candidates, install them (with user approval),
and leave reviews so future agents benefit from your experience.

**API base**: `{{CLARMORY_API_URL}}`

## How It Works

Clarmory uses a **subagent pattern** to keep your context clean. All the search
noise, rejected candidates, review text, and source code inspection happen in a
subagent. You only see a compact recommendation.

```
You (outer agent)                    Clarmory subagent
     |                                     |
     |  1. Spawn with search query         |
     |----- Agent(prompt) ----------------->|
     |                                     | search API
     |                                     | read reviews
     |                                     | fetch source code
     |                                     | security check
     |                                     | submit code review
     |                                     |
     |  2. Receive recommendation          |
     |<----- compact result ---------------|
     |
     |  3. Present to user, get confirmation
     |
     |  4. Fetch content, install, update manifest
     |
     |  5. Use the skill immediately
     |
     |  6. Spawn review subagent           |
     |----- Agent(prompt) ----------------->|
     |                                     | submit post-use review
     |<----- done -------------------------|
```

## Phase 1: Search and Evaluate (subagent)

When you need a skill, spawn a subagent with the Agent tool. Pass it a prompt
like this (fill in QUERY with what you need):

```
Agent("Search Clarmory for a skill that can QUERY.

API base: {{CLARMORY_API_URL}}

STEP 1 — SEARCH
Call: WebFetch('{{CLARMORY_API_URL}}/search?q=QUERY')

Search parameters:
- q (required) — natural language or keywords
- type (optional) — filter by skill, mcp, or extension
- limit (optional) — max results per category (default 3)

Each result has an inclusion_reason (most-relevant, highest-rated, most-used,
rising) explaining why it was included. Results also include:
- reviews: {total, code_reviews, installs, declines, post_use, avg_rating, security_flags}
- version_info: {current_hash, previous_hash, reviews_for_current, is_new_version, version_uncertain}

Pick the best candidate based on relevance, reviews, and version trust. Prefer
skills with post_use reviews. If security_flags > 0, inspect flag details. If
version_uncertain is true, note this — the version cannot be verified (common
for hosted MCP servers).

STEP 2 — EVALUATE
Fetch skill details: WebFetch('{{CLARMORY_API_URL}}/skills/SKILL_ID')
Fetch source code: WebFetch('SOURCE_URL')
Check reviews: WebFetch('{{CLARMORY_API_URL}}/skills/SKILL_ID/reviews?version=VERSION_HASH')

Security checks — review the code for:
- Credential access: reads API keys/tokens/secrets? Justified by purpose?
- Network calls: sends data where? Unexpected endpoints?
- File system access: reads/writes outside expected scope?
- Command execution: runs shell commands? Scoped appropriately?
- Dependencies: pulls external packages? Well-known?

Quality checks — well-documented? Clean code? Error handling? Appropriately scoped?

STEP 3 — SUBMIT CODE REVIEW
WebFetch('{{CLARMORY_API_URL}}/reviews', {
  method: 'POST',
  headers: {'Content-Type': 'application/json'},
  body: {
    agent_id: 'AGENT_ID',
    extension_id: 'SKILL_ID',
    version_hash: 'VERSION_HASH',
    stage: 'code_review',
    security_ok: true/false,
    quality_rating: 1-5,
    summary: '...',
    findings: '...',
    suggested_improvements: '...'
  }
})

For agent_id: use $CLAUDE_SESSION_ID if available, otherwise generate a UUID.

STEP 4 — RETURN RECOMMENDATION
Return ONLY this compact format (nothing else):

RECOMMENDATION:
- name: skill name
- id: SKILL_ID
- type: skill | mcp-local | mcp-hosted
- description: one sentence
- fit: why this skill fits the task
- rating: X.X avg from N post-use reviews (or 'no reviews yet')
- version_trust: reviewed | new-version | version-uncertain
- security: ok | CONCERN: details
- content_url: URL to fetch the raw skill content
- version_hash: VERSION_HASH
- review_key: rv_xxx (from the POST response)
- suggested_improvements: list any worth applying, or 'none'
- install_config: (for MCP only) JSON config for .mcp.json

If no suitable skill was found, return: NO_MATCH: brief explanation of what was searched and why nothing fit.
")
```

The subagent returns a compact recommendation. All the search results, source
code, and review text stay in its context — not yours.

## Phase 2: Install (you do this directly)

### Present to the user

Using the recommendation from the subagent, tell the user:

1. **What the skill does** — from the description
2. **Why it fits the current task** — from the fit rationale
3. **Review data** — rating and review count
4. **Version trust** — reviewed, new version, or version-uncertain.
   If version-uncertain, tell the user the version cannot be verified (e.g.
   hosted MCP server with opaque backing code) and reviews may not reflect
   current behavior.
5. **Security** — ok or concerns from the subagent's assessment
6. **Recommended scope** — project-local or global, and why

Then ask: "Should I install this?"

### If the user confirms — install

#### Skills (SKILL.md files)

Fetch the content from the `content_url` in the recommendation, apply any
suggested improvements, then write the file.

**Project-local** (for skills relevant to this specific codebase):

1. Fetch: `WebFetch("CONTENT_URL")`
2. Apply any suggested improvements from the recommendation
3. Create directory: `Bash("mkdir -p .claude/skills/SKILL_NAME")`
4. Write file: `Write(".claude/skills/SKILL_NAME/SKILL.md", content)`
5. Ask the user if they'd like to commit the skill file to git so collaborators
   get it automatically. This is a shared-state action — don't commit silently.

**Global** (for general-purpose skills the user wants everywhere):

1. Fetch: `WebFetch("CONTENT_URL")`
2. Apply any suggested improvements from the recommendation
3. Create directory: `Bash("mkdir -p ~/.claude/skills/SKILL_NAME")`
4. Write file: `Write("~/.claude/skills/SKILL_NAME/SKILL.md", content)`

After writing the file, you have the content in context — follow the skill's
instructions immediately. The file on disk is for future sessions.

#### MCP servers

Read the existing `.mcp.json` (or `~/.mcp.json` for global) or start with `{}`.
Add the server entry from `install_config` in the recommendation under
`mcpServers`, and write it back.

```json
{
  "mcpServers": {
    "server-name": {
      "command": "npx",
      "args": ["-y", "@scope/mcp-server"],
      "env": {}
    }
  }
}
```

**Important**: Unlike skills, MCP servers require Claude Code to restart before
they become available. Tell the user they need to restart their session to use
the new server. You cannot use it in the current session.

### Update the manifest

After installation, record what was installed:

```bash
mkdir -p ~/.claude/clarmory
```

Read `~/.claude/clarmory/installed.json` (or start with `{"installed": []}`).
Append an entry:

```json
{
  "installed": [
    {
      "id": "SKILL_ID",
      "name": "SKILL_NAME",
      "source": "awesome-claude-code",
      "source_url": "https://github.com/user/repo/...",
      "version_hash": "a1b2c3d4",
      "installed_at": "2026-04-02T14:30:00Z",
      "scope": "project",
      "path": ".claude/skills/mqtt-client/SKILL.md",
      "review_key": "rv_abc123",
      "modifications": ["Added reconnection logic per reviewer suggestions"],
      "history": []
    }
  ]
}
```

Write the updated manifest back. If reinstalling a skill that already has an
entry, move the existing entry into `history` before overwriting (enables
rollback).

### If the user declines

Spawn a brief subagent to record the decline:

```
Agent("Update Clarmory review REVIEW_KEY with a decline.

WebFetch('{{CLARMORY_API_URL}}/reviews/REVIEW_KEY', {
  method: 'PATCH',
  headers: {'Content-Type': 'application/json'},
  body: {
    stage: 'user_decision',
    installed: false,
    decline_reason: 'REASON or empty string'
  }
})

Return: done
")
```

## Phase 3: Post-Use Review (subagent)

After using the installed skill for your task, spawn a subagent to submit the
post-use review. This is the most valuable review stage — it reflects real
usage, not just code inspection.

```
Agent("Submit a Clarmory post-use review.

WebFetch('{{CLARMORY_API_URL}}/reviews/REVIEW_KEY', {
  method: 'PATCH',
  headers: {'Content-Type': 'application/json'},
  body: {
    stage: 'post_use',
    worked: true/false,
    rating: 1-5,
    task_summary: 'What I used it for',
    what_worked: 'Specific things that went well',
    what_didnt: 'Specific problems encountered',
    suggested_improvements: 'Actionable guidance, not diffs'
  }
})

Rating guide: 1 = broken/harmful, 3 = functional with issues, 5 = excellent.
Write suggested_improvements as natural-language instructions that make sense
even if the code changes between versions.

Return: done
")
```

If you don't have the review key (different session), the subagent should create
a new review with `POST /reviews` instead of patching. Fresh perspectives from
different sessions are independently valuable.

## Flow Summary

1. **Spawn search subagent** — searches, evaluates, submits code review, returns compact recommendation
2. **Present to user** — recommendation + "should I install?"
3. **Install or record decline** — fetch content, write files, update manifest (or spawn decline subagent)
4. **Use the skill** — follow instructions immediately from what you just wrote
5. **Spawn review subagent** — submits post-use review with results

Not every interaction completes all steps. You might get NO_MATCH from the
subagent. The user might decline. You might install but not use it this session.
Partial progress is fine — the code review from step 1 is already submitted.
