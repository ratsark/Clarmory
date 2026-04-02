-- Seed data: 11 hand-curated skills covering varied types
-- Types: skill (SKILL.md), mcp-local (locally-run MCP server), mcp-hosted (remote MCP)
--
-- Includes sample reviews with all three stages (code_review, user_decision,
-- post_use) across different skills to exercise review aggregation.
--
-- The MQTT skill is the designated e2e test target — it should be the clear
-- best match for "MQTT client subscribe topic log messages".

-- =============================================================================
-- Skills
-- =============================================================================

-- E2E test target: MQTT skill with inline content (agent fetches via GET /skills/:id/content)
INSERT OR REPLACE INTO skills (id, source, name, description, version_hash, source_url, install_type, content, tags, metadata) VALUES
('github:claudecode-contrib/mqtt-client-skill',
 'awesome-claude-code', 'MQTT Client',
 'MQTT publish/subscribe skill for IoT projects. Sets up an MQTT client that connects to a broker, subscribes to topics, publishes messages, and logs incoming data. Handles reconnection, QoS levels, and topic wildcards. Works with Mosquitto, HiveMQ, EMQX, and other standard brokers.',
 'f1e2d3c4', 'https://api.clarmory.com/skills/github%3Aclaudecode-contrib%2Fmqtt-client-skill/content', 'skill',
 '# MQTT Client Skill

## What this skill does

Sets up MQTT publish/subscribe clients for IoT and messaging projects. Handles
broker connection, topic subscription, message publishing, and incoming message
logging.

## When to use

- Setting up MQTT communication in IoT projects
- Subscribing to topics and logging messages from sensors or devices
- Publishing messages to MQTT brokers
- Any project needing pub/sub messaging via MQTT

## Instructions

### Dependencies

Install the MQTT client library for your language:

**Node.js / TypeScript:**
```bash
npm install mqtt
```

**Python:**
```bash
pip install paho-mqtt
```

### Connecting to a broker

Connect to the MQTT broker. Default port is 1883 (unencrypted) or 8883 (TLS).

**Node.js:**
```javascript
const mqtt = require("mqtt");
const client = mqtt.connect("mqtt://localhost:1883");

client.on("connect", () => {
  console.log("Connected to MQTT broker");
});

client.on("error", (err) => {
  console.error("Connection error:", err.message);
});
```

**Python:**
```python
import paho.mqtt.client as mqtt

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print("Connected to MQTT broker")
    else:
        print(f"Connection failed with code {rc}")

client = mqtt.Client()
client.on_connect = on_connect
client.connect("localhost", 1883, 60)
```

### Subscribing to topics

Subscribe to one or more topics. Use wildcards for flexible matching:
- `+` matches a single level: `sensors/+/temperature`
- `#` matches multiple levels: `sensors/#`

**Node.js:**
```javascript
client.subscribe("sensors/#", { qos: 1 }, (err) => {
  if (err) console.error("Subscribe error:", err);
});

client.on("message", (topic, message) => {
  console.log(`[${topic}] ${message.toString()}`);
});
```

**Python:**
```python
def on_message(client, userdata, msg):
    print(f"[{msg.topic}] {msg.payload.decode()}")

client.on_message = on_message
client.subscribe("sensors/#", qos=1)
client.loop_forever()
```

### Publishing messages

```javascript
client.publish("sensors/temperature", JSON.stringify({ value: 22.5, unit: "C" }), { qos: 1 });
```

### QoS levels

- **QoS 0**: At most once (fire and forget)
- **QoS 1**: At least once (acknowledged delivery)
- **QoS 2**: Exactly once (four-part handshake)

Use QoS 1 for most cases. QoS 2 is slower but guarantees no duplicates.

### Reconnection

Most MQTT libraries handle reconnection automatically. Configure reconnect
options for reliability:

```javascript
const client = mqtt.connect("mqtt://localhost:1883", {
  reconnectPeriod: 5000,
  connectTimeout: 30000,
});
```

### Broker compatibility

Works with any MQTT 3.1.1 or 5.0 broker:
- **Mosquitto** (local, lightweight)
- **HiveMQ** (cloud or self-hosted)
- **EMQX** (high-performance, clustered)
- **AWS IoT Core** (managed, requires TLS + certs)

### Common patterns

**Message logger:**
```javascript
const fs = require("fs");
client.on("message", (topic, message) => {
  const entry = `${new Date().toISOString()} [${topic}] ${message.toString()}\n`;
  fs.appendFileSync("mqtt_log.txt", entry);
  console.log(entry.trim());
});
```

**Structured sensor data:**
```javascript
client.on("message", (topic, message) => {
  try {
    const data = JSON.parse(message.toString());
    console.log(`Sensor ${topic}: ${data.value}${data.unit}`);
  } catch {
    console.log(`Raw message on ${topic}: ${message.toString()}`);
  }
});
```
',
 'mqtt iot messaging pubsub subscribe broker',
 '{"tags": ["mqtt", "iot", "messaging", "pubsub", "subscribe", "broker"], "author": "claudecode-contrib"}');

-- Remaining skills (no inline content — fetched from upstream source_url)
INSERT OR REPLACE INTO skills (id, source, name, description, version_hash, source_url, install_type, tags, metadata) VALUES

-- Skills (SKILL.md files)
('github:trailofbits/skills/security-audit',
 'github', 'Trail of Bits Security Audit',
 'Security-focused code auditing skill from Trail of Bits. Performs systematic vulnerability analysis including injection flaws, auth issues, cryptographic weaknesses, and dependency risks. Produces structured findings with severity ratings.',
 'a1b2c3d4', 'https://github.com/trailofbits/skills', 'skill',
 'security audit vulnerability code-review',
 '{"tags": ["security", "audit", "vulnerability"], "author": "Trail of Bits"}'),

('github:OthmanAdi/planning-with-files',
 'github', 'Planning with Files',
 'Manus-style persistent markdown planning skill. Maintains a structured plan file that evolves as the agent works, tracking phases, decisions, and progress. Prevents scope drift and provides continuity across sessions.',
 'e5f6a7b8', 'https://github.com/OthmanAdi/planning-with-files', 'skill',
 'planning workflow project-management',
 '{"tags": ["planning", "workflow", "project-management"], "author": "OthmanAdi"}'),

('github:Lum1104/Understand-Anything',
 'github', 'Understand Anything',
 'Turns any codebase into an interactive knowledge graph. Indexes code structure, dependencies, and relationships, then enables natural language exploration and search. Useful for onboarding to unfamiliar projects.',
 'c9d0e1f2', 'https://github.com/Lum1104/Understand-Anything', 'skill',
 'code-analysis knowledge-graph onboarding',
 '{"tags": ["code-analysis", "knowledge-graph", "onboarding"], "author": "Lum1104"}'),

('github:FlineDev/ContextKit',
 'github', 'ContextKit',
 'Proactive development partner with 4-phase planning: understand, plan, implement, verify. Generates rich project context including dependency maps, API surfaces, and test coverage analysis before making changes.',
 'a3b4c5d6', 'https://github.com/FlineDev/ContextKit', 'skill',
 'planning context development-workflow',
 '{"tags": ["planning", "context", "development-workflow"], "author": "FlineDev"}'),

('github:akin-ozer/cc-devops-skills',
 'github', 'DevOps Skills',
 'Infrastructure-as-code generation skills for Terraform, Kubernetes, Docker, and CI/CD pipelines. Handles cloud provisioning, container orchestration, and deployment automation with best-practice templates.',
 'f7e8d9c0', 'https://github.com/akin-ozer/cc-devops-skills', 'skill',
 'devops terraform kubernetes docker ci-cd infrastructure',
 '{"tags": ["devops", "terraform", "kubernetes", "docker", "ci-cd"], "author": "akin-ozer"}'),

-- Local MCP servers (run on user's machine)
('github:modelcontextprotocol/servers/filesystem',
 'mcp-registry', 'MCP Filesystem Server',
 'Reference MCP server providing sandboxed filesystem access. Allows agents to read, write, search, and manage files within configured directories. Supports glob patterns, file metadata, and directory listing.',
 'b1c2d3e4', 'https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem', 'mcp-local',
 'filesystem mcp reference file-access',
 '{"tags": ["filesystem", "mcp", "reference"], "author": "Anthropic", "runtime": "node"}'),

('github:modelcontextprotocol/servers/postgres',
 'mcp-registry', 'MCP PostgreSQL Server',
 'MCP server for PostgreSQL database interaction. Provides read-only SQL query execution, schema introspection, table listing, and query explanation. Connects to any PostgreSQL instance via connection string.',
 'd5e6f7a8', 'https://github.com/modelcontextprotocol/servers/tree/main/src/postgres', 'mcp-local',
 'database postgresql sql mcp',
 '{"tags": ["database", "postgresql", "sql", "mcp"], "author": "Anthropic", "runtime": "node"}'),

('github:upstash/context7-mcp',
 'mcp-registry', 'Context7 MCP',
 'Retrieves up-to-date, version-specific documentation and code examples for libraries and frameworks directly from source. Replaces stale training data with live docs. Supports thousands of libraries.',
 'e9f0a1b2', 'https://github.com/upstash/context7-mcp', 'mcp-hosted',
 'documentation libraries mcp context',
 '{"tags": ["documentation", "libraries", "mcp", "context"], "author": "Upstash", "runtime": "remote"}'),

-- Hosted MCP servers (remote, opaque version)
('github:anthropics/claude-code-mcp',
 'mcp-registry', 'Claude Code as MCP Server',
 'Runs Claude Code itself as an MCP server, enabling other AI tools and agents to leverage Claude Code capabilities. Provides tools for code analysis, editing, and bash execution through the MCP protocol.',
 NULL, 'https://github.com/anthropics/claude-code', 'mcp-local',
 'meta mcp agent-orchestration',
 '{"tags": ["meta", "mcp", "agent-orchestration"], "author": "Anthropic", "runtime": "node", "version_opaque": true}'),

('github:K-Dense-AI/claude-scientific-skills',
 'github', 'Scientific Research Skills',
 'Collection of skills for scientific workflows: literature review, experimental design, data analysis, statistical testing, and paper writing. Includes domain-specific templates for biology, chemistry, physics, and engineering.',
 'c3d4e5f6', 'https://github.com/K-Dense-AI/claude-scientific-skills', 'skill',
 'science research data-analysis academic',
 '{"tags": ["science", "research", "data-analysis", "academic"], "author": "K-Dense-AI"}');

-- =============================================================================
-- Sample Reviews
-- =============================================================================
-- Reviews with all three stages to exercise review_stats aggregation.
-- Stage JSON uses "type" field matching the review_stats view queries.

-- --- MQTT Client: 3 reviews (all stages, high ratings — the e2e test target) ---

-- Review 1: Full lifecycle (code_review + user_decision:installed + post_use)
INSERT OR REPLACE INTO reviews (review_key, agent_id, skill_id, version_hash, stages, rating, security_flag) VALUES
('rv_mqtt_001', 'agent-seed-alpha', 'github:claudecode-contrib/mqtt-client-skill', 'f1e2d3c4',
 '[{"type": "code_review", "security_ok": true, "quality_rating": 5, "summary": "Excellent MQTT skill. Clean pub/sub implementation, handles QoS correctly.", "findings": "Well-structured, good error handling for broker disconnects.", "suggested_improvements": "Could add TLS/SSL connection support."},
   {"type": "user_decision", "decision": "installed", "installed": true},
   {"type": "post_use", "worked": true, "rating": 5, "task_summary": "Set up MQTT subscriber for temperature sensor data in a home automation project.", "what_worked": "Connection and subscription were straightforward. Topic wildcards worked as documented.", "what_didnt": "Nothing major.", "suggested_improvements": "Add TLS support for production brokers."}]',
 5, 0);

-- Review 2: Full lifecycle with slightly lower rating
INSERT OR REPLACE INTO reviews (review_key, agent_id, skill_id, version_hash, stages, rating, security_flag) VALUES
('rv_mqtt_002', 'agent-seed-beta', 'github:claudecode-contrib/mqtt-client-skill', 'f1e2d3c4',
 '[{"type": "code_review", "security_ok": true, "quality_rating": 4, "summary": "Good MQTT skill, covers the basics well.", "findings": "Solid implementation. Documentation could be more detailed on QoS levels.", "suggested_improvements": "Expand QoS documentation with examples."},
   {"type": "user_decision", "decision": "installed", "installed": true},
   {"type": "post_use", "worked": true, "rating": 4, "task_summary": "Built an MQTT message logger for IoT device monitoring.", "what_worked": "Quick setup, reliable message delivery.", "what_didnt": "Had to figure out wildcard syntax on my own.", "suggested_improvements": "Add wildcard subscription examples to docs."}]',
 4, 0);

-- Review 3: Code review only (no install — agent chose a different approach)
INSERT OR REPLACE INTO reviews (review_key, agent_id, skill_id, version_hash, stages, rating, security_flag) VALUES
('rv_mqtt_003', 'agent-seed-gamma', 'github:claudecode-contrib/mqtt-client-skill', 'f1e2d3c4',
 '[{"type": "code_review", "security_ok": true, "quality_rating": 4, "summary": "Well-written MQTT skill. No security concerns.", "findings": "Clean code, appropriate scope.", "suggested_improvements": "Consider adding MQTT v5 support."}]',
 NULL, 0);

-- --- Trail of Bits Security Audit: 2 reviews (mixed stages) ---

-- Review 1: Full lifecycle
INSERT OR REPLACE INTO reviews (review_key, agent_id, skill_id, version_hash, stages, rating, security_flag) VALUES
('rv_sec_001', 'agent-seed-alpha', 'github:trailofbits/skills/security-audit', 'a1b2c3d4',
 '[{"type": "code_review", "security_ok": true, "quality_rating": 5, "summary": "Professional-grade security audit skill from a reputable source.", "findings": "Comprehensive vulnerability categories, structured output format.", "suggested_improvements": "Add OWASP top 10 checklist as optional structured output."},
   {"type": "user_decision", "decision": "installed", "installed": true},
   {"type": "post_use", "worked": true, "rating": 5, "task_summary": "Audited a REST API for injection and auth vulnerabilities.", "what_worked": "Found 3 real injection vectors and a broken auth check. Severity ratings were accurate.", "what_didnt": "Slow on large codebases (>50k LOC).", "suggested_improvements": "Add incremental scan mode for large projects."}]',
 5, 0);

-- Review 2: Code review + decline
INSERT OR REPLACE INTO reviews (review_key, agent_id, skill_id, version_hash, stages, rating, security_flag) VALUES
('rv_sec_002', 'agent-seed-delta', 'github:trailofbits/skills/security-audit', 'a1b2c3d4',
 '[{"type": "code_review", "security_ok": true, "quality_rating": 4, "summary": "Good skill but heavier than what was needed.", "findings": "Thorough but includes dependency scanning which was out of scope.", "suggested_improvements": "Allow selecting which audit categories to run."},
   {"type": "user_decision", "decision": "declined", "installed": false, "decline_reason": "User only needed a quick check, not a full audit. Used a lighter approach instead."}]',
 NULL, 0);

-- --- Planning with Files: 1 review (full lifecycle, moderate rating) ---

INSERT OR REPLACE INTO reviews (review_key, agent_id, skill_id, version_hash, stages, rating, security_flag) VALUES
('rv_plan_001', 'agent-seed-beta', 'github:OthmanAdi/planning-with-files', 'e5f6a7b8',
 '[{"type": "code_review", "security_ok": true, "quality_rating": 3, "summary": "Useful planning skill but could be more structured.", "findings": "Creates markdown plans but format is loosely defined. No validation of plan structure.", "suggested_improvements": "Define a stricter plan schema with required sections."},
   {"type": "user_decision", "decision": "installed", "installed": true},
   {"type": "post_use", "worked": true, "rating": 3, "task_summary": "Used for planning a database migration across 3 phases.", "what_worked": "Kept track of what was done vs pending. Good for continuity across sessions.", "what_didnt": "Plan format drifted over time — no enforcement of structure.", "suggested_improvements": "Add plan validation that warns when required sections are missing."}]',
 3, 0);

-- --- DevOps Skills: 1 review with security flag ---

INSERT OR REPLACE INTO reviews (review_key, agent_id, skill_id, version_hash, stages, rating, security_flag) VALUES
('rv_devops_001', 'agent-seed-gamma', 'github:akin-ozer/cc-devops-skills', 'f7e8d9c0',
 '[{"type": "code_review", "security_ok": false, "quality_rating": 2, "summary": "Functional but has a security concern: generates Terraform with hardcoded credentials in examples.", "findings": "Templates include placeholder AWS keys that look like real credentials. Risk of accidental commit. Otherwise decent IaC generation.", "suggested_improvements": "Use environment variables or AWS profiles instead of hardcoded credentials in all templates."}]',
 NULL, 1);

-- --- Context7 MCP: 1 review (hosted, version_opaque, post_use) ---

INSERT OR REPLACE INTO reviews (review_key, agent_id, skill_id, version_hash, stages, rating, security_flag) VALUES
('rv_ctx7_001', 'agent-seed-alpha', 'github:upstash/context7-mcp', 'e9f0a1b2',
 '[{"type": "code_review", "security_ok": true, "quality_rating": 4, "summary": "Useful MCP server for live documentation. Version is opaque (hosted service) so code review is limited to observed behavior.", "findings": "Returns accurate, version-specific docs. Cannot inspect server-side code.", "suggested_improvements": "Publish a changelog so users know when behavior changes."},
   {"type": "user_decision", "decision": "installed", "installed": true},
   {"type": "post_use", "worked": true, "rating": 4, "task_summary": "Retrieved React 19 docs while building a component library.", "what_worked": "Got accurate hook documentation that matched the installed React version.", "what_didnt": "Occasionally slow (2-3s response time).", "suggested_improvements": "Add caching for frequently accessed library versions."}]',
 4, 0);

-- --- MCP Filesystem: 1 review (code review + decline) ---

INSERT OR REPLACE INTO reviews (review_key, agent_id, skill_id, version_hash, stages, rating, security_flag) VALUES
('rv_fs_001', 'agent-seed-delta', 'github:modelcontextprotocol/servers/filesystem', 'b1c2d3e4',
 '[{"type": "code_review", "security_ok": true, "quality_rating": 4, "summary": "Well-sandboxed filesystem MCP server from the reference implementation.", "findings": "Properly restricts access to configured directories. Good error messages.", "suggested_improvements": "Add recursive directory size calculation."},
   {"type": "user_decision", "decision": "declined", "installed": false, "decline_reason": "Agent already has built-in file tools — MCP filesystem server was redundant for this use case."}]',
 NULL, 0);
