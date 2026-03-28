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

import os
import sys
import urllib3
from pathlib import Path

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HOST   = os.environ["DA_HOST"]
USER   = os.environ["DA_USER"]
KEY    = os.environ["DA_KEY"]
DOMAIN = os.environ["DA_DOMAIN"]

REMOTE_ROOT = f"/home/{USER}/domains/{DOMAIN}/public_html"
LOCAL_ROOT  = Path("site")

http = urllib3.PoolManager(cert_reqs="CERT_NONE")

# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------

def upload(local_path: Path, remote_dir: str) -> int:
    url = f"https://{HOST}:2222/api/files?path={remote_dir}"
    with open(local_path, "rb") as f:
        resp = http.request(
            "POST",
            url,
            headers={"Authorization": urllib3.make_headers(basic_auth=f"{USER}:{KEY}")["authorization"]},
            fields={"file": (local_path.name, f.read(), "application/octet-stream")},
        )
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
        remote_dir = f"{REMOTE_ROOT}/{relative.parent.as_posix()}".rstrip("/.")
        try:
            status = upload(local, remote_dir)
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
