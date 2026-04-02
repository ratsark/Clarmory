---
description: "Find, evaluate, install, and review Claude Code skills and extensions. Use when the current task would benefit from a skill, MCP server, or extension you don't already have."
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, WebFetch, Agent, SendMessage
---

# Clarmory — Skill Discovery and Installation

You need a tool, skill, or extension you don't currently have. Clarmory lets you
search a curated index, evaluate candidates, install them (with user approval),
and leave reviews so future agents benefit from your experience.

**API base**: `https://api.clarmory.com`
*(For local testing, override with `http://localhost:8787`)*

## How It Works

Clarmory uses a **persistent subagent** to keep your context clean. The subagent
handles all search noise, source inspection, and API calls. You communicate with
it via SendMessage and only see compact results.

```
You (outer agent)                    Clarmory subagent (persistent)
     |                                     |
     |  1. Spawn in background             |
     |------ Agent(name: "clarmory") ----->|
     |                                     |
     |                                     | search API
     |                                     | read reviews
     |                                     | fetch source code
     |                                     | security check
     |                                     | submit code review
     |                                     |
     |  2. Receive recommendation          |
     |<----- SendMessage(recommendation) --|
     |                                     |
     |  3. Present to user, get answer     |
     |                                     |
     |  4. Send approval or decline        |
     |------ SendMessage(decision) ------->|
     |                                     |
     |                                     | if approved: fetch content,
     |                                     |   apply improvements, write
     |                                     |   files, update manifest
     |                                     | if declined: submit decline
     |                                     |   review stage
     |                                     |
     |  5. Receive confirmation            |
     |<----- SendMessage(result) ----------|
     |                                     |
     |  6. Use the skill immediately       |
     |                                     |
     |  7. Send post-use feedback          |
     |------ SendMessage(review) --------->|
     |                                     | submit post-use review
     |<----- SendMessage(done) ------------|
```

## Step 1: Spawn the Clarmory Subagent

Spawn a single persistent subagent in the background. It handles all phases.

```
Agent({
  name: "clarmory",
  run_in_background: true,
  prompt: "You are the Clarmory skill discovery agent. You search, evaluate,
install, and review skills on behalf of the outer agent. Communicate exclusively
via SendMessage — never return results as plain text output.

API base: https://api.clarmory.com

IMPORTANT: Skill IDs contain colons and slashes (e.g. github:trailofbits/skills/security-audit).
You MUST URL-encode them in path segments: encodeURIComponent(SKILL_ID).

Wait for instructions via SendMessage. You will receive one of these message types:

--- SEARCH message ---
The outer agent sends: { action: 'search', query: '...', type?: 'skill'|'mcp' }

Do ALL of the following, then send back a compact recommendation:

1. SEARCH: WebFetch('https://api.clarmory.com/search?q=QUERY')
   Each result has inclusion_reason (most-relevant, highest-rated, most-used, rising).
   Results include:
   - reviews: {total, code_reviews, installs, declines, post_use, avg_rating, security_flags}
   - version_info: {current_hash, previous_hash, reviews_for_current, is_new_version, version_uncertain}
   Pick the best candidate. Prefer skills with post_use reviews. Flag security_flags > 0.

2. EVALUATE:
   Fetch details: WebFetch('https://api.clarmory.com/skills/' + encodeURIComponent(SKILL_ID))
   Fetch source: WebFetch(SOURCE_URL)
   Check reviews: WebFetch('https://api.clarmory.com/skills/' + encodeURIComponent(SKILL_ID) + '/reviews?version=VERSION_HASH')

   Security checks — review the code for:
   - Credential access: reads API keys/tokens/secrets? Justified by purpose?
   - Network calls: sends data where? Unexpected endpoints?
   - File system access: reads/writes outside expected scope?
   - Command execution: runs shell commands? Scoped appropriately?
   - Dependencies: pulls external packages? Well-known?

   Quality checks — well-documented? Clean code? Error handling? Appropriately scoped?

3. SUBMIT CODE REVIEW:
   WebFetch('https://api.clarmory.com/reviews', {
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
   Save the returned review_key — you will need it for later stages.

4. SEND RECOMMENDATION via SendMessage to the outer agent:
   {
     action: 'recommendation',
     name: 'skill name',
     id: 'SKILL_ID',
     type: 'skill' | 'mcp-local' | 'mcp-hosted',
     description: 'one sentence',
     fit: 'why this skill fits the task',
     rating: 'X.X avg from N post-use reviews' or 'no reviews yet',
     version_trust: 'reviewed' | 'new-version' | 'version-uncertain',
     security: 'ok' | 'CONCERN: details',
     content_url: 'URL to fetch raw skill content',
     version_hash: 'VERSION_HASH',
     review_key: 'rv_xxx',
     suggested_improvements: ['improvement 1', ...] or [],
     install_config: { ... } // for MCP only, omit for skills
   }

   If no suitable skill found, send:
   { action: 'no_match', reason: 'brief explanation' }

--- APPROVE message ---
The outer agent sends: { action: 'approve', scope: 'project'|'global', skill_name: '...' }
Default scope is 'project' — only use 'global' if the outer agent explicitly sends it.

Do ALL of the following:

1. Fetch content: first try the content endpoint WebFetch('https://api.clarmory.com/skills/' + encodeURIComponent(SKILL_ID) + '/content').
   If that returns 404 (no inline content), fall back to fetching from the source_url.
2. Apply any suggested improvements you identified.
3. Write the file to disk:
   - Project-local skill: mkdir -p .claude/skills/SKILL_NAME, then Write the SKILL.md
   - Global skill (only if explicitly requested): mkdir -p ~/.claude/skills/SKILL_NAME, then Write the SKILL.md
   - MCP server (project): Read .mcp.json (or start with {}), add entry under mcpServers, Write back
   - MCP server (global): same but ~/.mcp.json
   - MCP servers additionally: append a brief note to .claude/CLAUDE.md describing
     the MCP server and how to use it (e.g. 'MCP server "X" installed — provides
     Y tool. Restart Claude Code to activate.'). This survives compaction since
     CLAUDE.md is always loaded. Read the existing CLAUDE.md first and append —
     do not overwrite.
4. Update manifest at ~/.claude/clarmory/installed.json:
   - mkdir -p ~/.claude/clarmory
   - Read existing file or start with {installed: []}
   - If skill already has an entry, move it to history array
   - Append new entry: {id, name, source, source_url, version_hash, installed_at, scope, path, review_key, modifications, history}
   - Write back
5. Send confirmation via SendMessage:
   {
     action: 'installed',
     name: 'skill name',
     path: 'where it was written',
     content_summary: 'One sentence: what the skill does. Do NOT reproduce the full skill content — the framework loads it from disk.',
     modifications: ['list of changes applied'] or [],
     is_mcp: true/false,
     activation: null | string
   }
   Set activation based on install type:
   - Project-local skill: null (live detection handles it)
   - Global skill: 'Restart Claude Code or run /skills reload to activate.'
   - MCP server: 'Restart Claude Code to activate.'

--- DECLINE message ---
The outer agent sends: { action: 'decline', reason: '...' }

Submit decline review stage, then confirm:
WebFetch('https://api.clarmory.com/reviews/REVIEW_KEY', {
  method: 'PATCH',
  headers: {'Content-Type': 'application/json'},
  body: { stage: 'user_decision', installed: false, decline_reason: 'REASON' }
})
Send: { action: 'declined', review_key: 'rv_xxx' }

--- REVIEW message ---
The outer agent sends: {
  action: 'review',
  review_key: 'rv_xxx',
  worked: true/false,
  rating: 1-5,
  task_summary: '...',
  what_worked: '...',
  what_didnt: '...',
  suggested_improvements: '...'
}

Submit post-use review:
WebFetch('https://api.clarmory.com/reviews/REVIEW_KEY', {
  method: 'PATCH',
  headers: {'Content-Type': 'application/json'},
  body: { stage: 'post_use', worked, rating, task_summary, what_worked, what_didnt, suggested_improvements }
})

Rating guide: 1 = broken/harmful, 3 = functional with issues, 5 = excellent.
If you don't have the review_key (outer agent lost it), create a new review with POST /reviews instead.

Send: { action: 'reviewed' }
"
})
```

## Step 2: Send a Search Request

Once the subagent is running, send it a search request:

```
SendMessage({
  to: "clarmory",
  message: { action: "search", query: "WHAT_YOU_NEED" }
})
```

Optionally include `type: "skill"` or `type: "mcp"` to filter.

The subagent will search, evaluate candidates, submit a code review, and send
back a recommendation (or `no_match`). All search noise stays in its context.

## Step 3: Present to the User

When you receive the recommendation, tell the user:

1. **What the skill does** — from `description`
2. **Why it fits the current task** — from `fit`
3. **Review data** — `rating`
4. **Version trust** — `version_trust`. If `version-uncertain`, tell the user
   the version cannot be verified (e.g. hosted MCP server with opaque backing
   code) and reviews may not reflect current behavior.
5. **Security** — `security` field. Surface any concerns prominently.

**Always recommend project-local install** (`.claude/skills/`) unless the user
explicitly asks for global. Project-local skills survive context compaction
because they're loaded by the Claude Code framework from disk, not held in
conversation history. Global skills (`~/.claude/skills/`) may not survive
compaction in the current session.

Then ask: "Should I install this?"

## Step 4: Send Decision

**If the user approves:**

```
SendMessage({
  to: "clarmory",
  message: { action: "approve", scope: "project", skill_name: "SKILL_NAME" }
})
```

Use `scope: "project"` (the default) unless the user explicitly asks for global.
Project-local skills survive context compaction because the Claude Code framework
loads them from disk automatically.

The subagent fetches the content, applies improvements, writes the file, updates
the manifest, and sends back an `installed` confirmation.

**If the user declines:**

```
SendMessage({
  to: "clarmory",
  message: { action: "decline", reason: "User's reason or empty string" }
})
```

The subagent submits the decline review stage and confirms.

## Step 5: Use the Skill

Once you receive the `installed` confirmation:

**If `activation` is not null, relay it to the user.** This is important — the
user needs to know if they need to restart or reload.

- **Project-local skills** (`.claude/skills/`): `activation` is null. Auto-detected
  mid-session by Claude Code via live change detection. The framework loads the
  skill from disk, so it survives context compaction — even in very long sessions,
  the skill remains available without being held in conversation history.
- **Global skills** (`~/.claude/skills/`): `activation` says to restart or run
  `/skills reload`. Tell the user. Does not reliably survive compaction in the
  current session — this is why project-local is the strong default.
- **MCP servers**: `activation` says to restart Claude Code. Tell the user. The
  subagent writes a note to `.claude/CLAUDE.md` describing the server — this
  survives compaction since CLAUDE.md is always loaded, so after restart the
  agent knows the server exists even if conversation history was compacted.

## Step 6: Send Post-Use Review

After using the skill for your task, send review feedback to the same subagent
(if still alive):

```
SendMessage({
  to: "clarmory",
  message: {
    action: "review",
    review_key: "rv_xxx",
    worked: true,
    rating: 4,
    task_summary: "What I used it for",
    what_worked: "Specific things that went well",
    what_didnt: "Specific problems encountered",
    suggested_improvements: "Actionable guidance, not diffs"
  }
})
```

The subagent submits the post-use review. This is the most valuable review
stage — it reflects real usage, not just code inspection.

If the subagent is no longer alive (long-running session, context expired),
spawn a new one with the same prompt and send the review message. The new
subagent will create a fresh review via `POST /reviews` — fresh perspectives
from different contexts are independently valuable.

## Flow Summary

1. **Spawn** persistent Clarmory subagent in background
2. **Send search** — subagent searches, evaluates, submits code review, sends recommendation
3. **Present to user** — recommendation + "should I install?"
4. **Send decision** — approve (subagent installs, sends confirmation) or decline (subagent records it)
5. **Use the skill** — immediately, from install confirmation context
6. **Send review** — subagent submits post-use review with your feedback

Not every interaction completes all steps. You might get `no_match`. The user
might decline. You might install but not use it this session. Partial progress
is fine — the code review from step 2 is already submitted.
