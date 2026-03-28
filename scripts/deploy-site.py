#!/usr/bin/env python3
"""
deploy-site.py

Uploads all files in site/ to DirectAdmin hosting via the Evolution REST API.

Usage (environment variables must be set):
    DA_HOST    — DirectAdmin hostname, e.g. h58.mijn.host
    DA_USER    — DirectAdmin username
    DA_KEY     — DirectAdmin Login Key
    DA_DOMAIN  — Domain to deploy to, e.g. astrophoto-app.com
"""

import base64
import os
import ssl
import sys
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HOST   = os.environ["DA_HOST"]
USER   = os.environ["DA_USER"]
KEY    = os.environ["DA_KEY"]
DOMAIN = os.environ["DA_DOMAIN"]

REMOTE_ROOT = f"/home/{USER}/domains/{DOMAIN}/public_html"
LOCAL_ROOT  = Path("site")

# DirectAdmin port 2222 uses a self-signed certificate — skip verification.
SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

CREDENTIALS = base64.b64encode(f"{USER}:{KEY}".encode()).decode()

# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------

def upload(local_path: Path, remote_path: str) -> int:
    url = f"https://{HOST}:2222/api/files?path={remote_path}"
    data = local_path.read_bytes()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Basic {CREDENTIALS}",
            "Content-Type": "application/octet-stream",
        },
        method="PUT",
    )
    with urllib.request.urlopen(req, context=SSL_CTX) as resp:
        return resp.status


def main():
    files = sorted(LOCAL_ROOT.rglob("*"))
    files = [f for f in files if f.is_file()]

    if not files:
        print("No files found in site/")
        sys.exit(1)

    errors = 0
    for local in files:
        relative = local.relative_to(LOCAL_ROOT)
        remote = f"{REMOTE_ROOT}/{relative.as_posix()}"
        try:
            status = upload(local, remote)
            print(f"  {status}  {relative}")
        except Exception as e:
            print(f"  ERR  {relative}  —  {e}")
            errors += 1

    if errors:
        print(f"\n{errors} file(s) failed to upload.")
        sys.exit(1)
    else:
        print(f"\nAll {len(files)} file(s) uploaded successfully.")


if __name__ == "__main__":
    main()
