#!/usr/bin/env python3
"""Submit a single review to the Clarmory API."""

import json, base64, subprocess, sys, os
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

with open(os.path.expanduser('~/.claude/clarmory/identity.json')) as f:
    identity = json.load(f)
priv_bytes = base64.b64decode(identity['private_key'])
private_key = Ed25519PrivateKey.from_private_bytes(priv_bytes)
pub_b64 = identity['public_key']

def submit(skill_id, version_hash, security_ok, quality_rating, summary, findings, suggested_improvements):
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
    # Read review data from stdin as JSON
    data = json.load(sys.stdin)
    result = submit(**data)
    print(result)
