#!/usr/bin/env python3
"""Import real skills from upstream sources into the Clarmory D1 database.

Sources:
  1. awesome-claude-code (hesreallyhim/awesome-claude-code) — curated README
  2. GitHub code search — repos containing SKILL.md files

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
        "mcp": ["mcp", "model context protocol"],
        "research": ["research", "scientific", "academic"],
        "documentation": ["documentation", "docs", "readme"],
        "database": ["database", "sql", "postgres", "sqlite"],
        "agent": ["agent", "orchestrat", "swarm", "multi-agent"],
        "hooks": ["hook"],
        "commands": ["command", "slash-command", "slash command"],
        "framework": ["framework", "kit", "toolkit"],
        "monitoring": ["monitor", "usage", "analytics", "dashboard"],
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


def insert_via_wrangler(skill: dict, tmpdir: str) -> bool:
    """Insert a skill into remote D1 via wrangler d1 execute."""
    def sql_escape(s: str) -> str:
        if s is None:
            return "NULL"
        return "'" + s.replace("'", "''") + "'"

    content = skill.get("content")
    if content:
        sql = (
            f"INSERT OR IGNORE INTO skills "
            f"(id, source, name, description, version_hash, source_url, install_type, content, metadata) "
            f"VALUES ({sql_escape(skill['id'])}, {sql_escape(skill['source'])}, "
            f"{sql_escape(skill['name'])}, {sql_escape(skill['description'])}, "
            f"{sql_escape(skill['version_hash'])}, {sql_escape(skill['source_url'])}, "
            f"{sql_escape(skill['install_type'])}, {sql_escape(content)}, "
            f"{sql_escape(json.dumps(skill.get('metadata', {})))});"
        )
    else:
        sql = (
            f"INSERT OR IGNORE INTO skills "
            f"(id, source, name, description, version_hash, source_url, install_type, metadata) "
            f"VALUES ({sql_escape(skill['id'])}, {sql_escape(skill['source'])}, "
            f"{sql_escape(skill['name'])}, {sql_escape(skill['description'])}, "
            f"{sql_escape(skill['version_hash'])}, {sql_escape(skill['source_url'])}, "
            f"{sql_escape(skill['install_type'])}, "
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
