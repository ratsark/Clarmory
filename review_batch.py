#!/usr/bin/env python3
"""Batch skill reviewer for Clarmory. Fetches skill details, source code, and submits reviews."""

import json, base64, subprocess, sys, os, time, urllib.parse

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

# Load identity
with open(os.path.expanduser('~/.claude/clarmory/identity.json')) as f:
    identity = json.load(f)
priv_bytes = base64.b64decode(identity['private_key'])
private_key = Ed25519PrivateKey.from_private_bytes(priv_bytes)
pub_b64 = identity['public_key']

def curl_get(url):
    """Fetch URL via curl, return string."""
    r = subprocess.run(['curl', '-s', '-L', '--max-time', '15', url], capture_output=True, text=True)
    return r.stdout

def get_skill(skill_id):
    """Fetch skill details from API."""
    encoded = urllib.parse.quote(skill_id, safe='')
    data = curl_get(f'https://api.clarmory.com/skills/{encoded}')
    try:
        return json.loads(data)
    except:
        return None

def fetch_source(source_url):
    """Fetch source code from GitHub. Returns dict of filename->content."""
    if not source_url or 'github.com' not in source_url:
        return None

    # Parse GitHub URL to get owner/repo
    parts = source_url.rstrip('/').split('github.com/')[-1].split('/')
    if len(parts) < 2:
        return None
    owner, repo = parts[0], parts[1]

    files = {}

    # Try common skill file locations
    for path in [
        'CLAUDE.md', 'claude.md', '.claude/commands', 'README.md',
        'src/index.ts', 'src/index.js', 'index.ts', 'index.js',
        'main.py', 'server.py', 'src/server.ts', 'src/main.ts',
        'package.json', 'pyproject.toml', 'Cargo.toml',
        'SKILL.md', 'skill.md',
    ]:
        url = f'https://raw.githubusercontent.com/{owner}/{repo}/main/{path}'
        content = curl_get(url)
        if content and '404: Not Found' not in content and len(content) > 10:
            files[path] = content[:5000]  # Cap at 5KB per file
            continue
        # Try master branch
        url2 = f'https://raw.githubusercontent.com/{owner}/{repo}/master/{path}'
        content = curl_get(url2)
        if content and '404: Not Found' not in content and len(content) > 10:
            files[path] = content[:5000]

    return files if files else None

def submit_review(skill_id, version_hash, security_ok, quality_rating, summary, findings, suggested_improvements):
    """Submit a review to the API."""
    body = json.dumps({
        "agent_id": "clarmory-reviewer",
        "extension_id": skill_id,
        "version_hash": version_hash,
        "stage": "code_review",
        "security_ok": security_ok,
        "quality_rating": quality_rating,
        "model": "claude-opus-4-6",
        "summary": summary,
        "findings": findings,
        "suggested_improvements": suggested_improvements
    })

    signature = private_key.sign(body.encode())
    sig_b64 = base64.b64encode(signature).decode()

    r = subprocess.run(['curl', '-s', '-X', 'POST', 'https://api.clarmory.com/reviews',
        '-H', 'Content-Type: application/json',
        '-H', f'X-Clarmory-Public-Key: {pub_b64}',
        '-H', f'X-Clarmory-Signature: {sig_b64}',
        '-d', body], capture_output=True, text=True)
    return r.stdout

if __name__ == '__main__':
    skill_id = sys.argv[1]
    skill = get_skill(skill_id)
    if not skill:
        print(f"FAILED to fetch skill: {skill_id}")
        sys.exit(1)

    print(f"=== {skill.get('name', skill_id)} ===")
    print(f"Source: {skill.get('source', 'unknown')}")
    print(f"URL: {skill.get('source_url', 'none')}")
    print(f"Description: {skill.get('description', 'none')}")
    print(f"Version: {skill.get('version_hash', 'none')}")
    print(f"Reviews: {skill.get('reviews', {}).get('total', 0)}")

    source = fetch_source(skill.get('source_url', ''))
    if source:
        print(f"\nFetched {len(source)} source files: {list(source.keys())}")
        for fname, content in source.items():
            print(f"\n--- {fname} ---")
            print(content[:2000])
    else:
        print("\nCould not fetch source files")

    print(f"\n=== END {skill_id} ===")
