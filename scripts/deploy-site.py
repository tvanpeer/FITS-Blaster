#!/usr/bin/env python3
"""
deploy-site.py

Uploads all files in site/ to DirectAdmin hosting via the Evolution REST API.
Uses only Python stdlib — no third-party packages required.

Usage (environment variables must be set):
    DA_HOST    — DirectAdmin hostname, e.g. h58.mijn.host
    DA_USER    — DirectAdmin username
    DA_KEY     — DirectAdmin Login Key
    DA_DOMAIN  — Domain to deploy to, e.g. astrophoto-app.com
"""

import base64
import http.client
import os
import ssl
import sys
import uuid
import urllib.parse
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HOST   = os.environ["DA_HOST"]
USER   = os.environ["DA_USER"]
KEY    = os.environ["DA_KEY"]
DOMAIN = os.environ["DA_DOMAIN"]

REMOTE_ROOT = f"domains/{DOMAIN}/public_html"
LOCAL_ROOT  = Path("site")

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

AUTH = "Basic " + base64.b64encode(f"{USER}:{KEY}".encode()).decode()

# ---------------------------------------------------------------------------
# Multipart encoding
# ---------------------------------------------------------------------------

def build_multipart(filename: str, data: bytes) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: application/octet-stream\r\n"
        f"\r\n"
    ).encode() + data + f"\r\n--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"

# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------

def upload(local_path: Path, remote_dir: str) -> int:
    body, content_type = build_multipart(local_path.name, local_path.read_bytes())
    path = (
        f"/api/filemanager-actions/upload"
        f"?dir={urllib.parse.quote(remote_dir)}"
        f"&overwrite=true"
    )

    conn = http.client.HTTPSConnection(HOST, 2222, context=SSL_CTX)
    conn.request("POST", path, body, {
        "Authorization": AUTH,
        "Content-Type": content_type,
        "Content-Length": str(len(body)),
    })
    resp = conn.getresponse()
    resp.read()  # drain
    return resp.status

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    files = sorted(f for f in LOCAL_ROOT.rglob("*") if f.is_file())

    if not files:
        print("No files found in site/")
        sys.exit(1)

    errors = 0
    for local in files:
        relative = local.relative_to(LOCAL_ROOT)
        remote_dir = f"{REMOTE_ROOT}/{relative.parent.as_posix()}".rstrip("/.")
        try:
            status = upload(local, remote_dir)
            ok = status in (200, 204)
            print(f"  {'OK ' if ok else status}  {relative}")
            if not ok:
                errors += 1
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
