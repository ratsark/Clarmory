# Search Improvements Research

Research into improving Clarmory's `/search` endpoint. Current state: FTS5 over
`name` + `description` columns with default tokenizer, no column weights, no tags
in the FTS index. ~200 skills indexed, most with zero reviews.

## Current Problems

1. **Narrow FTS matching**: "vision" returns 1 result, "image" returns 1, "screenshot camera visual" returns 0. The default tokenizer does exact token matching with no stemming.
2. **No structured categorization**: Skills have `tags` in their metadata JSON but these aren't indexed or searchable. An agent searching for "vision" can't find Clearshot because neither its name nor description happens to use that exact word.
3. **Cold start for ranking dimensions**: highest-rated, most-used, and rising dimensions return nothing for most queries because almost no skills have reviews yet.

## Recommendation 1: Better FTS5 Configuration (HIGH IMPACT, LOW COST)

### Problem
The current FTS5 table uses the default tokenizer (unicode61, no stemming):

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS skills_fts USING fts5(
  name,
  description,
  content=skills,
  content_rowid=rowid
);
```

This means "testing" won't match "test", "containers" won't match "container",
"visualize" won't match "vision" (though stemming won't solve all synonym cases).

### Fix: Porter stemming + column weights + tags in index

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS skills_fts USING fts5(
  name,
  description,
  tags,
  content=skills,
  content_rowid=rowid,
  tokenize='porter unicode61'
);
```

**Porter stemming** reduces words to stems: "testing"/"tests"/"tested" all become
"test". This is FTS5's built-in stemmer -- zero dependencies, just a tokenizer
config change. It won't solve true synonyms ("vision" vs "camera") but it catches
the most common class of near-misses.

**Column weights via BM25**: FTS5's `bm25()` function accepts per-column weights.
A name match should outrank a description match, and a tag match should boost
relevance. The current query uses `ORDER BY rank` which is unweighted BM25.

Change search query to:
```sql
SELECT s.*, bm25(skills_fts, 10.0, 1.0, 5.0) AS relevance
FROM skills_fts fts
JOIN skills s ON s.rowid = fts.rowid
WHERE skills_fts MATCH ?
ORDER BY relevance
LIMIT ?
```

Weights: name=10, description=1, tags=5. BM25 returns lower values for better
matches, so `ORDER BY relevance` (ascending) is correct -- which is what
`ORDER BY rank` already does, since `rank` is an alias for `bm25()` with equal
weights.

**Tags in the FTS index**: The seed data already has tags in the metadata JSON
(e.g., `"tags": ["security", "audit", "vulnerability"]`). Adding a `tags` column
to the FTS table and populating it with space-separated tag values means a search
for "vision" would match a skill tagged "vision" even if the word doesn't appear
in name/description.

### Migration path
1. Add a `tags` TEXT column to the `skills` table (extracted from metadata JSON on insert/update)
2. Recreate the FTS table with porter tokenizer and tags column
3. Update sync triggers to populate tags
4. Update the search query to use weighted `bm25()`

### What this fixes
- "testing" matches skills about "test" (stemming)
- "containers" matches "container", "containerization" (stemming)
- Category-style searches like "vision", "devops", "iot" work if skills are tagged appropriately (tags in index)
- Name matches rank higher than description-only matches (column weights)

### What this doesn't fix
- True synonyms: "camera" won't match "vision" unless both stem to the same root (they don't)
- Conceptual queries: "something to help me take screenshots" won't match unless description or tags contain relevant stems

## Recommendation 2: Structured Tags (HIGH IMPACT, MODERATE COST)

### Problem
The seed data already has tags in metadata JSON, but they're invisible to search.
Tags solve the vocabulary mismatch problem: a skill can be tagged "vision" even if
its description says "screenshot capture" instead.

### Design

Add a first-class `tags` column to the `skills` table:

```sql
ALTER TABLE skills ADD COLUMN tags TEXT DEFAULT '';
```

Store as space-separated lowercase tokens (FTS-friendly). Example: `"vision screenshot capture image"`.

This column feeds into the FTS table (see Recommendation 1) and can also support
exact-match tag filtering:

```
GET /search?q=screenshot&tag=vision
```

### Tag generation for existing skills

For 200 skills, a one-time batch script can:
1. Extract existing tags from `metadata.tags` JSON
2. Optionally enrich with GitHub repo topics (already fetched during sync)
3. Manual curation for the initial set is feasible at 200 skills

For new skills added via sync:
- GitHub repos: use repo topics as tags (free, already in GitHub API response)
- awesome-claude-code: extract from list item descriptions
- MCP registry: use registry-provided categories

### How registries do it

- **crates.io**: Authors set keywords (max 5) and one category. Keywords are
  free-form strings; categories are from a curated list. Search indexes both.
  [RFC 1824](https://rust-lang.github.io/rfcs/1824-crates.io-default-ranking.html)
  uses recent downloads for ranking within categories.
- **npm**: Indexes `keywords` from package.json alongside name, description, and
  README. Search results are sorted by text relevance with a popularity boost from
  downloads.
- **PyPI**: Uses "trove classifiers" -- hierarchical structured categories
  (`Framework :: Django :: 4.0`). Good for browsing but heavyweight for 200 skills.
- **VS Code Marketplace**: Fixed category list (Debuggers, Formatters, Linters,
  Testing, etc.) plus free-form tags. Supports `category:` and `tag:` filter
  prefixes in search.

### Recommendation for Clarmory

Use **free-form tags** (like npm keywords / crates.io keywords), not a fixed
category taxonomy. Reasons:
- Simpler to implement (just a text column, no separate tables)
- Authors can add domain-specific tags without waiting for taxonomy updates
- Agents can search or filter by tag
- At 200 skills, a curated taxonomy is premature

Return tags in search results so agents can see what terms a skill is categorized
under. This aids transparency ("this matched because it's tagged 'vision'").

## Recommendation 3: Search Response Improvements (MODERATE IMPACT, LOW COST)

### Return match context

Tell the agent *why* something matched. Current response includes `inclusion_reason`
(most-relevant, highest-rated, etc.) but not *what matched*. Add a `match_details`
field:

```json
{
  "id": "github:example/clearshot",
  "name": "Clearshot",
  "inclusion_reason": "most-relevant",
  "match_details": {
    "matched_fields": ["tags"],
    "matched_terms": ["vision"]
  }
}
```

This is cheap to compute: FTS5's `highlight()` or `snippet()` auxiliary functions
can identify which columns matched. For tags specifically, a simple string check
on the tags column works.

Why this matters: agents are smart consumers. If they see "matched on tag only,
not description," they can make better install decisions. It also prevents the
agent from doing redundant follow-up searches.

### Return total count

Current response returns `{ results: [...] }` with no indication of how many
total results exist. Adding `total_count` lets the agent decide whether to
paginate or reformulate:

```json
{
  "total_count": 47,
  "results": [...]
}
```

This is a simple `SELECT COUNT(*)` from the FTS match before applying LIMIT.

## Recommendation 4: Cold Start Mitigations (MODERATE IMPACT, LOW COST)

### Problem
With ~200 skills and near-zero reviews, the highest-rated, most-used, and rising
dimensions return nothing. Three of four search dimensions are dead weight.

### Options

**Option A: Editorial picks (recommended)**
Add an `editorial_score` column to skills. Manually assign scores (0-100) to
skills based on:
- Source reputation (Trail of Bits > random GitHub user)
- README quality and completeness
- Whether the skill has inline content
- GitHub stars (available from sync)

Use editorial_score as a fallback ranking when review data is insufficient:
```sql
-- "highest-rated" dimension with cold start fallback
ORDER BY COALESCE(rs.avg_rating, editorial_score / 20.0) DESC
```

This gives reasonable results immediately and gracefully degrades as real reviews
accumulate (reviews take priority over editorial scores).

**Option B: Use GitHub stars as popularity proxy**
Stars are already available or easily fetched during sync. Use `stars_count` as
the "most-used" proxy until real usage data exists:
```sql
-- "most-used" with cold start fallback
ORDER BY COALESCE(rs.review_count - rs.decline_count, 0) + 
         COALESCE(json_extract(s.metadata, '$.stars'), 0) * 0.01 DESC
```

**Option C: Collapse empty dimensions**
If a dimension returns no results, don't show it. Return only dimensions that
have actual data. This is the simplest approach but means most searches only
return the "most-relevant" dimension.

### Recommendation
Combine A and C: add editorial scores for the initial 200 skills (feasible manual
effort), use them as fallback, and suppress dimensions that still return nothing
after fallback. As reviews accumulate, they naturally replace editorial scores.

## Recommendation 5: Indexing README / SKILL.md Content (LOW PRIORITY)

### Problem
Some skills have rich README content that describes capabilities not mentioned in
the short description. Indexing this content would improve recall.

### Trade-offs
- **Pro**: More text = more potential matches for obscure queries
- **Con**: README content is noisy (installation instructions, license text, code
  samples). This can pollute relevance -- a skill whose README mentions "docker"
  in a setup section shouldn't rank for "docker" queries.
- **Con**: Content must be fetched from GitHub on sync, increasing API calls
- **Con**: Larger FTS index, though at 200 skills this is negligible

### Recommendation
Defer this. Tags + porter stemming solve the vocabulary gap more cleanly. If
recall is still a problem after those changes, revisit indexing a curated
"extended_description" field (manually cleaned README excerpts, not raw README).

## Recommendation 6: Query Suggestions (LOW PRIORITY)

### Problem
An agent searches for "vision" and gets 1 result. Should we suggest "image",
"screenshot", "capture" as related searches?

### Why this is low priority for Clarmory
The constraint note in the task is exactly right: agents are smart and can
reformulate queries themselves. Auto-suggesting "did you mean X?" adds complexity
and may confuse an agent that already has a search strategy. The agent client
(SKILL.md) can instruct the agent to try broader/narrower queries.

If implemented later, the cheapest approach is tag co-occurrence: "skills tagged
'vision' are also tagged 'image', 'screenshot', 'capture'" -- return these as
`related_tags` in the response. This requires no additional infrastructure, just
a query on the tags column.

## Recommendation 7: Faceted Search Filters (LOW PRIORITY)

### Current state
The API supports `?type=skill` or `?type=mcp` filtering. This is the only facet.

### Additional facets worth adding eventually
- `?tag=vision` -- filter to skills with a specific tag
- `?source=github` -- filter by upstream source
- `?has_reviews=true` -- only show skills with at least one review
- `?has_content=true` -- only show skills with inline content

These are all simple WHERE clauses on existing columns. Low effort, moderate value
for agent filtering. But they only matter once the catalog is large enough that
unfiltered results are overwhelming -- not a problem at 200 skills.

## Priority Summary

| # | Change | Impact | Cost | Depends on |
|---|--------|--------|------|------------|
| 1 | Porter stemming + BM25 weights | High | Low | Nothing |
| 2 | Tags column in FTS index | High | Moderate | #1 (same FTS rebuild) |
| 4 | Cold start fallbacks | Moderate | Low | Nothing |
| 3 | Match context in response | Moderate | Low | #1 (uses FTS aux functions) |
| 7 | Faceted search (?tag=) | Low-Moderate | Low | #2 (needs tags column) |
| 5 | Index README content | Low | Moderate | Nothing |
| 6 | Query suggestions | Low | Moderate | #2 (needs tags for co-occurrence) |

**Recommended implementation order**: 1+2 together (single FTS table rebuild),
then 4, then 3. The rest can wait until the catalog grows or user feedback
indicates need.

## Implementation Sketch for #1 + #2

### Schema changes

```sql
-- Add tags column to skills table
ALTER TABLE skills ADD COLUMN tags TEXT DEFAULT '';

-- Populate from metadata JSON (one-time migration)
UPDATE skills SET tags = (
  SELECT GROUP_CONCAT(j.value, ' ')
  FROM json_each(json_extract(metadata, '$.tags')) AS j
) WHERE json_extract(metadata, '$.tags') IS NOT NULL;

-- Recreate FTS table with porter stemming and tags
DROP TRIGGER IF EXISTS skills_ai;
DROP TRIGGER IF EXISTS skills_ad;
DROP TRIGGER IF EXISTS skills_au;
DROP TABLE IF EXISTS skills_fts;

CREATE VIRTUAL TABLE skills_fts USING fts5(
  name,
  description,
  tags,
  content=skills,
  content_rowid=rowid,
  tokenize='porter unicode61'
);

-- Rebuild index from existing data
INSERT INTO skills_fts(rowid, name, description, tags)
  SELECT rowid, name, description, tags FROM skills;

-- Updated triggers
CREATE TRIGGER skills_ai AFTER INSERT ON skills BEGIN
  INSERT INTO skills_fts(rowid, name, description, tags)
  VALUES (new.rowid, new.name, new.description, new.tags);
END;

CREATE TRIGGER skills_ad AFTER DELETE ON skills BEGIN
  INSERT INTO skills_fts(skills_fts, rowid, name, description, tags)
  VALUES ('delete', old.rowid, old.name, old.description, old.tags);
END;

CREATE TRIGGER skills_au AFTER UPDATE ON skills BEGIN
  INSERT INTO skills_fts(skills_fts, rowid, name, description, tags)
  VALUES ('delete', old.rowid, old.name, old.description, old.tags);
  INSERT INTO skills_fts(rowid, name, description, tags)
  VALUES (new.rowid, new.name, new.description, new.tags);
END;
```

### Search query change

```sql
SELECT s.*, bm25(skills_fts, 10.0, 1.0, 5.0) AS relevance,
       'most-relevant' AS inclusion_reason
FROM skills_fts fts
JOIN skills s ON s.rowid = fts.rowid
WHERE skills_fts MATCH ?
ORDER BY relevance
LIMIT ?
```

### Seed data change

Update INSERT statements to include `tags` column:
```sql
INSERT INTO skills (..., tags) VALUES
('github:trailofbits/skills/security-audit', ...,
 'security audit vulnerability code-review', ...);
```

The tags value should be the space-separated union of `metadata.tags` plus any
additional terms that describe the skill's category (e.g., adding "vision" to
Clearshot even if the metadata didn't include it).
