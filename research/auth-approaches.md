# Review Authentication: Research & Recommendation

## Problem

Clarmory reviews are submitted by AI agents running in Claude Code, not humans
in browsers. We need to authenticate reviewers to prevent:

- **Astroturfing**: Skill authors submitting hundreds of fake positive reviews
- **Sabotage**: Competitors submitting fake negative reviews or false security flags
- **Spam**: Bots flooding the review database with garbage

Constraints:
- Minimal friction — agents should be able to submit reviews without user setup
- No browser-based OAuth flows (agents don't have browsers)
- Must work from the agent's environment (Bash, WebFetch, file access)
- Ideally zero-config for the user on first use

## Environment Analysis

What identity signals does a Claude Code agent actually have?

| Signal | Available? | Notes |
|--------|-----------|-------|
| `$CLAUDECODE=1` | Yes | Proves nothing — trivially set |
| `$USER` / `$HOME` | Yes | Local username, no global uniqueness |
| Claude OAuth token | Yes | At `~/.claude/.credentials.json`. Has `sk-ant-oat01-*` access token with scopes including `user:profile`. This is the strongest identity signal — it's tied to an Anthropic account. |
| `$CLAUDE_SESSION_ID` | No | Not currently exposed as env var |
| Machine fingerprint | Partial | Hostname, IP, etc. — unreliable (NAT, VPNs, shared IPs) |
| GitHub CLI (`gh`) | Maybe | Present if user has it installed; not universal |

**Key finding**: The Claude OAuth token at `~/.claude/.credentials.json` is the
strongest available signal. It's tied to an Anthropic account (which requires
email verification and, for Max subscribers, payment). This is a high-quality
identity anchor that exists on every Claude Code installation with zero setup.

## Approaches Evaluated

### 1. API Keys (Classic)

**How it works**: User registers on clarmory.dev, gets an API key, configures
it in `~/.claude/clarmory/config.json`. Agent includes it in requests.

**Pros**: Simple to implement, well-understood, easy to revoke.

**Cons**: Requires user to visit a website and manually configure. This is the
exact friction we want to avoid. An agent discovering Clarmory for the first
time cannot submit reviews until the user goes through setup. Kills autonomous
operation.

**Verdict**: Too much friction. Reject.

### 2. GitHub OAuth (Device Flow)

**How it works**: Agent initiates GitHub device flow (`POST
https://github.com/login/device/code`), gets a user code, asks user to visit
`github.com/login/device` and enter it. Polls for token. Uses GitHub identity
for reviews.

**Pros**: Strong identity (GitHub accounts are real). Device flow works without
a browser redirect (user visits URL manually). GitHub is ubiquitous among
developers.

**Cons**: Requires user action (visit URL, enter code) on first use per machine.
Breaks autonomous operation for that first session. Not every Claude Code user
has a GitHub account (possible but unlikely for our audience). Token management
(refresh, expiry) adds complexity.

**Verdict**: Good identity quality but too much setup friction. Consider as
optional upgrade (see hybrid approach below).

### 3. Claude OAuth Attestation (Recommended)

**How it works**: The agent already has an OAuth token for claude.ai at
`~/.claude/.credentials.json` with `user:profile` scope. The agent sends this
token (or a derivative) to Clarmory's API. Clarmory's backend calls the
Anthropic profile endpoint to verify the token is valid and extract a stable
user identifier (account ID or email hash). Reviews are tied to this identity.

**Flow**:
1. Agent reads access token from `~/.claude/.credentials.json`
2. Agent sends token to `POST /auth/claude` on Clarmory API
3. Clarmory backend calls Anthropic's profile API to validate
4. If valid, Clarmory returns a short-lived Clarmory session token
5. Agent uses Clarmory session token for subsequent review submissions

**Pros**:
- **Zero setup**: Every Claude Code installation already has this token.
- **Strong identity**: Tied to an Anthropic account (email-verified, often
  payment-verified for Max/Team subscribers).
- **Hard to mass-create**: Creating fake Anthropic accounts at scale is
  non-trivial (email verification, possibly payment).
- **Natural rate limiting**: One Anthropic account = one reviewer identity.
  Multiple reviews from same identity are visible and discountable.
- **Agent can do it autonomously**: No user action needed. Read a file, make
  an HTTP call, done.

**Cons**:
- **Privacy concern**: Sending the user's Claude OAuth token to a third-party
  API (Clarmory) is sensitive. The user should be informed and consent. Mitigated
  by: (a) SKILL.md explicitly documents this, (b) user must approve the
  installation of the Clarmory skill, (c) Clarmory only needs to call the
  profile endpoint — we could design a flow where the agent calls Anthropic's
  profile API itself and sends a signed attestation, avoiding Clarmory ever
  seeing the raw token.
- **Dependency on Anthropic API**: If Anthropic's profile endpoint changes or
  becomes unavailable, auth breaks. Mitigated by caching validated identities.
- **Token-forwarding variant is a security risk**: If we have agents send their
  raw OAuth token to our API, a compromised/malicious Clarmory server could
  abuse it. Strongly prefer the attestation variant (see below).

**Attestation variant (preferred)**:
Instead of sending the raw token to Clarmory, the agent:
1. Calls Anthropic's profile API itself: `GET https://api.anthropic.com/v1/me`
   (hypothetical — need to verify actual endpoint) with its OAuth token
2. Gets back a signed profile response (or at minimum, an account ID)
3. Sends the account ID + some proof to Clarmory

The challenge: without a signed response from Anthropic, the agent could fake
the account ID. We need Clarmory to verify independently. This likely means
Clarmory needs to see the token (even briefly) to validate it server-side.

**Practical compromise**: Agent sends the OAuth token to Clarmory over HTTPS.
Clarmory validates it against Anthropic's API, extracts a stable account
identifier, stores only the identifier (never the token), and returns a Clarmory
session token. The raw OAuth token is never persisted. This is the same pattern
used by "Sign in with Google/GitHub" — the relying party sees the token briefly
to verify it, then discards it.

**Verdict**: Best balance of zero-friction and strong identity. Recommend as
primary auth method.

### 4. Proof-of-Work

**How it works**: To submit a review, the agent must solve a computational
puzzle (e.g., find a nonce where `SHA256(review_content + nonce)` has N leading
zeros). Difficulty calibrated so one review takes ~5-10 seconds of CPU.

**Pros**: No identity needed. Anonymous reviews that are expensive to spam.
Works without any setup or accounts.

**Cons**:
- Claude Code runs on user machines — burning CPU for PoW is rude, especially
  on constrained hardware (Raspberry Pi, etc.).
- Doesn't actually prevent astroturfing — a motivated attacker runs the PoW on
  cloud GPUs cheaply.
- No identity linkage — can't flag "all reviews from this entity are suspicious."
- Adds latency to every review submission.

**Verdict**: Poor fit. Cost falls on legitimate users, not attackers. Reject as
primary method. Could work as a supplementary anti-spam layer (very low
difficulty, just to slow automated flooding).

### 5. IP-Based Rate Limiting

**How it works**: Cloudflare Workers have access to `request.cf.ip`. Rate limit
review submissions per IP.

**Pros**: Zero friction, works immediately, no implementation on client side.

**Cons**:
- NAT: Many users share IPs (corporate networks, university networks, carrier
  NAT). Rate limits would be unfairly restrictive.
- VPNs: Trivially bypassed by switching VPN servers.
- No identity: Can't build reputation or flag suspicious reviewers.
- Cloudflare Workers have `request.headers.get('cf-connecting-ip')` which is
  reliable for the direct client IP, but tells us nothing about identity.

**Verdict**: Useful as a supplementary rate-limit layer, not a primary auth
mechanism. Every API should have basic IP rate limiting regardless.

### 6. Signed Reviews (Agent Keypairs)

**How it works**: On first Clarmory use, the agent generates an Ed25519 keypair,
stores the private key locally (`~/.claude/clarmory/identity.key`), registers
the public key with the API. Reviews are signed with the private key.

**Pros**: Cryptographic proof of review origin. Can build reviewer reputation
over time. Works offline (sign locally, submit later).

**Cons**:
- **Sybil-trivial**: Creating a new keypair takes microseconds. An attacker
  generates 1000 keypairs = 1000 "unique" reviewers. No cost barrier.
- Reputation systems help but take time to build — a new keypair with no
  reputation is indistinguishable from a legitimate new user.
- Key management complexity (backup, migration between machines).
- Doesn't prove the reviewer is a real Claude Code user.

**Verdict**: Cryptographic identity without a cost barrier is security theater
against astroturfing. A keypair only proves "the same entity signed this" — it
doesn't prove "this is a real, unique user." Reject as primary method. Useful
for review integrity (tamper detection) if combined with real identity.

## Recommendation: Tiered Approach

### Tier 1: Claude OAuth Attestation (primary, zero-config)

Every review is tied to a verified Anthropic account. Implementation:

```
Agent                           Clarmory API                 Anthropic API
  |                                  |                            |
  |  POST /auth/token               |                            |
  |  {claude_token: "sk-ant-..."}   |                            |
  |--------------------------------->|                            |
  |                                  |  GET /v1/profile           |
  |                                  |  Auth: Bearer sk-ant-...   |
  |                                  |--------------------------->|
  |                                  |                            |
  |                                  |  {account_id: "acct_123"} |
  |                                  |<---------------------------|
  |                                  |                            |
  |  {clarmory_token: "ct_...",     |                            |
  |   expires_in: 3600}             |                            |
  |<---------------------------------|                            |
  |                                  |                            |
  |  POST /reviews                  |                            |
  |  Auth: Bearer ct_...            |                            |
  |  {extension_id: ..., ...}       |                            |
  |--------------------------------->|                            |
```

- Agent reads `~/.claude/.credentials.json`, sends token once per session
- Clarmory validates against Anthropic, extracts stable account ID, returns
  a short-lived Clarmory session token (1 hour)
- All reviews in that session use the Clarmory token
- Clarmory stores `account_id_hash` (not raw account ID) to preserve privacy
- One Anthropic account = one reviewer identity. Multiple reviews visible.

**Rate limits per identity**: 10 reviews/hour, 50/day. Generous for legitimate
use, prohibitive for mass gaming.

**Privacy**: The SKILL.md must clearly document that the agent sends the Claude
OAuth token to Clarmory for verification. The user consents by installing the
skill. Clarmory never stores the raw token — only a hash of the account ID.

### Tier 2: IP Rate Limiting (supplementary, always-on)

Cloudflare Workers rate limiting on `cf-connecting-ip`:
- 60 requests/minute per IP across all endpoints
- 20 review submissions/hour per IP
- Applied regardless of auth tier

This catches automated flooding even if someone compromises or fakes auth.

### Tier 3: GitHub Identity (optional upgrade)

For users who want stronger reviewer reputation or want to link reviews to their
GitHub profile, offer optional GitHub device flow authentication. This is an
upgrade, not a requirement. Benefits:

- Public reviewer identity (GitHub username visible on reviews)
- Stronger Sybil resistance (GitHub accounts with history are harder to fake)
- Cross-references ("this reviewer also maintains 5 popular repos")

Not needed for MVP. Add when/if reviewer reputation becomes important.

## Open Questions

1. **Does Anthropic's OAuth token support a profile/identity endpoint?** The
   `user:profile` scope in the credentials suggests yes, but the exact endpoint
   needs verification. If no such endpoint exists, we fall back to using the
   token itself as a bearer token for an Anthropic API call that returns account
   info (e.g., usage endpoint, billing endpoint, any authenticated endpoint that
   returns an account ID).

2. **Token refresh**: The OAuth token has an `expiresAt` and a `refreshToken`.
   If the token is expired when the agent tries to auth with Clarmory, the agent
   would need to refresh it first. Claude Code presumably handles this — we just
   need to document "read the current token from the credentials file."

3. **Anthropic ToS**: Using the Claude OAuth token to authenticate with a
   third-party service (Clarmory) may have ToS implications. Need to verify this
   is permitted. If not, we fall back to GitHub device flow as primary (Tier 3
   becomes Tier 1).

4. **Multi-machine users**: A single Anthropic account used on multiple machines
   appears as one reviewer identity. This is correct behavior (one person = one
   voice) but worth noting.

## Implementation Complexity

| Approach | Clarmory API work | SKILL.md changes | User friction |
|----------|------------------|-------------------|---------------|
| Claude OAuth | Medium (auth endpoint, token validation, session management) | Small (add auth step to flow) | Zero |
| IP rate limiting | Small (Cloudflare config) | None | Zero |
| GitHub device flow | Medium (OAuth flow, token storage) | Medium (add auth flow) | One-time URL visit |
| API keys | Small (key generation, validation) | Small | Manual registration |
| Proof-of-work | Small (puzzle generation, verification) | Small | CPU cost per review |
| Keypairs | Medium (key registration, signature verification) | Medium (key generation) | Zero (but Sybil-trivial) |

## Summary

**Primary recommendation**: Claude OAuth attestation (Tier 1) + IP rate limiting
(Tier 2). This gives us strong identity with zero user friction. Every Claude
Code user already has the credential. Adding GitHub as an optional Tier 3 later
provides a reputation upgrade path.

**Fallback if Anthropic OAuth validation isn't feasible**: GitHub device flow as
primary (one-time setup per machine) + IP rate limiting. Higher friction but
proven identity model.

**Reject**: API keys (too much friction), proof-of-work (punishes legitimate
users), standalone keypairs (Sybil-trivial).
