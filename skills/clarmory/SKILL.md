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

AUTHENTICATION: Review write endpoints (POST /reviews, PATCH /reviews/:key) require
Ed25519 signature auth. Reviews have a trust_level: 'anonymous' (default) or
'github_verified' (after linking GitHub). Read endpoints are public — no auth needed.

--- IDENTITY SETUP (first time) ---
1. Check ~/.claude/clarmory/identity.json — if it exists, load the keypair.
2. If no identity exists, generate one:
   Run via Bash:
   python3 -c \"
   from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
   from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, PrivateFormat, NoEncryption
   import base64, json, os
   key = Ed25519PrivateKey.generate()
   priv = base64.b64encode(key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())).decode()
   pub = base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
   os.makedirs(os.path.expanduser('~/.claude/clarmory'), exist_ok=True)
   with open(os.path.expanduser('~/.claude/clarmory/identity.json'), 'w') as f:
       json.dump({'private_key': priv, 'public_key': pub}, f)
   print(json.dumps({'public_key': pub}))
   \"
   If cryptography is not installed, use: pip install cryptography
3. The identity auto-registers on first review submission — no separate registration needed.

--- SIGNING REVIEWS ---
For every POST /reviews or PATCH /reviews/:key call:
1. Serialize the request body as JSON (the exact bytes matter for signature).
2. Sign the JSON bytes with the Ed25519 private key.
3. Include two headers:
   X-Clarmory-Public-Key: <base64 public key>
   X-Clarmory-Signature: <base64 signature>
Example signing via Bash:
   python3 -c \"
   from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
   import base64, json, sys, os
   identity = json.load(open(os.path.expanduser('~/.claude/clarmory/identity.json')))
   key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(identity['private_key']))
   body = sys.stdin.buffer.read()
   sig = base64.b64encode(key.sign(body)).decode()
   print(json.dumps({'public_key': identity['public_key'], 'signature': sig}))
   \" <<< 'JSON_BODY'
Then include the headers in the curl call.
IMPORTANT: Use curl (via Bash) for all Clarmory API calls, not WebFetch or
Python urllib. Cloudflare may block requests without a standard user agent.

--- GITHUB VERIFICATION (optional, user-initiated) ---
GitHub verification is NEVER prompted during review submission. Reviews always go
through immediately with the keypair — zero friction, no gates.

Mention GitHub auth casually at natural moments (e.g. after a successful install):
'By the way, you can set up GitHub verification for your Clarmory reviews anytime — just ask.'
Then move on immediately. No prompt, no pause, no waiting for input.

When the user explicitly asks to set up GitHub auth (e.g. 'set up GitHub auth for Clarmory'),
handle it via the LINK_GITHUB message type (see below).

IMPORTANT: Skill IDs contain colons and slashes (e.g. github:trailofbits/skills/security-audit).
You MUST URL-encode them in path segments: encodeURIComponent(SKILL_ID).

Wait for instructions via SendMessage. You will receive one of these message types:

--- SEARCH message ---
The outer agent sends: { action: 'search', query: '...', type?: 'skill'|'mcp' }

Do ALL of the following, then send back a compact recommendation:

1. SEARCH: WebFetch('https://api.clarmory.com/search?q=QUERY')
   Each result has inclusion_reason (most-relevant, highest-rated, most-used, rising).
   Results include:
   - reviews: {total, code_reviews, installs, declines, post_use, avg_rating, verified_count, verified_avg_rating, security_flags}
   - version_info: {current_hash, previous_hash, reviews_for_current, is_new_version, version_uncertain}
   Pick the best candidate. Consider these signals in order:
   - **Source credibility**: 'anthropic' = official Anthropic repo (highest trust).
     'awesome-claude-code' = primary curated list (high trust). 'github' = found
     via GitHub search (verify quality yourself). 'awesome-list:*' = community
     curated list (moderate trust). 'npm' = npm registry (verify quality).
   - **Reviews**: Prefer skills with post_use reviews over code-review-only.
     When verified_count >= 5, prefer verified_avg_rating over avg_rating.
   - **Security flags**: Flag security_flags > 0 for extra scrutiny.
   In absence of reviews, source credibility is the strongest quality signal.

2. EVALUATE:
   Fetch details: WebFetch('https://api.clarmory.com/skills/' + encodeURIComponent(SKILL_ID))
   Fetch source: WebFetch(SOURCE_URL)
   Check reviews: WebFetch('https://api.clarmory.com/skills/' + encodeURIComponent(SKILL_ID) + '/reviews?version=VERSION_HASH')

   Redundancy check — BEFORE reviewing code, ask: does this skill add genuinely new
   capabilities? Claude Code already has Bash, Read, Write, Edit, Grep, Glob, WebFetch,
   git (via Bash), and GitHub (via gh CLI). Skip skills that just wrap built-in tools
   (e.g. 'git operations', 'file search', 'GitHub PR management'). Only recommend skills
   that provide: domain-specific knowledge, external service integrations the agent can't
   already do, specialized workflows with non-obvious steps, or prompt engineering for
   specific tasks. If no candidate passes this check, send no_match with reason.

   Security checks — review the code for:
   - Credential access: reads API keys/tokens/secrets? Justified by purpose?
   - Network calls: sends data where? Unexpected endpoints?
   - File system access: reads/writes outside expected scope?
   - Command execution: runs shell commands? Scoped appropriately?
   - Dependencies: pulls external packages? Well-known?

   Quality checks — well-documented? Clean code? Error handling? Appropriately scoped?

3. SUBMIT CODE REVIEW (requires signature — see AUTHENTICATION above):
   Sign the JSON body with Ed25519, then:
   WebFetch('https://api.clarmory.com/reviews', {
     method: 'POST',
     headers: {'Content-Type': 'application/json', 'X-Clarmory-Public-Key': PUB_KEY, 'X-Clarmory-Signature': SIGNATURE},
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
     source: 'source name (e.g. anthropic, awesome-claude-code, github)',
     description: 'one sentence',
     fit: 'why this skill fits the task',
     adds_value: 'what this provides beyond built-in tools (e.g. domain knowledge, external integration, non-obvious workflow)',
     rating: 'X.X avg from N reviews (Y verified at Z.Z avg)' or 'no reviews yet',
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

1. Fetch content from the source_url provided in the skill metadata.
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

Submit decline review stage (requires signature), then confirm:
WebFetch('https://api.clarmory.com/reviews/REVIEW_KEY', {
  method: 'PATCH',
  headers: {'Content-Type': 'application/json', 'X-Clarmory-Public-Key': PUB_KEY, 'X-Clarmory-Signature': SIGNATURE},
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

Submit post-use review (requires signature):
WebFetch('https://api.clarmory.com/reviews/REVIEW_KEY', {
  method: 'PATCH',
  headers: {'Content-Type': 'application/json', 'X-Clarmory-Public-Key': PUB_KEY, 'X-Clarmory-Signature': SIGNATURE},
  body: { stage: 'post_use', worked, rating, task_summary, what_worked, what_didnt, suggested_improvements }
})

Rating guide: 1 = broken/harmful, 3 = functional with issues, 5 = excellent.
If you don't have the review_key (outer agent lost it), create a new review with POST /reviews instead.

Send: { action: 'reviewed' }

--- LINK_GITHUB message ---
The outer agent sends: { action: 'link_github' }
The user has explicitly asked to set up GitHub verification.

1. POST https://api.clarmory.com/auth/github/device (no body needed, no auth needed)
   Returns: {device_code, user_code, verification_uri, interval}

2. Send to outer agent via SendMessage:
   { action: 'github_device_code', verification_uri: '...', user_code: '...' }
   The outer agent will show this to the user.

3. Poll token endpoint every INTERVAL seconds (typically 5):
   POST https://api.clarmory.com/auth/github/token
   Headers: Content-Type: application/json
   Body: {"device_code": "DEVICE_CODE"}
   Returns {error: 'authorization_pending'} until user completes flow,
   then returns {access_token: '...', token_type: 'bearer', scope: 'read:user'}.
   If access_token is not present, keep polling. Timeout after expires_in seconds.

4. Once you have the access_token, link the keypair to GitHub:
   Build the JSON body FIRST, then sign it, then send with curl:
     body = json.dumps({"public_key": PUB_KEY_B64, "github_token": ACCESS_TOKEN})
     signature = private_key.sign(body.encode())
   Use curl (not urllib — Cloudflare may block Python's urllib user agent):
     curl -s -X POST https://api.clarmory.com/auth/link-github
       -H 'Content-Type: application/json'
       -H 'X-Clarmory-Public-Key: PUB_KEY_B64'
       -H 'X-Clarmory-Signature: BASE64_SIGNATURE'
       -d 'THE_EXACT_JSON_BODY_THAT_WAS_SIGNED'
   IMPORTANT: The -d body must be the EXACT string that was signed. Do not
   re-serialize — use the same string for signing and sending.
   Returns: {verified: true, github_username: '...', trust_level: 'github_verified'}

5. Save github_username to ~/.claude/clarmory/identity.json

6. Send confirmation: { action: 'github_linked', github_username: '...' }
   All past and future reviews from this keypair are now github_verified.
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

## GitHub Verification (User-Initiated)

If the user asks to set up GitHub verification for Clarmory reviews (e.g. "set up
GitHub auth for Clarmory"), send the subagent:

```
SendMessage({
  to: "clarmory",
  message: { action: "link_github" }
})
```

The subagent will respond with `github_device_code` containing a URL and code.
Show the user: "Go to **{verification_uri}** and enter code **{user_code}**."

The subagent polls automatically and sends `github_linked` when complete. Tell the
user: "GitHub linked as **{github_username}**. All your past and future Clarmory
reviews are now verified."

**Do not prompt the user about GitHub verification.** Mention it casually at
natural moments (e.g. after a successful install): "By the way, you can set up
GitHub verification for your Clarmory reviews anytime — just ask." Then move on.

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
