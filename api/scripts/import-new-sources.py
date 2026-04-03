#!/usr/bin/env python3
"""Import skills from new upstream sources into the Clarmory D1 database.

Sources:
  1. npm registry — packages with "mcp-server" or "mcp" in name
  2. Smithery.ai — MCP server registry (public API)
  3. Official MCP servers repo — modelcontextprotocol/servers subdirectories
  4. GitHub topics — claude-code, mcp-server, claude-skills, model-context-protocol
  5. GitHub trending / additional searches

Usage:
  python3 scripts/import-new-sources.py                        # dry run
  python3 scripts/import-new-sources.py --apply                # insert into production
  python3 scripts/import-new-sources.py --apply --source npm   # only one source
  python3 scripts/import-new-sources.py --apply --source smithery
  python3 scripts/import-new-sources.py --apply --source official-mcp
  python3 scripts/import-new-sources.py --apply --source github-topics
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request


API_URL = "https://api.clarmory.com"


def sha256_short(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def fetch_json(url: str, timeout: int = 30) -> dict | list | None:
    """Fetch JSON from a URL."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Clarmory/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                return json.loads(resp.read().decode("utf-8", errors="replace"))
    except Exception as e:
        print(f"  fetch_json error for {url}: {e}", file=sys.stderr)
    return None


def fetch_url(url: str, timeout: int = 15) -> str | None:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Clarmory/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                return resp.read().decode("utf-8", errors="replace")
    except Exception:
        pass
    return None


def gh_api(endpoint: str) -> dict | list | None:
    try:
        result = subprocess.run(
            ["gh", "api", endpoint],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    return None


def skill_exists(skill_id: str, api_url: str) -> bool:
    encoded = urllib.parse.quote(skill_id, safe="")
    try:
        req = urllib.request.Request(
            f"{api_url}/skills/{encoded}",
            headers={"User-Agent": "Clarmory/1.0"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except Exception:
        return False


def infer_tags(name: str, description: str) -> list[str]:
    text = f"{name} {description}".lower()
    keywords = {
        "security": ["security", "audit", "vulnerability", "pentest"],
        "devops": ["devops", "terraform", "kubernetes", "docker", "ci-cd", "deployment", "infrastructure"],
        "testing": ["testing", "test", "tdd", "bdd", "qa"],
        "git": ["git", "version control", "pr ", "pull request"],
        "mcp": ["mcp", "model context protocol", "mcp-server", "mcp server"],
        "database": ["database", "sql", "postgres", "sqlite", "supabase", "prisma", "mongodb", "redis"],
        "agent": ["agent", "orchestrat", "swarm", "multi-agent"],
        "framework": ["framework", "kit", "toolkit", "sdk"],
        "web": ["web", "http", "api ", "rest", "graphql", "browser", "scraping", "crawl"],
        "ai": ["ai ", "llm", "openai", "anthropic", "claude", "gpt", "embedding"],
        "file-management": ["file", "filesystem", "storage", "s3", "blob"],
        "communication": ["slack", "discord", "email", "notification", "chat", "messaging", "sms"],
        "search": ["search", "index", "retrieval", "rag"],
        "cloud": ["aws", "gcp", "azure", "cloudflare", "vercel", "netlify"],
        "data": ["data", "csv", "json", "xml", "parser", "transform"],
        "monitoring": ["monitor", "usage", "analytics", "dashboard", "observability"],
        "documentation": ["documentation", "docs", "readme"],
        "code-review": ["code review", "code-review", "lint", "analysis"],
    }
    tags = []
    for tag, patterns in keywords.items():
        if any(p in text for p in patterns):
            tags.append(tag)
    return tags if tags else ["mcp"]


def sql_escape(s: str) -> str:
    if s is None:
        return "NULL"
    return "'" + s.replace("'", "''") + "'"


def skill_to_sql(skill: dict) -> str:
    """Generate INSERT OR IGNORE SQL for a single skill."""
    tags = " ".join(skill.get("metadata", {}).get("tags", []))
    content = skill.get("content")

    if content:
        return (
            f"INSERT OR IGNORE INTO skills "
            f"(id, source, name, description, version_hash, source_url, install_type, content, tags, metadata) "
            f"VALUES ({sql_escape(skill['id'])}, {sql_escape(skill['source'])}, "
            f"{sql_escape(skill['name'])}, {sql_escape(skill['description'])}, "
            f"{sql_escape(skill['version_hash'])}, {sql_escape(skill['source_url'])}, "
            f"{sql_escape(skill['install_type'])}, {sql_escape(content)}, "
            f"{sql_escape(tags)}, "
            f"{sql_escape(json.dumps(skill.get('metadata', {})))});"
        )
    else:
        return (
            f"INSERT OR IGNORE INTO skills "
            f"(id, source, name, description, version_hash, source_url, install_type, tags, metadata) "
            f"VALUES ({sql_escape(skill['id'])}, {sql_escape(skill['source'])}, "
            f"{sql_escape(skill['name'])}, {sql_escape(skill['description'])}, "
            f"{sql_escape(skill['version_hash'])}, {sql_escape(skill['source_url'])}, "
            f"{sql_escape(skill['install_type'])}, {sql_escape(tags)}, "
            f"{sql_escape(json.dumps(skill.get('metadata', {})))});"
        )


def batch_insert_via_wrangler(skills: list[dict], tmpdir: str, batch_size: int = 50) -> tuple[int, int]:
    """Insert skills in batches via wrangler. Returns (inserted, failed) counts."""
    total_inserted = 0
    total_failed = 0

    for i in range(0, len(skills), batch_size):
        batch = skills[i:i + batch_size]
        sql_statements = [skill_to_sql(s) for s in batch]
        sql_content = "\n".join(sql_statements)

        sql_file = os.path.join(tmpdir, "batch_insert.sql")
        with open(sql_file, "w") as f:
            f.write(sql_content)

        try:
            result = subprocess.run(
                ["npx", "wrangler", "d1", "execute", "clarmory-db", "--remote",
                 f"--file={sql_file}"],
                capture_output=True, text=True, timeout=60,
                cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            )
            if result.returncode == 0:
                total_inserted += len(batch)
                print(f"  Batch {i//batch_size + 1}: inserted {len(batch)} skills ({i+len(batch)}/{len(skills)})")
            else:
                total_failed += len(batch)
                print(f"  Batch {i//batch_size + 1}: FAILED ({result.stderr[:200]})", file=sys.stderr)
        except subprocess.TimeoutExpired:
            total_failed += len(batch)
            print(f"  Batch {i//batch_size + 1}: TIMEOUT", file=sys.stderr)

        time.sleep(0.5)  # brief pause between batches

    return total_inserted, total_failed


# ============================================================
# Source: npm registry
# ============================================================

def fetch_npm_mcp_servers() -> list[dict]:
    """Fetch MCP server packages from npm registry."""
    skills = []
    seen = set()

    # Paginate through npm search results
    for offset in range(0, 1000, 250):
        url = f"https://registry.npmjs.org/-/v1/search?text=mcp-server&size=250&from={offset}"
        data = fetch_json(url)
        if not data or not data.get("objects"):
            break

        batch_relevant = 0
        for obj in data["objects"]:
            pkg = obj["package"]
            name = pkg["name"]
            name_lower = name.lower()

            # Only include packages with "mcp" in the name
            if "mcp" not in name_lower:
                continue

            if name in seen:
                continue
            seen.add(name)

            description = pkg.get("description") or ""
            if len(description) > 500:
                description = description[:497] + "..."

            # Extract repo URL
            links = pkg.get("links", {})
            repo_url = links.get("repository", "")
            homepage = links.get("homepage", "")
            npm_url = links.get("npm", f"https://www.npmjs.com/package/{name}")

            # Clean git URL to https
            source_url = repo_url or homepage or npm_url
            source_url = re.sub(r'^git\+', '', source_url)
            source_url = re.sub(r'^ssh://git@github\.com/', 'https://github.com/', source_url)
            source_url = re.sub(r'^git@github\.com:', 'https://github.com/', source_url)
            source_url = re.sub(r'\.git$', '', source_url)

            # Use npm package name as ID (avoids collisions with github: IDs)
            skill_id = f"npm:{name}"

            # Get author
            publisher = pkg.get("publisher", {})
            author = publisher.get("username", "")

            # Display name: strip common prefixes, prettify
            display_name = name
            display_name = re.sub(r'^@[^/]+/', '', display_name)  # strip scope
            display_name = re.sub(r'[-_]', ' ', display_name).title()

            skills.append({
                "id": skill_id,
                "source": "npm",
                "name": display_name,
                "description": description,
                "source_url": source_url,
                "install_type": "mcp-local",
                "author": author,
                "version_hash": sha256_short(f"{name}@{pkg.get('version', '')}"),
            })
            batch_relevant += 1

        print(f"  npm offset={offset}: {len(data['objects'])} results, {batch_relevant} new MCP packages")

        # If fewer than 250 returned, we've reached the end
        if len(data["objects"]) < 250:
            break

        time.sleep(0.5)  # rate limit

    return skills


# ============================================================
# Source: Smithery.ai
# ============================================================

def fetch_smithery_servers() -> list[dict]:
    """Fetch MCP servers from Smithery.ai registry API."""
    skills = []
    seen = set()

    # Get top servers by usage (most popular first)
    for page in range(1, 11):  # up to 1000 servers
        url = f"https://registry.smithery.ai/servers?pageSize=100&page={page}"
        data = fetch_json(url)
        if not data or not data.get("servers"):
            break

        for server in data["servers"]:
            qname = server.get("qualifiedName", "")
            if not qname or qname in seen:
                continue
            seen.add(qname)

            display_name = server.get("displayName") or qname
            description = server.get("description") or ""
            if len(description) > 500:
                description = description[:497] + "..."

            homepage = server.get("homepage") or f"https://smithery.ai/servers/{qname}"
            is_remote = server.get("remote", False)

            skill_id = f"smithery:{qname}"
            install_type = "mcp-hosted" if is_remote else "mcp-local"

            skills.append({
                "id": skill_id,
                "source": "smithery",
                "name": display_name,
                "description": description,
                "source_url": homepage,
                "install_type": install_type,
                "author": server.get("namespace", ""),
                "version_hash": sha256_short(f"{qname}:{server.get('createdAt', '')}"),
            })

        print(f"  smithery page={page}: {len(data['servers'])} servers")

        pagination = data.get("pagination", {})
        if page >= pagination.get("totalPages", 0):
            break

        time.sleep(0.3)

    return skills


# ============================================================
# Source: Official MCP servers repo
# ============================================================

def fetch_official_mcp_servers() -> list[dict]:
    """Fetch individual servers from modelcontextprotocol/servers."""
    skills = []

    # Get subdirectories
    contents = gh_api("repos/modelcontextprotocol/servers/contents/src")
    if not contents:
        print("  Failed to list official MCP servers repo")
        return []

    for item in contents:
        if item.get("type") != "dir":
            continue

        name = item["name"]
        skill_id = f"github:modelcontextprotocol/servers/{name}"

        # Fetch README for description
        readme_url = f"https://raw.githubusercontent.com/modelcontextprotocol/servers/HEAD/src/{name}/README.md"
        readme = fetch_url(readme_url)

        description = ""
        if readme:
            # Extract first paragraph after the title
            lines = readme.split("\n")
            for line in lines[1:]:  # skip title
                line = line.strip()
                if line and not line.startswith("#") and not line.startswith("<!--") and not line.startswith("|") and not line.startswith("["):
                    description = line
                    break

        if not description:
            description = f"Official MCP server: {name}"

        display_name = re.sub(r'[-_]', ' ', name).title()

        skills.append({
            "id": skill_id,
            "source": "official-mcp",
            "name": f"MCP {display_name}",
            "description": description,
            "source_url": f"https://github.com/modelcontextprotocol/servers/tree/main/src/{name}",
            "install_type": "mcp-local",
            "author": "modelcontextprotocol",
            "version_hash": sha256_short(readme or name),
            "content": readme,
        })
        print(f"  Official MCP: {name}")

    return skills


# ============================================================
# Source: GitHub topics
# ============================================================

def fetch_github_topics() -> list[dict]:
    """Search GitHub repos by topic."""
    skills = []
    seen = set()

    topics = [
        ("mcp-server", "mcp-local", 100),
        ("mcp-servers", "mcp-local", 50),
        ("model-context-protocol", "mcp-local", 50),
        ("claude-code", "skill", 50),
        ("claude-skills", "skill", 50),
        ("claude-code-skill", "skill", 50),
        ("claude-code-extension", "skill", 50),
    ]

    for topic, default_type, limit in topics:
        cmd = ["gh", "search", "repos", f"--topic={topic}",
               "--limit", str(limit), "--json", "fullName,description",
               "--sort", "stars"]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            if result.returncode != 0:
                print(f"  topic {topic}: search failed")
                continue
            repos = json.loads(result.stdout)
        except (subprocess.TimeoutExpired, json.JSONDecodeError):
            print(f"  topic {topic}: error")
            continue

        added = 0
        for repo in repos:
            full_name = repo.get("fullName", "")
            if not full_name or full_name in seen:
                continue
            seen.add(full_name)

            description = repo.get("description") or ""
            if not description:
                description = f"From GitHub topic: {topic}"
            if len(description) > 500:
                description = description[:497] + "..."

            name = full_name.split("/")[1]
            display_name = re.sub(r'[-_]', ' ', name).title()
            owner = full_name.split("/")[0]

            # Determine install type from name/description
            text_lower = f"{name} {description}".lower()
            if "mcp" in text_lower:
                install_type = "mcp-local"
                if any(w in text_lower for w in ["hosted", "cloud", "saas"]):
                    install_type = "mcp-hosted"
            else:
                install_type = default_type

            skill_id = f"github:{full_name}"

            skills.append({
                "id": skill_id,
                "source": f"github-topic:{topic}",
                "name": display_name,
                "description": description,
                "source_url": f"https://github.com/{full_name}",
                "install_type": install_type,
                "author": owner,
            })
            added += 1

        print(f"  topic {topic}: {len(repos)} repos, {added} new")
        time.sleep(1)

    return skills


# ============================================================
# Main
# ============================================================

def main():
    parser = argparse.ArgumentParser(description="Import new sources into Clarmory DB")
    parser.add_argument("--apply", action="store_true", help="Actually insert (default: dry run)")
    parser.add_argument("--api", default=API_URL, help="API URL for existence checks")
    parser.add_argument("--source", choices=["npm", "smithery", "official-mcp", "github-topics", "all"],
                        default="all", help="Which source to import")
    parser.add_argument("--skip-exists-check", action="store_true",
                        help="Skip per-skill existence check (rely on INSERT OR IGNORE)")
    args = parser.parse_args()

    print(f"API: {args.api}")
    print(f"Mode: {'APPLY' if args.apply else 'DRY RUN'}")
    print(f"Source: {args.source}")
    print()

    with tempfile.TemporaryDirectory() as tmpdir:
        all_skills = []
        seen_ids = set()

        sources = {
            "npm": ("npm registry", fetch_npm_mcp_servers),
            "smithery": ("Smithery.ai", fetch_smithery_servers),
            "official-mcp": ("Official MCP servers", fetch_official_mcp_servers),
            "github-topics": ("GitHub topics", fetch_github_topics),
        }

        run_sources = sources.keys() if args.source == "all" else [args.source]

        for source_key in run_sources:
            label, fetcher = sources[source_key]
            print(f"=== Source: {label} ===")
            skills = fetcher()
            added = 0
            for skill in skills:
                if skill["id"] in seen_ids:
                    continue
                seen_ids.add(skill["id"])
                all_skills.append(skill)
                added += 1
            print(f"  Total from {label}: {len(skills)} found, {added} unique new")
            print()

        print(f"=== Total unique skills to process: {len(all_skills)} ===")
        print()

        # --- Enrich skills ---
        print("=== Enriching skills ===")
        to_insert = []
        skipped = 0

        for i, skill in enumerate(all_skills):
            skill_id = skill["id"]

            # Check existence via API (skip if --skip-exists-check, rely on INSERT OR IGNORE)
            if args.apply and not args.skip_exists_check and skill_exists(skill_id, args.api):
                skipped += 1
                continue

            # Build version hash if not set
            if "version_hash" not in skill:
                skill["version_hash"] = sha256_short(skill["description"])

            # Build tags
            tags = infer_tags(skill["name"], skill["description"])
            skill["metadata"] = {"tags": tags, "author": skill.pop("author", "")}

            to_insert.append(skill)

            if not args.apply:
                print(f"  [{i+1}/{len(all_skills)}] {skill_id}: {skill['name']}")

        print(f"  Skills to insert: {len(to_insert)}, already exist: {skipped}")
        print()

        # --- Batch insert ---
        if args.apply and to_insert:
            print(f"=== Batch inserting {len(to_insert)} skills ===")
            inserted, failed = batch_insert_via_wrangler(to_insert, tmpdir, batch_size=50)
        elif not args.apply:
            inserted = len(to_insert)
            failed = 0
        else:
            inserted = 0
            failed = 0

        print()
        print("=== Summary ===")
        print(f"  {'Would insert' if not args.apply else 'Inserted'}: {inserted}")
        print(f"  Skipped (exists): {skipped}")
        if args.apply:
            print(f"  Failed: {failed}")


if __name__ == "__main__":
    main()
