import {
  env,
  createExecutionContext,
  waitOnExecutionContext,
} from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import worker from "./index";

// Read schema + seed SQL and apply to the test D1 instance
import schemaSQL from "../schema.sql";
import seedSQL from "../scripts/seed.sql";

async function callWorker(
  path: string,
  init?: RequestInit
): Promise<Response> {
  const request = new Request(`http://localhost${path}`, init);
  const ctx = createExecutionContext();
  const response = await worker.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

async function jsonResponse<T = unknown>(
  path: string,
  init?: RequestInit
): Promise<{ status: number; body: T }> {
  const response = await callWorker(path, init);
  const body = (await response.json()) as T;
  return { status: response.status, body };
}

// Split SQL into individual statements for D1 batch execution.
// Handles comments, string literals, and BEGIN...END trigger blocks.
function splitStatements(sql: string): string[] {
  const statements: string[] = [];
  let current = "";
  let inString = false;
  let beginDepth = 0;

  for (let i = 0; i < sql.length; i++) {
    const ch = sql[i];

    if (ch === "'" && !inString) {
      inString = true;
      current += ch;
      continue;
    }
    if (ch === "'" && inString) {
      current += ch;
      if (sql[i + 1] === "'") {
        current += "'";
        i++;
      } else {
        inString = false;
      }
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
      if (upper.startsWith("BEGIN") && /\s/.test(sql[i + 5] || "")) {
        beginDepth++;
      }
      const endStr = sql.substring(i, i + 4).toUpperCase();
      if (endStr === "END" && beginDepth > 0 && /[\s;]/.test(sql[i + 3] || "")) {
        beginDepth--;
      }
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

beforeAll(async () => {
  const allSQL = schemaSQL + "\n" + seedSQL;
  const stmts = splitStatements(allSQL);
  for (const stmt of stmts) {
    await env.DB.prepare(stmt).run();
  }
});

// --- Types matching the SKILL.md contract ---

interface SearchResult {
  id: string;
  name: string;
  description: string;
  source: string;
  source_url: string;
  type: string;
  version_hash: string | null;
  inclusion_reason: string;
  reviews: {
    total: number;
    code_reviews: number;
    installs: number;
    declines: number;
    post_use: number;
    avg_rating: number | null;
    security_flags: number;
  };
  version_info: {
    current_hash: string | null;
    previous_hash: string | null;
    reviews_for_current: number;
    is_new_version: boolean;
    version_uncertain: boolean;
  };
}

interface SkillDetail {
  id: string;
  name: string;
  description: string;
  source: string;
  source_url: string;
  type: string;
  version_hash: string | null;
  metadata: Record<string, unknown>;
  indexed_at: string;
  reviews: SearchResult["reviews"];
  version_info: SearchResult["version_info"];
  review_stats_by_version: Array<
    SearchResult["reviews"] & { version_hash: string | null }
  >;
}

// --- Health ---

describe("health", () => {
  it("GET / returns ok", async () => {
    const { status, body } = await jsonResponse<{ status: string }>("/");
    expect(status).toBe(200);
    expect(body.status).toBe("ok");
  });

  it("GET /health returns ok", async () => {
    const { status, body } = await jsonResponse<{ status: string }>("/health");
    expect(status).toBe(200);
    expect(body.status).toBe("ok");
  });
});

// --- Search ---

describe("GET /search", () => {
  it("returns 400 without query", async () => {
    const { status } = await jsonResponse("/search");
    expect(status).toBe(400);
  });

  it("returns 400 with empty query", async () => {
    const { status } = await jsonResponse("/search?q=");
    expect(status).toBe(400);
  });

  it("finds skills by keyword", async () => {
    const { status, body } = await jsonResponse<{ results: SearchResult[] }>(
      "/search?q=security"
    );
    expect(status).toBe(200);
    expect(body.results.length).toBeGreaterThan(0);
    expect(body.results.some((r) => r.name.includes("Security"))).toBe(true);
  });

  it("returns results with inclusion_reason", async () => {
    const { body } = await jsonResponse<{ results: SearchResult[] }>(
      "/search?q=security"
    );
    for (const result of body.results) {
      expect(["most-relevant", "highest-rated", "most-used", "rising"]).toContain(
        result.inclusion_reason
      );
    }
  });

  it("returns results with reviews and version_info objects", async () => {
    const { body } = await jsonResponse<{ results: SearchResult[] }>(
      "/search?q=security"
    );
    const result = body.results[0];
    expect(result.reviews).toBeDefined();
    expect(result.reviews).toHaveProperty("total");
    expect(result.reviews).toHaveProperty("code_reviews");
    expect(result.reviews).toHaveProperty("security_flags");
    expect(result.version_info).toBeDefined();
    expect(result.version_info).toHaveProperty("current_hash");
    expect(result.version_info).toHaveProperty("version_uncertain");
  });

  it("respects limit parameter (per dimension)", async () => {
    // limit=1 means 1 per ranking dimension, but deduplication may reduce total
    const { body: small } = await jsonResponse<{ results: SearchResult[] }>(
      "/search?q=mcp&limit=1"
    );
    const { body: large } = await jsonResponse<{ results: SearchResult[] }>(
      "/search?q=mcp&limit=10"
    );
    // Smaller limit should return <= larger limit results
    expect(small.results.length).toBeLessThanOrEqual(large.results.length);
  });

  it("marks version_uncertain for null version_hash skills", async () => {
    const { body } = await jsonResponse<{ results: SearchResult[] }>(
      "/search?q=claude+code+mcp"
    );
    const claudeMcp = body.results.find((r) =>
      r.id.includes("claude-code-mcp")
    );
    if (claudeMcp) {
      expect(claudeMcp.version_info.version_uncertain).toBe(true);
    }
  });
});

// --- Get Skill ---

describe("GET /skills/:id", () => {
  it("returns skill with SKILL.md contract shape", async () => {
    const { status, body } = await jsonResponse<SkillDetail>(
      `/skills/${encodeURIComponent("github:trailofbits/skills/security-audit")}`
    );
    expect(status).toBe(200);
    expect(body.name).toBe("Trail of Bits Security Audit");
    expect(body.source).toBe("github");
    expect(body.type).toBe("skill");
    expect(body.reviews).toBeDefined();
    expect(body.version_info).toBeDefined();
    expect(body.review_stats_by_version).toBeInstanceOf(Array);
    expect(body.metadata).toBeDefined();
  });

  it("returns 404 for unknown skill", async () => {
    const { status } = await jsonResponse(
      `/skills/${encodeURIComponent("github:nonexistent/skill")}`
    );
    expect(status).toBe(404);
  });
});

// --- Get Skill Content ---

describe("GET /skills/:id/content", () => {
  it("returns markdown content for skill with inline content", async () => {
    const response = await callWorker(
      `/skills/${encodeURIComponent("github:claudecode-contrib/mqtt-client-skill")}/content`
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/markdown");
    const text = await response.text();
    expect(text).toContain("# MQTT Client Skill");
    expect(text).toContain("mqtt");
  });

  it("returns 404 with source_url hint for skill without inline content", async () => {
    const { status, body } = await jsonResponse<{
      error: string;
      source_url: string;
      hint: string;
    }>(
      `/skills/${encodeURIComponent("github:trailofbits/skills/security-audit")}/content`
    );
    expect(status).toBe(404);
    expect(body.error).toContain("No inline content");
    expect(body.source_url).toBeDefined();
    expect(body.hint).toBeDefined();
  });

  it("returns 404 for nonexistent skill", async () => {
    const { status } = await jsonResponse(
      `/skills/${encodeURIComponent("github:nonexistent/skill")}/content`
    );
    expect(status).toBe(404);
  });
});

// --- Get Skill Reviews ---

describe("GET /skills/:id/reviews", () => {
  it("returns empty reviews for skill with none", async () => {
    // Understand Anything has no seeded reviews
    const { status, body } = await jsonResponse<{
      count: number;
      reviews: unknown[];
    }>(
      `/skills/${encodeURIComponent("github:Lum1104/Understand-Anything")}/reviews`
    );
    expect(status).toBe(200);
    expect(body.count).toBe(0);
    expect(body.reviews).toEqual([]);
  });

  it("returns seeded reviews for reviewed skills", async () => {
    const { status, body } = await jsonResponse<{
      count: number;
      reviews: Array<{ review_key: string; stages: unknown[] }>;
    }>(
      `/skills/${encodeURIComponent("github:trailofbits/skills/security-audit")}/reviews`
    );
    expect(status).toBe(200);
    expect(body.count).toBeGreaterThanOrEqual(2);
    // Stages should be parsed arrays, not strings
    expect(Array.isArray(body.reviews[0].stages)).toBe(true);
  });
});

// --- Create Review (SKILL.md contract) ---

describe("POST /reviews", () => {
  it("returns 400 without required fields", async () => {
    const { status } = await jsonResponse("/reviews", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(status).toBe(400);
  });

  it("returns 404 for nonexistent skill", async () => {
    const { status } = await jsonResponse("/reviews", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        agent_id: "test-agent",
        skill_id: "github:nonexistent/skill",
      }),
    });
    expect(status).toBe(404);
  });

  it("accepts extension_id as alias for skill_id", async () => {
    const { status, body } = await jsonResponse<{
      review_key: string;
      created: boolean;
    }>("/reviews", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        agent_id: "test-agent-alias",
        extension_id: "github:trailofbits/skills/security-audit",
        version_hash: "a1b2c3d4",
        stage: "code_review",
        security_ok: true,
        quality_rating: 4,
        summary: "Clean security skill",
        findings: "Well-structured audit workflow",
      }),
    });
    expect(status).toBe(201);
    expect(body.review_key).toMatch(/^rv_/);
    expect(body.created).toBe(true);
  });

  it("creates a review with object stage format (backwards compat)", async () => {
    const { status, body } = await jsonResponse<{ review_key: string }>(
      "/reviews",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          agent_id: "test-agent-1",
          skill_id: "github:trailofbits/skills/security-audit",
          version_hash: "a1b2c3d4",
          stage: { type: "code_review", quality: "good", issues: [] },
          rating: 4,
        }),
      }
    );
    expect(status).toBe(201);
    expect(body.review_key).toBeDefined();
  });

  it("creates a review with security flag via security_ok=false", async () => {
    const { status, body } = await jsonResponse<{ review_key: string }>(
      "/reviews",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          agent_id: "test-agent-security",
          skill_id: "github:trailofbits/skills/security-audit",
          version_hash: "a1b2c3d4",
          stage: "code_review",
          security_ok: false,
          summary: "Found credential exfiltration",
        }),
      }
    );
    expect(status).toBe(201);
    expect(body.review_key).toBeDefined();
  });
});

// --- Update Review (SKILL.md contract) ---

describe("PATCH /reviews/:key", () => {
  let reviewKey: string;

  beforeAll(async () => {
    const { body } = await jsonResponse<{ review_key: string }>("/reviews", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        agent_id: "test-agent-patch",
        skill_id: "github:OthmanAdi/planning-with-files",
        version_hash: "e5f6a7b8",
        stage: "code_review",
        quality_rating: 4,
        summary: "Good planning skill",
      }),
    });
    reviewKey = body.review_key;
  });

  it("returns 404 for unknown review key", async () => {
    const { status } = await jsonResponse("/reviews/nonexistent-key", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ rating: 5 }),
    });
    expect(status).toBe(404);
  });

  it("appends user_decision stage (SKILL.md format)", async () => {
    const { status, body } = await jsonResponse<{
      review_key: string;
      stages_count: number;
    }>(`/reviews/${reviewKey}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        stage: "user_decision",
        installed: true,
      }),
    });
    expect(status).toBe(200);
    expect(body.stages_count).toBe(2);
  });

  it("appends post_use stage with rating (SKILL.md format)", async () => {
    const { status, body } = await jsonResponse<{
      review_key: string;
      stages_count: number;
    }>(`/reviews/${reviewKey}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        stage: "post_use",
        worked: true,
        rating: 5,
        task_summary: "Used for project planning",
        what_worked: "Great structure",
        what_didnt: "Nothing",
        suggested_improvements: "Add Gantt chart support",
      }),
    });
    expect(status).toBe(200);
    expect(body.stages_count).toBe(3);
  });

  it("appends stage with object format (backwards compat)", async () => {
    const { status, body } = await jsonResponse<{
      review_key: string;
      stages_count: number;
    }>(`/reviews/${reviewKey}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        stage: { type: "note", text: "Additional observation" },
      }),
    });
    expect(status).toBe(200);
    expect(body.stages_count).toBe(4);
  });
});

// --- Review Stats integration ---

describe("review stats", () => {
  it("search results include review stats after reviews are created", async () => {
    const { body } = await jsonResponse<{ results: SearchResult[] }>(
      "/search?q=security+audit"
    );
    const skill = body.results.find(
      (r) => r.id === "github:trailofbits/skills/security-audit"
    );
    expect(skill).toBeDefined();
    expect(skill!.reviews.total).toBeGreaterThanOrEqual(2);
    expect(skill!.reviews.security_flags).toBeGreaterThanOrEqual(1);
  });

  it("skill detail includes review stats", async () => {
    const { body } = await jsonResponse<SkillDetail>(
      `/skills/${encodeURIComponent("github:trailofbits/skills/security-audit")}`
    );
    expect(body.reviews.total).toBeGreaterThanOrEqual(2);
    expect(body.review_stats_by_version.length).toBeGreaterThan(0);
  });

  it("skill reviews endpoint returns created reviews", async () => {
    const { body } = await jsonResponse<{
      count: number;
      reviews: Array<{ agent_id: string; stages: unknown[] }>;
    }>(
      `/skills/${encodeURIComponent("github:trailofbits/skills/security-audit")}/reviews`
    );
    expect(body.count).toBeGreaterThanOrEqual(2);
    // Verify stages are parsed (not raw JSON string)
    expect(Array.isArray(body.reviews[0].stages)).toBe(true);
  });

  it("decline_count includes installed:false reviews (SKILL.md format)", async () => {
    // Create a review with a decline using installed:false (SKILL.md format)
    const { body: createBody } = await jsonResponse<{ review_key: string }>(
      "/reviews",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          agent_id: "test-agent-decline",
          skill_id: "github:Lum1104/Understand-Anything",
          version_hash: "c9d0e1f2",
          stage: "code_review",
          quality_rating: 3,
          summary: "Decent but not what I need",
        }),
      }
    );
    // Append a decline using installed:false
    await jsonResponse(`/reviews/${createBody.review_key}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        stage: "user_decision",
        installed: false,
        decline_reason: "User preferred a different approach",
      }),
    });
    // Check that the skill's review stats reflect the decline
    const { body } = await jsonResponse<SkillDetail>(
      `/skills/${encodeURIComponent("github:Lum1104/Understand-Anything")}`
    );
    expect(body.reviews.declines).toBeGreaterThanOrEqual(1);
  });

  it("skill reviews can be filtered by version", async () => {
    const { body } = await jsonResponse<{
      count: number;
      reviews: unknown[];
    }>(
      `/skills/${encodeURIComponent("github:trailofbits/skills/security-audit")}/reviews?version=a1b2c3d4`
    );
    expect(body.count).toBeGreaterThanOrEqual(2);
  });
});

// --- Admin: request log ---

describe("GET /admin/recent-requests", () => {
  it("returns logged requests", async () => {
    // Make a request that gets logged
    await callWorker("/search?q=security");

    const { status, body } = await jsonResponse<{
      count: number;
      total: number;
      requests: Array<{
        method: string;
        path: string;
        query: Record<string, string>;
        timestamp: string;
        status: number;
      }>;
    }>("/admin/recent-requests");

    expect(status).toBe(200);
    expect(body.count).toBeGreaterThan(0);
    const searchReq = body.requests.find(
      (r) => r.path === "/search" && r.query.q === "security"
    );
    expect(searchReq).toBeDefined();
    expect(searchReq!.method).toBe("GET");
    expect(searchReq!.status).toBe(200);
    expect(searchReq!.timestamp).toBeDefined();
  });

  it("supports method and path filters", async () => {
    const { body } = await jsonResponse<{
      count: number;
      requests: Array<{ method: string; path: string }>;
    }>("/admin/recent-requests?method=GET&path=/search");

    for (const req of body.requests) {
      expect(req.method).toBe("GET");
      expect(req.path).toContain("/search");
    }
  });

  it("clears the log", async () => {
    await callWorker("/admin/clear-requests", { method: "POST" });
    const { body } = await jsonResponse<{ count: number }>(
      "/admin/recent-requests"
    );
    expect(body.count).toBe(0);
  });
});

// --- Admin: seed database ---

describe("POST /admin/seed", () => {
  it("reseeds the database and returns success", async () => {
    const { status, body } = await jsonResponse<{
      seeded: boolean;
      statements: number;
    }>("/admin/seed", { method: "POST" });

    expect(status).toBe(200);
    expect(body.seeded).toBe(true);
    expect(body.statements).toBeGreaterThan(0);

    // Verify data is present after reseed
    const { body: searchBody } = await jsonResponse<{
      results: Array<{ id: string }>;
    }>("/search?q=mqtt");
    expect(searchBody.results.length).toBeGreaterThan(0);
  });
});

// --- 404 ---

describe("unknown routes", () => {
  it("returns 404 for unknown paths", async () => {
    const { status } = await jsonResponse("/nonexistent");
    expect(status).toBe(404);
  });
});
