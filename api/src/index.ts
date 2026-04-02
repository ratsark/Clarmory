import schemaSQL from "../schema.sql";
import seedSQL from "../scripts/seed.sql";

export interface Env {
  DB: D1Database;
  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;
  ADMIN_SECRET: string;
}

type RouteHandler = (
  request: Request,
  env: Env,
  params: Record<string, string>
) => Promise<Response>;

// Simple router — no dependencies needed for a handful of routes.
// Skill IDs contain colons and slashes (e.g. "github:trailofbits/skills/foo"),
// so callers must URL-encode them. The router decodes params automatically.
function matchRoute(
  method: string,
  path: string,
  routes: Array<{ method: string; pattern: string; handler: RouteHandler }>
): { handler: RouteHandler; params: Record<string, string> } | null {
  for (const route of routes) {
    if (route.method !== method) continue;
    const paramNames: string[] = [];
    const regexStr = route.pattern.replace(/:(\w+)/g, (_, name) => {
      paramNames.push(name);
      return "([^/]+)";
    });
    const match = path.match(new RegExp(`^${regexStr}$`));
    if (match) {
      const params: Record<string, string> = {};
      paramNames.forEach((name, i) => {
        params[name] = decodeURIComponent(match[i + 1]);
      });
      return { handler: route.handler, params };
    }
  }
  return null;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// --- Request log (in-memory, for test observability) ---

interface RequestLogEntry {
  method: string;
  path: string;
  query: Record<string, string>;
  timestamp: string;
  status: number;
}

const MAX_LOG_ENTRIES = 100;
const requestLog: RequestLogEntry[] = [];

function logRequest(
  method: string,
  path: string,
  query: Record<string, string>,
  status: number
) {
  requestLog.push({
    method,
    path,
    query,
    timestamp: new Date().toISOString(),
    status,
  });
  if (requestLog.length > MAX_LOG_ENTRIES) {
    requestLog.splice(0, requestLog.length - MAX_LOG_ENTRIES);
  }
}

// --- SQL helpers ---

// Split SQL into individual statements, handling comments, string literals,
// and BEGIN...END trigger blocks with embedded semicolons.
function splitStatements(sql: string): string[] {
  const statements: string[] = [];
  let current = "";
  let inString = false;
  let beginDepth = 0;

  for (let i = 0; i < sql.length; i++) {
    const ch = sql[i];

    if (ch === "'" && !inString) { inString = true; current += ch; continue; }
    if (ch === "'" && inString) {
      current += ch;
      if (sql[i + 1] === "'") { current += "'"; i++; } else { inString = false; }
      continue;
    }
    if (!inString && ch === "-" && sql[i + 1] === "-") {
      const eol = sql.indexOf("\n", i);
      i = eol === -1 ? sql.length : eol;
      current += " ";
      continue;
    }
    if (!inString) {
      const upper = sql.substring(i, i + 6).toUpperCase();
      if (upper.startsWith("BEGIN") && /\s/.test(sql[i + 5] || "")) beginDepth++;
      const endStr = sql.substring(i, i + 4).toUpperCase();
      if (endStr === "END" && beginDepth > 0 && /[\s;]/.test(sql[i + 3] || "")) beginDepth--;
    }
    if (!inString && beginDepth === 0 && ch === ";") {
      const trimmed = current.trim();
      if (trimmed) statements.push(trimmed);
      current = "";
      continue;
    }
    current += ch;
  }
  const trimmed = current.trim();
  if (trimmed) statements.push(trimmed);
  return statements;
}

// --- Auth helpers ---

// Check IP rate limit. Returns true if within limit, false if exceeded.
async function checkRateLimit(
  db: D1Database,
  ip: string,
  action: string,
  windowFn: () => string,
  maxCount: number
): Promise<boolean> {
  const window = windowFn();
  const row = await db
    .prepare(
      "SELECT count FROM rate_limits WHERE ip = ? AND action = ? AND window = ?"
    )
    .bind(ip, action, window)
    .first<{ count: number }>();

  if (row && row.count >= maxCount) return false;

  await db
    .prepare(
      `INSERT INTO rate_limits (ip, action, window, count)
       VALUES (?, ?, ?, 1)
       ON CONFLICT(ip, action, window) DO UPDATE SET count = count + 1`
    )
    .bind(ip, action, window)
    .run();

  return true;
}

function hourWindow(): string {
  return new Date().toISOString().slice(0, 13); // "2026-04-02T14"
}

function dayWindow(): string {
  return new Date().toISOString().slice(0, 10); // "2026-04-02"
}

function getClientIp(request: Request): string {
  return (
    request.headers.get("cf-connecting-ip") ||
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    "unknown"
  );
}

// --- Ed25519 signature verification ---

// Verify an Ed25519 signature over the request body.
// Agent sends: X-Clarmory-Public-Key (base64), X-Clarmory-Signature (base64)
// The signed payload is the raw request body bytes.
async function verifySignature(
  publicKeyB64: string,
  signatureB64: string,
  bodyBytes: Uint8Array
): Promise<boolean> {
  try {
    const publicKeyBytes = Uint8Array.from(atob(publicKeyB64), (c) =>
      c.charCodeAt(0)
    );
    const signatureBytes = Uint8Array.from(atob(signatureB64), (c) =>
      c.charCodeAt(0)
    );

    const key = await crypto.subtle.importKey(
      "raw",
      publicKeyBytes,
      { name: "Ed25519" },
      false,
      ["verify"]
    );

    return await crypto.subtle.verify("Ed25519", key, signatureBytes, bodyBytes);
  } catch {
    return false;
  }
}

interface AuthResult {
  publicKey: string | null;
  trustLevel: "anonymous" | "pseudonymous" | "github_verified";
}

// Authenticate a review request. Three tiers:
// 1. No auth headers → anonymous (no identity tracking)
// 2. Valid keypair signature → pseudonymous (consistent identity) or github_verified
// 3. Invalid signature → rejected (401)
async function authenticateReview(
  db: D1Database,
  request: Request,
  ip: string
): Promise<{ auth: AuthResult; body: Record<string, unknown> } | Response> {
  const bodyBytes = new Uint8Array(await request.arrayBuffer());
  const bodyText = new TextDecoder().decode(bodyBytes);
  const body = JSON.parse(bodyText) as Record<string, unknown>;

  const publicKeyB64 = request.headers.get("x-clarmory-public-key");
  const signatureB64 = request.headers.get("x-clarmory-signature");

  // No auth headers → anonymous tier
  if (!publicKeyB64 && !signatureB64) {
    return {
      auth: { publicKey: null, trustLevel: "anonymous" },
      body,
    };
  }

  // Partial headers (one without the other) → reject
  if (!publicKeyB64 || !signatureB64) {
    return json(
      { error: "Both X-Clarmory-Public-Key and X-Clarmory-Signature headers are required when using keypair auth." },
      401
    );
  }

  // Both headers present → verify signature
  const valid = await verifySignature(publicKeyB64, signatureB64, bodyBytes);
  if (!valid) {
    return json({ error: "Invalid signature" }, 401);
  }

  // Look up or auto-register identity
  let identity = await db
    .prepare("SELECT public_key, trust_level FROM identities WHERE public_key = ?")
    .bind(publicKeyB64)
    .first<{ public_key: string; trust_level: string }>();

  if (!identity) {
    await db
      .prepare(
        "INSERT INTO identities (public_key, trust_level, ip_address) VALUES (?, 'pseudonymous', ?)"
      )
      .bind(publicKeyB64, ip)
      .run();
    identity = { public_key: publicKeyB64, trust_level: "pseudonymous" };
  }

  return {
    auth: {
      publicKey: publicKeyB64,
      trustLevel: identity.trust_level as "pseudonymous" | "github_verified",
    },
    body,
  };
}

// --- GitHub OAuth device flow endpoints ---

const githubDeviceCode: RouteHandler = async (_request, env) => {
  // Start the GitHub device flow using server-side client_id
  const ghResponse = await fetch("https://github.com/login/device/code", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      client_id: env.GITHUB_CLIENT_ID,
      scope: "read:user",
    }),
  });

  const ghBody = await ghResponse.json();
  return json(ghBody, ghResponse.status);
};

// Exchange a device code for an access token (server-side, uses client_secret)
const githubToken: RouteHandler = async (request, env) => {
  const body = (await request.json()) as Record<string, unknown>;
  const deviceCode = body.device_code as string | undefined;

  if (!deviceCode) {
    return json({ error: "device_code is required" }, 400);
  }

  const ip = getClientIp(request);
  const allowed = await checkRateLimit(env.DB, ip, "github_auth", hourWindow, 10);
  if (!allowed) {
    return json({ error: "GitHub auth rate limit exceeded" }, 429);
  }

  const ghResponse = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      client_id: env.GITHUB_CLIENT_ID,
      client_secret: env.GITHUB_CLIENT_SECRET,
      device_code: deviceCode,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    }),
  });

  const ghBody = await ghResponse.json();
  return json(ghBody, ghResponse.status);
};

const linkGithub: RouteHandler = async (request, env) => {
  const ip = getClientIp(request);

  // Rate limit GitHub auth attempts
  const allowed = await checkRateLimit(env.DB, ip, "github_auth", hourWindow, 10);
  if (!allowed) {
    return json({ error: "GitHub auth rate limit exceeded" }, 429);
  }

  // Read body as bytes for signature verification, then parse
  const bodyBytes = new Uint8Array(await request.arrayBuffer());
  const bodyText = new TextDecoder().decode(bodyBytes);
  const body = JSON.parse(bodyText) as Record<string, unknown>;

  const githubToken = body.github_token as string | undefined;
  const publicKeyB64 = body.public_key as string | undefined;
  const signatureB64 = request.headers.get("x-clarmory-signature");

  if (!githubToken || !publicKeyB64 || !signatureB64) {
    return json(
      { error: "github_token, public_key, and X-Clarmory-Signature header are required" },
      400
    );
  }

  // Verify the signature over the request body to prove keypair ownership
  const valid = await verifySignature(publicKeyB64, signatureB64, bodyBytes);
  if (!valid) {
    return json({ error: "Invalid signature — cannot prove keypair ownership" }, 401);
  }

  // Validate the GitHub token against GitHub's API
  const ghResponse = await fetch("https://api.github.com/user", {
    headers: {
      Authorization: `Bearer ${githubToken}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "Clarmory-API/1.0",
    },
  });

  if (!ghResponse.ok) {
    return json({ error: "Invalid GitHub token" }, 401);
  }

  const ghUser = (await ghResponse.json()) as { login: string };
  const githubUsername = ghUser.login;

  // Update or create the identity with GitHub verification
  const existing = await env.DB.prepare(
    "SELECT public_key FROM identities WHERE public_key = ?"
  )
    .bind(publicKeyB64)
    .first();

  if (existing) {
    await env.DB.prepare(
      "UPDATE identities SET github_username = ?, trust_level = 'github_verified' WHERE public_key = ?"
    )
      .bind(githubUsername, publicKeyB64)
      .run();
  } else {
    await env.DB.prepare(
      "INSERT INTO identities (public_key, github_username, trust_level, ip_address) VALUES (?, ?, 'github_verified', ?)"
    )
      .bind(publicKeyB64, githubUsername, ip)
      .run();
  }

  // Retroactive upgrade: update trust_level on ALL past reviews from this keypair
  await env.DB.prepare(
    "UPDATE reviews SET trust_level = 'github_verified' WHERE public_key = ?"
  )
    .bind(publicKeyB64)
    .run();

  return json({
    verified: true,
    github_username: githubUsername,
    trust_level: "github_verified",
  });
};

// --- Helpers ---

interface ReviewStatsRow {
  skill_id: string;
  version_hash: string | null;
  review_count: number;
  rated_count: number;
  avg_rating: number | null;
  verified_count: number;
  verified_rated_count: number;
  verified_avg_rating: number | null;
  security_flags: number;
  code_reviews: number;
  decline_count: number;
  post_use_reviews: number;
}

interface SkillRow {
  id: string;
  source: string;
  name: string;
  description: string;
  version_hash: string | null;
  source_url: string;
  install_type: string;
  metadata: string;
  indexed_at: string;
}

// Build the reviews summary object the SKILL.md expects
function buildReviewsSummary(stats: ReviewStatsRow | null) {
  if (!stats) {
    return {
      total: 0,
      code_reviews: 0,
      installs: 0,
      declines: 0,
      post_use: 0,
      avg_rating: null,
      verified_count: 0,
      verified_avg_rating: null,
      security_flags: 0,
    };
  }
  return {
    total: stats.review_count,
    code_reviews: stats.code_reviews,
    installs: stats.review_count - stats.decline_count,
    declines: stats.decline_count,
    post_use: stats.post_use_reviews,
    avg_rating: stats.avg_rating,
    verified_count: stats.verified_count,
    verified_avg_rating: stats.verified_avg_rating,
    security_flags: stats.security_flags,
  };
}

// Build version_info for a skill
function buildVersionInfo(
  skill: SkillRow,
  currentStats: ReviewStatsRow | null,
  allStats: ReviewStatsRow[]
) {
  const metadata = JSON.parse(skill.metadata || "{}");
  const previousVersions = allStats.filter(
    (s) => s.version_hash !== skill.version_hash
  );
  const previousHash =
    previousVersions.length > 0 ? previousVersions[0].version_hash : null;
  return {
    current_hash: skill.version_hash,
    previous_hash: previousHash,
    reviews_for_current: currentStats ? currentStats.review_count : 0,
    is_new_version: previousHash !== null && (currentStats?.review_count ?? 0) < 3,
    version_uncertain: metadata.version_opaque === true || skill.version_hash === null,
  };
}

// --- Route handlers ---

const searchSkills: RouteHandler = async (request, env) => {
  const url = new URL(request.url);
  const query = url.searchParams.get("q") || "";
  const typeFilter = url.searchParams.get("type");
  const limit = Math.min(
    parseInt(url.searchParams.get("limit") || "3"),
    20
  );

  if (!query.trim()) {
    return json({ error: "Query parameter 'q' is required" }, 400);
  }

  // Map type param to install_type values
  const installTypes: Record<string, string[]> = {
    skill: ["skill"],
    mcp: ["mcp-local", "mcp-hosted"],
  };

  const typeClause = typeFilter && installTypes[typeFilter]
    ? `AND s.install_type IN (${installTypes[typeFilter].map(() => "?").join(",")})`
    : "";
  const typeBinds = typeFilter && installTypes[typeFilter]
    ? installTypes[typeFilter]
    : [];

  // Most-relevant: weighted BM25 (name=10, description=1, tags=5)
  const relevantQuery = `
    SELECT s.*, 'most-relevant' AS inclusion_reason,
           bm25(skills_fts, 10.0, 1.0, 5.0) AS relevance
    FROM skills_fts fts
    JOIN skills s ON s.rowid = fts.rowid
    WHERE skills_fts MATCH ? ${typeClause}
    ORDER BY relevance
    LIMIT ?
  `;

  // Highest-rated: by avg review rating (only rated skills)
  const ratedQuery = `
    SELECT s.*, 'highest-rated' AS inclusion_reason
    FROM skills s
    JOIN review_stats rs ON rs.skill_id = s.id
      AND (rs.version_hash = s.version_hash OR (rs.version_hash IS NULL AND s.version_hash IS NULL))
    WHERE rs.avg_rating IS NOT NULL
      AND s.id IN (
        SELECT s2.id FROM skills_fts fts2
        JOIN skills s2 ON s2.rowid = fts2.rowid
        WHERE skills_fts MATCH ?
      )
      ${typeClause}
    ORDER BY rs.avg_rating DESC, rs.review_count DESC
    LIMIT ?
  `;

  // Most-used: by total review count (proxy for installs)
  const usedQuery = `
    SELECT s.*, 'most-used' AS inclusion_reason
    FROM skills s
    JOIN review_stats rs ON rs.skill_id = s.id
      AND (rs.version_hash = s.version_hash OR (rs.version_hash IS NULL AND s.version_hash IS NULL))
    WHERE s.id IN (
        SELECT s2.id FROM skills_fts fts2
        JOIN skills s2 ON s2.rowid = fts2.rowid
        WHERE skills_fts MATCH ?
      )
      ${typeClause}
    ORDER BY (rs.review_count - rs.decline_count) DESC
    LIMIT ?
  `;

  // Rising: recent positive reviews (post-use with high rating)
  const risingQuery = `
    SELECT s.*, 'rising' AS inclusion_reason
    FROM skills s
    JOIN reviews r ON r.skill_id = s.id
    WHERE r.rating >= 4
      AND r.updated_at >= datetime('now', '-30 days')
      AND s.id IN (
        SELECT s2.id FROM skills_fts fts2
        JOIN skills s2 ON s2.rowid = fts2.rowid
        WHERE skills_fts MATCH ?
      )
      ${typeClause}
    GROUP BY s.id
    ORDER BY COUNT(*) DESC
    LIMIT ?
  `;

  // Run all queries in a batch
  const [relevant, rated, used, rising] = await env.DB.batch([
    env.DB.prepare(relevantQuery).bind(query, ...typeBinds, limit),
    env.DB.prepare(ratedQuery).bind(query, ...typeBinds, limit),
    env.DB.prepare(usedQuery).bind(query, ...typeBinds, limit),
    env.DB.prepare(risingQuery).bind(query, ...typeBinds, limit),
  ]);

  // Deduplicate: first occurrence wins (preserves the most useful inclusion_reason)
  const seen = new Set<string>();
  const allResults: Array<SkillRow & { inclusion_reason: string }> = [];
  for (const batch of [relevant, rated, used, rising]) {
    for (const row of batch.results as Array<SkillRow & { inclusion_reason: string }>) {
      if (!seen.has(row.id)) {
        seen.add(row.id);
        allResults.push(row);
      }
    }
  }

  // Enrich each result with review stats and version info
  const skillIds = allResults.map((r) => r.id);
  let statsMap: Map<string, ReviewStatsRow[]> = new Map();

  if (skillIds.length > 0) {
    const placeholders = skillIds.map(() => "?").join(",");
    const statsResult = await env.DB.prepare(
      `SELECT * FROM review_stats WHERE skill_id IN (${placeholders})`
    )
      .bind(...skillIds)
      .all<ReviewStatsRow>();

    for (const row of statsResult.results) {
      const existing = statsMap.get(row.skill_id) || [];
      existing.push(row);
      statsMap.set(row.skill_id, existing);
    }
  }

  const enriched = allResults.map((skill) => {
    const allStats = statsMap.get(skill.id) || [];
    const currentStats =
      allStats.find(
        (s) =>
          s.version_hash === skill.version_hash ||
          (s.version_hash === null && skill.version_hash === null)
      ) || null;

    return {
      id: skill.id,
      name: skill.name,
      description: skill.description,
      source: skill.source,
      source_url: skill.source_url,
      type: skill.install_type,
      version_hash: skill.version_hash,
      inclusion_reason: skill.inclusion_reason,
      reviews: buildReviewsSummary(currentStats),
      version_info: buildVersionInfo(skill, currentStats, allStats),
    };
  });

  return json({ results: enriched });
};

const getSkill: RouteHandler = async (_request, env, params) => {
  const skill = await env.DB.prepare("SELECT * FROM skills WHERE id = ?")
    .bind(params.id)
    .first<SkillRow>();

  if (!skill) {
    return json({ error: "Skill not found" }, 404);
  }

  // Get review stats for all versions of this skill
  const statsResult = await env.DB.prepare(
    "SELECT * FROM review_stats WHERE skill_id = ?"
  )
    .bind(params.id)
    .all<ReviewStatsRow>();

  const allStats = statsResult.results;
  const currentStats =
    allStats.find(
      (s) =>
        s.version_hash === skill.version_hash ||
        (s.version_hash === null && skill.version_hash === null)
    ) || null;

  return json({
    id: skill.id,
    name: skill.name,
    description: skill.description,
    source: skill.source,
    source_url: skill.source_url,
    type: skill.install_type,
    version_hash: skill.version_hash,
    metadata: JSON.parse(skill.metadata || "{}"),
    indexed_at: skill.indexed_at,
    reviews: buildReviewsSummary(currentStats),
    version_info: buildVersionInfo(skill, currentStats, allStats),
    review_stats_by_version: allStats.map((s) => ({
      version_hash: s.version_hash,
      ...buildReviewsSummary(s),
    })),
  });
};

const getSkillContent: RouteHandler = async (_request, env, params) => {
  const skill = await env.DB.prepare("SELECT id, name, content, source_url FROM skills WHERE id = ?")
    .bind(params.id)
    .first<{ id: string; name: string; content: string | null; source_url: string }>();

  if (!skill) {
    return json({ error: "Skill not found" }, 404);
  }

  if (!skill.content) {
    return json({
      error: "No inline content available",
      source_url: skill.source_url,
      hint: "Fetch content directly from source_url",
    }, 404);
  }

  return new Response(skill.content, {
    status: 200,
    headers: { "Content-Type": "text/markdown; charset=utf-8" },
  });
};

const getSkillReviews: RouteHandler = async (request, env, params) => {
  const url = new URL(request.url);
  const limit = Math.min(parseInt(url.searchParams.get("limit") || "20"), 50);
  const offset = parseInt(url.searchParams.get("offset") || "0");
  const versionFilter = url.searchParams.get("version");

  let query: string;
  let binds: unknown[];

  if (versionFilter) {
    query =
      "SELECT * FROM reviews WHERE skill_id = ? AND version_hash = ? ORDER BY updated_at DESC LIMIT ? OFFSET ?";
    binds = [params.id, versionFilter, limit, offset];
  } else {
    query =
      "SELECT * FROM reviews WHERE skill_id = ? ORDER BY updated_at DESC LIMIT ? OFFSET ?";
    binds = [params.id, limit, offset];
  }

  const reviews = await env.DB.prepare(query).bind(...binds).all();

  // Parse stages JSON for each review
  const parsed = reviews.results.map((r: Record<string, unknown>) => ({
    ...r,
    stages: JSON.parse(r.stages as string),
  }));

  return json({
    skill_id: params.id,
    count: parsed.length,
    reviews: parsed,
  });
};

const createReview: RouteHandler = async (request, env) => {
  const ip = getClientIp(request);

  // Rate limit: max 30 reviews per IP per hour
  const allowed = await checkRateLimit(env.DB, ip, "review", hourWindow, 30);
  if (!allowed) {
    return json({ error: "Review rate limit exceeded (max 30 per hour)" }, 429);
  }

  // Authenticate via Ed25519 signature
  const authResult = await authenticateReview(env.DB, request, ip);
  if (authResult instanceof Response) return authResult;
  const { auth, body } = authResult;

  const agentId = body.agent_id as string | undefined;
  // Accept both skill_id and extension_id (SKILL.md uses extension_id)
  const skillId = (body.skill_id || body.extension_id) as string | undefined;
  const versionHash = body.version_hash as string | undefined;
  const stageType = body.stage as string | undefined;
  const rating = body.rating as number | undefined;
  const qualityRating = body.quality_rating as number | undefined;
  const securityFlag = body.security_ok === false || body.security_flag === true;
  const model = (body.model as string | undefined) || null;

  if (!agentId || !skillId) {
    return json(
      { error: "agent_id and skill_id (or extension_id) are required" },
      400
    );
  }

  // Verify skill exists
  const skill = await env.DB.prepare("SELECT id FROM skills WHERE id = ?")
    .bind(skillId)
    .first();
  if (!skill) {
    return json({ error: "Skill not found" }, 404);
  }

  const reviewKey = `rv_${crypto.randomUUID().replace(/-/g, "").substring(0, 12)}`;

  // Build stage object from the flat body fields
  const stageObj: Record<string, unknown> = { type: stageType || "code_review" };
  const stageFields = [
    "security_ok",
    "quality_rating",
    "summary",
    "findings",
    "suggested_improvements",
    "worked",
    "what_worked",
    "what_didnt",
    "task_summary",
    "installed",
    "decline_reason",
    "decision",
  ];
  for (const field of stageFields) {
    if (body[field] !== undefined) {
      stageObj[field] = body[field];
    }
  }
  stageObj.added_at = new Date().toISOString();

  const stages = JSON.stringify([stageObj]);
  const effectiveRating = rating ?? qualityRating ?? null;

  await env.DB.prepare(`
    INSERT INTO reviews (review_key, agent_id, skill_id, version_hash, stages, rating, security_flag, trust_level, public_key, model)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `)
    .bind(
      reviewKey,
      agentId,
      skillId,
      versionHash || null,
      stages,
      effectiveRating,
      securityFlag ? 1 : 0,
      auth.trustLevel,
      auth.publicKey,
      model
    )
    .run();

  return json({ review_key: reviewKey, created: true, trust_level: auth.trustLevel, model }, 201);
};

const updateReview: RouteHandler = async (request, env, params) => {
  const ip = getClientIp(request);

  // Authenticate via Ed25519 signature
  const authResult = await authenticateReview(env.DB, request, ip);
  if (authResult instanceof Response) return authResult;
  const { body } = authResult;

  // Fetch existing review
  const existing = await env.DB.prepare(
    "SELECT * FROM reviews WHERE review_key = ?"
  )
    .bind(params.key)
    .first<{ stages: string; rating: number | null; security_flag: number }>();

  if (!existing) {
    return json({ error: "Review not found" }, 404);
  }

  let stages = JSON.parse(existing.stages) as unknown[];

  // Build new stage from flat body fields (SKILL.md sends stage type + fields at top level)
  const stageType = body.stage as string | undefined;
  if (stageType) {
    const stageObj: Record<string, unknown> = { type: stageType };
    const stageFields = [
      "security_ok",
      "quality_rating",
      "summary",
      "findings",
      "suggested_improvements",
      "worked",
      "what_worked",
      "what_didnt",
      "task_summary",
      "installed",
      "decline_reason",
      "decision",
      "rating",
    ];
    for (const field of stageFields) {
      if (body[field] !== undefined) {
        stageObj[field] = body[field];
      }
    }
    stageObj.added_at = new Date().toISOString();
    stages.push(stageObj);
  } else if (typeof body.stage === "object" && body.stage !== null) {
    // Also accept the original object format for backwards compat
    stages.push({
      ...(body.stage as Record<string, unknown>),
      added_at: new Date().toISOString(),
    });
  }

  const rating =
    body.rating !== undefined ? (body.rating as number) : existing.rating;
  const securityFlag =
    body.security_flag !== undefined
      ? body.security_flag
        ? 1
        : 0
      : body.security_ok === false
        ? 1
        : existing.security_flag;

  await env.DB.prepare(`
    UPDATE reviews
    SET stages = ?, rating = ?, security_flag = ?, updated_at = datetime('now')
    WHERE review_key = ?
  `)
    .bind(JSON.stringify(stages), rating, securityFlag, params.key)
    .run();

  return json({ review_key: params.key, stages_count: stages.length });
};

// --- Route table ---

const routes: Array<{
  method: string;
  pattern: string;
  handler: RouteHandler;
}> = [
  { method: "POST", pattern: "/auth/github/device", handler: githubDeviceCode },
  { method: "POST", pattern: "/auth/github/token", handler: githubToken },
  { method: "POST", pattern: "/auth/link-github", handler: linkGithub },
  { method: "GET", pattern: "/search", handler: searchSkills },
  { method: "GET", pattern: "/skills/:id", handler: getSkill },
  { method: "GET", pattern: "/skills/:id/content", handler: getSkillContent },
  { method: "GET", pattern: "/skills/:id/reviews", handler: getSkillReviews },
  { method: "POST", pattern: "/reviews", handler: createReview },
  { method: "PATCH", pattern: "/reviews/:key", handler: updateReview },
];

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const query = Object.fromEntries(url.searchParams.entries());

    // Admin endpoints require X-Admin-Secret header
    if (url.pathname.startsWith("/admin/")) {
      if (request.headers.get("x-admin-secret") !== env.ADMIN_SECRET) {
        return json({ error: "Forbidden" }, 403);
      }
    }

    // Admin: recent requests log
    if (url.pathname === "/admin/recent-requests") {
      const limit = Math.min(
        parseInt(url.searchParams.get("limit") || "50"),
        MAX_LOG_ENTRIES
      );
      const method = url.searchParams.get("method");
      const path = url.searchParams.get("path");

      let entries = [...requestLog].reverse();
      if (method) entries = entries.filter((e) => e.method === method.toUpperCase());
      if (path) entries = entries.filter((e) => e.path.includes(path));

      return json({
        count: entries.slice(0, limit).length,
        total: entries.length,
        requests: entries.slice(0, limit),
      });
    }

    // Admin: clear request log
    if (url.pathname === "/admin/clear-requests" && request.method === "POST") {
      requestLog.length = 0;
      return json({ cleared: true });
    }

    // Admin: seed database (drop + recreate + seed)
    if (url.pathname === "/admin/seed" && request.method === "POST") {
      try {
        // Drop existing tables/views/triggers in reverse dependency order
        await env.DB.exec("DROP VIEW IF EXISTS review_stats");
        await env.DB.exec("DROP TRIGGER IF EXISTS skills_ai");
        await env.DB.exec("DROP TRIGGER IF EXISTS skills_ad");
        await env.DB.exec("DROP TRIGGER IF EXISTS skills_au");
        await env.DB.exec("DROP TABLE IF EXISTS skills_fts");
        await env.DB.exec("DROP TABLE IF EXISTS reviews");
        await env.DB.exec("DROP TABLE IF EXISTS skills");
        await env.DB.exec("DROP TABLE IF EXISTS identities");
        await env.DB.exec("DROP TABLE IF EXISTS rate_limits");

        // Apply schema and seed
        const allSQL = schemaSQL + "\n" + seedSQL;
        const stmts = splitStatements(allSQL);
        for (const stmt of stmts) {
          await env.DB.prepare(stmt).run();
        }

        // Clear request log too for a clean test slate
        requestLog.length = 0;

        return json({
          seeded: true,
          statements: stmts.length,
        });
      } catch (err) {
        console.error(err);
        return json({ seeded: false, error: "Internal server error" }, 500);
      }
    }

    const match = matchRoute(request.method, url.pathname, routes);

    if (match) {
      try {
        const response = await match.handler(request, env, match.params);
        logRequest(request.method, url.pathname, query, response.status);
        return response;
      } catch (err) {
        logRequest(request.method, url.pathname, query, 500);
        console.error(err);
        return json({ error: "Internal server error" }, 500);
      }
    }

    // Health check
    if (url.pathname === "/" || url.pathname === "/health") {
      return json({ status: "ok", service: "clarmory-api" });
    }

    logRequest(request.method, url.pathname, query, 404);
    return json({ error: "Not found" }, 404);
  },
};
