#!/usr/bin/env python3
"""Import real skills from upstream sources into the Clarmory D1 database.

Sources:
  1. awesome-claude-code (hesreallyhim/awesome-claude-code) — curated README
  2. GitHub code search — repos containing SKILL.md files
  3. GitHub search — Claude Code skills (various search terms)
  4. GitHub search — MCP servers (mcp-server, modelcontextprotocol)
  5. GitHub search — APM packages (apm.yml files)
  6. Other awesome-claude lists on GitHub

Usage:
  python3 scripts/import-skills.py                        # dry run
  python3 scripts/import-skills.py --apply                # insert into production
  python3 scripts/import-skills.py --apply --api URL      # custom API URL
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
    """Return first 16 chars of SHA256 hex digest."""
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def gh_api(endpoint: str) -> dict | list | None:
    """Call GitHub API via gh CLI."""
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


def fetch_url(url: str, timeout: int = 15) -> str | None:
    """Fetch a URL and return body text, or None on failure."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Clarmory/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                return resp.read().decode("utf-8", errors="replace")
    except Exception:
        pass
    return None


def skill_exists(skill_id: str, api_url: str) -> bool:
    """Check if a skill already exists in the API."""
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


def parse_awesome_readme(readme_text: str) -> list[dict]:
    """Parse the awesome-claude-code README for skill entries."""
    skills = []
    seen_urls = set()

    # Pattern: - [Name](URL) by ... - Description
    # Also handle entries with [author](url) after "by"
    pattern = r'- \[([^\]]+)\]\((https://github\.com/[^)]+)\)[^-]*?- (.+?)(?:\n|$)'

    for match in re.finditer(pattern, readme_text):
        name = match.group(1).strip()
        url = match.group(2).strip()
        description = match.group(3).strip()

        # Skip non-repo links
        if "youtu" in url or "marketplace" in url:
            continue

        # Normalize URL
        url = re.sub(r'/tree/.*$', '', url)
        url = url.rstrip('/')

        # Extract owner/repo
        parts = url.replace("https://github.com/", "").split("/")
        if len(parts) < 2:
            continue
        owner, repo = parts[0], parts[1]

        if url in seen_urls:
            continue
        seen_urls.add(url)

        # Truncate description
        if len(description) > 500:
            description = description[:497] + "..."

        # Clean up description — remove markdown links, trailing HTML
        description = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', description)
        description = re.sub(r'<[^>]+>', '', description).strip()
        # Remove trailing incomplete sentences
        description = re.sub(r'\s*\([^)]*$', '', description).strip()

        skills.append({
            "id": f"github:{owner}/{repo}",
            "source": "awesome-claude-code",
            "name": name,
            "description": description,
            "source_url": url,
            "install_type": "skill",
            "author": owner,
        })

    return skills


def fetch_skillmd(owner_repo: str) -> str | None:
    """Try to fetch SKILL.md from common locations in a repo."""
    for path in ["SKILL.md", "skill.md", "Skill.md", ".claude/skills/SKILL.md"]:
        url = f"https://raw.githubusercontent.com/{owner_repo}/HEAD/{path}"
        content = fetch_url(url)
        if content and len(content) > 50:
            return content
    return None


def infer_tags(name: str, description: str) -> list[str]:
    """Infer tags from name and description."""
    text = f"{name} {description}".lower()
    keywords = {
        "security": ["security", "audit", "vulnerability", "pentest"],
        "devops": ["devops", "terraform", "kubernetes", "docker", "ci-cd", "deployment", "infrastructure"],
        "planning": ["planning", "workflow", "project-management", "task"],
        "testing": ["testing", "test", "tdd", "bdd", "qa"],
        "code-review": ["code review", "code-review", "lint", "analysis"],
        "git": ["git", "version control", "pr ", "pull request"],
        "mcp": ["mcp", "model context protocol", "mcp-server", "mcp server"],
        "research": ["research", "scientific", "academic"],
        "documentation": ["documentation", "docs", "readme"],
        "database": ["database", "sql", "postgres", "sqlite", "supabase", "prisma"],
        "agent": ["agent", "orchestrat", "swarm", "multi-agent"],
        "hooks": ["hook"],
        "commands": ["command", "slash-command", "slash command"],
        "framework": ["framework", "kit", "toolkit"],
        "monitoring": ["monitor", "usage", "analytics", "dashboard"],
        "web": ["web", "http", "api ", "rest", "graphql", "browser"],
        "ai": ["ai ", "llm", "openai", "anthropic", "claude", "gpt", "embedding"],
        "file-management": ["file", "filesystem", "storage", "s3", "blob"],
        "communication": ["slack", "discord", "email", "notification", "chat", "messaging"],
        "search": ["search", "index", "retrieval", "rag"],
        "cloud": ["aws", "gcp", "azure", "cloudflare", "vercel", "netlify"],
        "data": ["data", "csv", "json", "xml", "parser", "transform"],
        "apm": ["apm", "application performance", "observability", "tracing"],
    }
    tags = []
    for tag, patterns in keywords.items():
        if any(p in text for p in patterns):
            tags.append(tag)
    return tags if tags else ["skill"]


def search_github_skillmd() -> list[dict]:
    """Search GitHub for repos containing SKILL.md files."""
    try:
        result = subprocess.run(
            ["gh", "search", "code", "filename:SKILL.md", "--limit", "50",
             "--json", "repository,path"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return []
        data = json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        return []

    seen = set()
    repos = []
    for item in data:
        repo = item["repository"]["nameWithOwner"]
        if repo in seen:
            continue
        seen.add(repo)
        repos.append({"repo": repo, "path": item["path"]})
    return repos


def search_github_repos(query: str, limit: int = 50, sort: str = "") -> list[dict]:
    """Search GitHub repos by query string. Returns list of {repo, description}.
    sort can be 'stars', 'forks', 'updated', etc."""
    cmd = ["gh", "search", "repos", query, "--limit", str(limit),
           "--json", "fullName,description"]
    if sort:
        cmd.extend(["--sort", sort])
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return []
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        return []


def search_github_claude_skills() -> list[dict]:
    """Search GitHub for Claude Code skill repos using various search terms."""
    search_terms = [
        "claude code skill",
        "claude-code plugin",
        "claude code extension",
        "claude code SKILL.md",
    ]
    seen = set()
    results = []
    for term in search_terms:
        repos = search_github_repos(term, limit=30)
        for repo in repos:
            name = repo.get("fullName", "")
            if not name or name in seen:
                continue
            seen.add(name)
            results.append({
                "repo": name,
                "description": repo.get("description") or "",
            })
        time.sleep(1)  # rate limit between searches
    return results


def search_github_mcp_servers() -> list[dict]:
    """Search GitHub for MCP server repos, sorted by stars for quality."""
    search_terms = [
        ("mcp-server in:name", 100),
        ("modelcontextprotocol in:name", 50),
        ("mcp server in:description", 80),
        ("model context protocol server in:description", 50),
        ("mcp-server- in:name", 50),          # catches mcp-server-* repos
    ]
    seen = set()
    results = []
    for term, limit in search_terms:
        repos = search_github_repos(term, limit=limit, sort="stars")
        for repo in repos:
            name = repo.get("fullName", "")
            if not name or name in seen:
                continue
            seen.add(name)
            results.append({
                "repo": name,
                "description": repo.get("description") or "",
            })
        time.sleep(1)
    return results


def search_github_apm_packages() -> list[dict]:
    """Search GitHub for repos with apm.yml files (APM packages)."""
    try:
        result = subprocess.run(
            ["gh", "search", "code", "filename:apm.yml", "--limit", "50",
             "--json", "repository,path"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return []
        data = json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        return []

    seen = set()
    repos = []
    for item in data:
        repo = item["repository"]["nameWithOwner"]
        if repo in seen:
            continue
        seen.add(repo)
        repos.append({"repo": repo, "path": item["path"]})
    return repos


def search_other_awesome_lists() -> list[dict]:
    """Search GitHub for other awesome-claude lists beyond hesreallyhim's."""
    search_terms = [
        "awesome-claude-code in:name",
        "awesome-claude in:name",
        "awesome claude code in:name",
    ]
    seen = set()
    readme_repos = []
    for term in search_terms:
        repos = search_github_repos(term, limit=20)
        for repo in repos:
            name = repo.get("fullName", "")
            if not name or name in seen:
                continue
            # Skip the primary source (already handled)
            if name == "hesreallyhim/awesome-claude-code":
                continue
            seen.add(name)
            readme_repos.append(name)
        time.sleep(1)
    return readme_repos


def search_anthropic_repos() -> list[dict]:
    """Fetch repos from the anthropics GitHub org for skills/MCP servers."""
    results = []
    try:
        result = subprocess.run(
            ["gh", "api", "orgs/anthropics/repos", "--paginate",
             "-q", '.[] | {fullName: .full_name, description: .description}'],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return []
        # Output is newline-delimited JSON objects
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            try:
                repo = json.loads(line)
                results.append(repo)
            except json.JSONDecodeError:
                continue
    except subprocess.TimeoutExpired:
        pass
    return results


def insert_via_wrangler(skill: dict, tmpdir: str) -> bool:
    """Insert a skill into remote D1 via wrangler d1 execute."""
    def sql_escape(s: str) -> str:
        if s is None:
            return "NULL"
        return "'" + s.replace("'", "''") + "'"

    content = skill.get("content")
    tags = " ".join(skill.get("metadata", {}).get("tags", []))
    if content:
        sql = (
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
        sql = (
            f"INSERT OR IGNORE INTO skills "
            f"(id, source, name, description, version_hash, source_url, install_type, tags, metadata) "
            f"VALUES ({sql_escape(skill['id'])}, {sql_escape(skill['source'])}, "
            f"{sql_escape(skill['name'])}, {sql_escape(skill['description'])}, "
            f"{sql_escape(skill['version_hash'])}, {sql_escape(skill['source_url'])}, "
            f"{sql_escape(skill['install_type'])}, {sql_escape(tags)}, "
            f"{sql_escape(json.dumps(skill.get('metadata', {})))});"
        )

    sql_file = os.path.join(tmpdir, "insert.sql")
    with open(sql_file, "w") as f:
        f.write(sql)

    try:
        result = subprocess.run(
            ["npx", "wrangler", "d1", "execute", "clarmory-db", "--remote",
             f"--file={sql_file}"],
            capture_output=True, text=True, timeout=30,
            cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        )
        if result.returncode == 0:
            return True
        else:
            print(f"    wrangler error: {result.stderr[:200]}", file=sys.stderr)
            return False
    except subprocess.TimeoutExpired:
        print(f"    wrangler timeout", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(description="Import skills into Clarmory DB")
    parser.add_argument("--apply", action="store_true", help="Actually insert (default: dry run)")
    parser.add_argument("--api", default=API_URL, help="API URL for existence checks")
    args = parser.parse_args()

    print(f"API: {args.api}")
    print(f"Mode: {'APPLY' if args.apply else 'DRY RUN'}")
    print()

    with tempfile.TemporaryDirectory() as tmpdir:
        all_skills = []
        seen_ids = set()

        # --- Source 1: awesome-claude-code ---
        print("=== Source: awesome-claude-code ===")
        readme_data = gh_api("repos/hesreallyhim/awesome-claude-code/readme")
        if readme_data and "content" in readme_data:
            import base64
            readme_text = base64.b64decode(readme_data["content"]).decode("utf-8")
            awesome_skills = parse_awesome_readme(readme_text)
            print(f"  Parsed {len(awesome_skills)} entries from README")

            for skill in awesome_skills:
                if skill["id"] in seen_ids:
                    continue
                seen_ids.add(skill["id"])
                all_skills.append(skill)
        else:
            print("  Failed to fetch README")

        # --- Source 2: GitHub SKILL.md search ---
        print()
        print("=== Source: GitHub SKILL.md search ===")
        skillmd_repos = search_github_skillmd()
        print(f"  Found {len(skillmd_repos)} repos with SKILL.md")

        for repo_info in skillmd_repos:
            repo = repo_info["repo"]
            skill_id = f"github:{repo}"
            if skill_id in seen_ids:
                continue
            seen_ids.add(skill_id)

            # Fetch repo info for description
            repo_data = gh_api(f"repos/{repo}")
            description = ""
            if repo_data:
                description = repo_data.get("description") or ""

            if not description:
                description = f"Claude Code skill from {repo}"

            # Extract name from repo name
            name = repo.split("/")[1]
            name = re.sub(r'[-_]', ' ', name).title()

            owner = repo.split("/")[0]
            all_skills.append({
                "id": skill_id,
                "source": "github",
                "name": name,
                "description": description,
                "source_url": f"https://github.com/{repo}",
                "install_type": "skill",
                "author": owner,
            })

        # --- Source 3: GitHub search for Claude Code skills ---
        print()
        print("=== Source: GitHub Claude Code skill search ===")
        claude_skills = search_github_claude_skills()
        print(f"  Found {len(claude_skills)} repos")
        added_3 = 0

        for repo_info in claude_skills:
            repo = repo_info["repo"]
            skill_id = f"github:{repo}"
            if skill_id in seen_ids:
                continue
            seen_ids.add(skill_id)

            description = repo_info.get("description") or ""
            if not description:
                description = f"Claude Code skill from {repo}"

            name = repo.split("/")[1]
            name = re.sub(r'[-_]', ' ', name).title()
            owner = repo.split("/")[0]

            all_skills.append({
                "id": skill_id,
                "source": "github",
                "name": name,
                "description": description,
                "source_url": f"https://github.com/{repo}",
                "install_type": "skill",
                "author": owner,
            })
            added_3 += 1

        print(f"  Added {added_3} new skills")

        # --- Source 4: MCP servers ---
        print()
        print("=== Source: GitHub MCP servers ===")
        mcp_repos = search_github_mcp_servers()
        print(f"  Found {len(mcp_repos)} repos")
        added_4 = 0

        for repo_info in mcp_repos:
            repo = repo_info["repo"]
            skill_id = f"github:{repo}"
            if skill_id in seen_ids:
                continue
            seen_ids.add(skill_id)

            description = repo_info.get("description") or ""
            if not description:
                description = f"MCP server from {repo}"

            name = repo.split("/")[1]
            name = re.sub(r'[-_]', ' ', name).title()
            owner = repo.split("/")[0]

            # Determine if hosted or local based on name/description hints
            text_lower = f"{name} {description}".lower()
            if any(w in text_lower for w in ["hosted", "cloud", "saas", "api"]):
                install_type = "mcp-hosted"
            else:
                install_type = "mcp-local"

            all_skills.append({
                "id": skill_id,
                "source": "github",
                "name": name,
                "description": description,
                "source_url": f"https://github.com/{repo}",
                "install_type": install_type,
                "author": owner,
            })
            added_4 += 1

        print(f"  Added {added_4} new MCP servers")

        # --- Source 5: APM packages ---
        print()
        print("=== Source: GitHub APM packages ===")
        apm_repos = search_github_apm_packages()
        print(f"  Found {len(apm_repos)} repos with apm.yml")
        added_5 = 0

        for repo_info in apm_repos:
            repo = repo_info["repo"]
            skill_id = f"github:{repo}"
            if skill_id in seen_ids:
                continue
            seen_ids.add(skill_id)

            repo_data = gh_api(f"repos/{repo}")
            description = ""
            if repo_data:
                description = repo_data.get("description") or ""
            if not description:
                description = f"APM package from {repo}"

            name = repo.split("/")[1]
            name = re.sub(r'[-_]', ' ', name).title()
            owner = repo.split("/")[0]

            all_skills.append({
                "id": skill_id,
                "source": "github",
                "name": name,
                "description": description,
                "source_url": f"https://github.com/{repo}",
                "install_type": "skill",
                "author": owner,
            })
            added_5 += 1

        print(f"  Added {added_5} new APM packages")

        # --- Source 6: Other awesome-claude lists ---
        print()
        print("=== Source: Other awesome-claude lists ===")
        other_lists = search_other_awesome_lists()
        print(f"  Found {len(other_lists)} other awesome lists")
        added_6 = 0

        for list_repo in other_lists:
            readme_data = gh_api(f"repos/{list_repo}/readme")
            if not readme_data or "content" not in readme_data:
                print(f"  Skipping {list_repo} (no README)")
                continue

            import base64
            readme_text = base64.b64decode(readme_data["content"]).decode("utf-8")
            parsed = parse_awesome_readme(readme_text)
            print(f"  Parsed {len(parsed)} entries from {list_repo}")

            for skill in parsed:
                if skill["id"] in seen_ids:
                    continue
                seen_ids.add(skill["id"])
                skill["source"] = f"awesome-list:{list_repo}"
                all_skills.append(skill)
                added_6 += 1

            time.sleep(1)

        print(f"  Added {added_6} new skills from other lists")

        # --- Source 7: Anthropic official repos ---
        print()
        print("=== Source: Anthropic official repos ===")
        anthropic_repos = search_anthropic_repos()
        print(f"  Found {len(anthropic_repos)} repos in anthropics org")
        added_7 = 0

        for repo_info in anthropic_repos:
            repo = repo_info.get("fullName", "")
            if not repo:
                continue
            skill_id = f"github:{repo}"
            if skill_id in seen_ids:
                continue
            seen_ids.add(skill_id)

            description = repo_info.get("description") or ""
            if not description:
                description = f"Official Anthropic tool from {repo}"

            name = repo.split("/")[1]
            name = re.sub(r'[-_]', ' ', name).title()

            # Classify: MCP servers vs skills vs skip
            name_lower = name.lower()
            desc_lower = description.lower()
            if "mcp" in name_lower or "mcp" in desc_lower:
                install_type = "mcp-local"
            elif any(w in desc_lower for w in ["sdk", "library", "client"]):
                install_type = "skill"
            else:
                install_type = "skill"

            all_skills.append({
                "id": skill_id,
                "source": "anthropic",
                "name": name,
                "description": description,
                "source_url": f"https://github.com/{repo}",
                "install_type": install_type,
                "author": "anthropics",
            })
            added_7 += 1

        print(f"  Added {added_7} new Anthropic repos")

        print()
        print(f"=== Total unique skills: {len(all_skills)} ===")
        print()

        # --- Enrich and insert ---
        print("=== Processing skills ===")
        inserted = 0
        skipped = 0
        failed = 0

        for i, skill in enumerate(all_skills):
            skill_id = skill["id"]
            owner_repo = skill_id.replace("github:", "")

            # Check existence
            if args.apply and skill_exists(skill_id, args.api):
                print(f"  [{i+1}/{len(all_skills)}] SKIP {skill_id} (exists)")
                skipped += 1
                continue

            # Try to fetch SKILL.md
            content = fetch_skillmd(owner_repo)
            if content:
                skill["content"] = content
                skill["version_hash"] = sha256_short(content)
            else:
                skill["version_hash"] = sha256_short(skill["description"])

            # Build tags
            tags = infer_tags(skill["name"], skill["description"])
            skill["metadata"] = {"tags": tags, "author": skill.pop("author", "")}

            if args.apply:
                print(f"  [{i+1}/{len(all_skills)}] INSERT {skill_id}: {skill['name']}")
                if insert_via_wrangler(skill, tmpdir):
                    inserted += 1
                else:
                    failed += 1
                # Rate limit
                time.sleep(0.3)
            else:
                has_content = "+" if content else "-"
                print(f"  [{i+1}/{len(all_skills)}] [{has_content}] {skill_id}: {skill['name']}")
                inserted += 1

        print()
        print("=== Summary ===")
        print(f"  {'Would insert' if not args.apply else 'Inserted'}: {inserted}")
        print(f"  Skipped (exists): {skipped}")
        if args.apply:
            print(f"  Failed: {failed}")


if __name__ == "__main__":
    main()
