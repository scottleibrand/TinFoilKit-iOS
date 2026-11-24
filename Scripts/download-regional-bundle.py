#!/usr/bin/env python3
"""Download a pinned regional manifest and resume its assets into a Files-importable folder."""

import argparse
import fcntl
import hashlib
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


MANIFEST_LIMIT = 65_536
CHUNK_SIZE = 1024 * 1024
VERIFIER = Path(__file__).with_name("build-regional-bundle.py")
ASSETS = {"places": "places.sqlite", "routing": "routing.tfkroute"}


def valid_https(url):
    if not isinstance(url, str) or any(character.isspace() for character in url):
        return False
    parsed = urlsplit(url)
    return parsed.scheme == "https" and parsed.hostname and parsed.username is None and not parsed.fragment


class HTTPSRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        if not valid_https(url):
            raise ValueError("Regional bundle redirects must use HTTPS without credentials.")
        return super().redirect_request(request, response, code, message, headers, url)


def asset_list(manifest):
    base = manifest["artifactBaseURL"]
    if not valid_https(base) or urlsplit(base).query:
        raise ValueError("Invalid regional artifact base URL.")
    version = manifest["schemaVersion"]
    if type(version) is not int or version not in (1, 2):
        raise ValueError("Unsupported regional bundle manifest version.")
    filenames = ASSETS if version == 1 else dict(ASSETS, basemap="basemap.pmtiles")
    assets = manifest["assets"]
    if not isinstance(assets, dict) or set(assets) != set(filenames):
        raise ValueError("Unexpected regional bundle assets.")
    for kind, name in filenames.items():
        item = assets[kind]
        url = base.rstrip("/") + "/" + name
        count = item["byteCount"]
        digest = item["sha256"]
        if (item["filename"] != name or item["url"] != url
                or type(count) is not int or not 0 < count < 2**63
                or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise ValueError(f"Invalid metadata for {name}.")
        yield name, url, count, digest


def checked_size(file):
    if file.is_symlink() or (file.exists() and not file.is_file()):
        raise ValueError(f"Expected a regular checkpoint file named {file.name}.")
    return file.stat().st_size if file.exists() else 0


def download_asset(opener, directory, name, url, count, digest):
    file = directory / name
    offset = checked_size(file)
    if offset > count:
        file.unlink()
        offset = 0
    if offset < count:
        request = Request(url, headers={"Accept-Encoding": "identity", "Range": f"bytes={offset}-{count - 1}"})
        with opener.open(request, timeout=30) as response:
            if response.headers.get("Content-Encoding", "identity").lower() != "identity":
                raise ValueError(f"Unexpected HTTP content encoding for {name}.")
            if response.status == 206:
                if response.headers.get("Content-Range") != f"bytes {offset}-{count - 1}/{count}":
                    raise ValueError(f"Unexpected HTTP range for {name}.")
            elif response.status == 200:
                offset = 0
            else:
                raise ValueError(f"Unexpected HTTP status for {name}.")
            remaining = count - offset
            with file.open("ab" if offset else "wb") as output:
                while remaining:
                    chunk = response.read1(min(CHUNK_SIZE, remaining))
                    if not chunk:
                        raise ValueError(f"Download interrupted for {name}. Run the same command to resume.")
                    output.write(chunk)
                    remaining -= len(chunk)
                if response.read(1):
                    file.unlink()
                    raise ValueError(f"Download exceeds the pinned size for {name}.")
                output.flush()
                os.fsync(output.fileno())
    with file.open("rb") as stream:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: stream.read(CHUNK_SIZE), b""):
            checksum.update(chunk)
    if checksum.hexdigest() != digest:
        file.unlink()
        raise ValueError(f"Checksum mismatch for {name}. Its checkpoint was cleared.")


def download(opener, manifest_url, manifest_sha256, output):
    if not valid_https(manifest_url) or not re.fullmatch(r"[0-9a-f]{64}", manifest_sha256):
        raise ValueError("Provide an HTTPS manifest URL and a lowercase SHA-256 pin.")
    if output.exists() or output.is_symlink():
        raise ValueError("Choose a new destination folder.")
    with opener.open(Request(manifest_url, headers={"Accept-Encoding": "identity"}), timeout=30) as response:
        if response.status != 200:
            raise ValueError("The regional manifest request failed.")
        raw = response.read(MANIFEST_LIMIT + 1)
    if len(raw) > MANIFEST_LIMIT or hashlib.sha256(raw).hexdigest() != manifest_sha256:
        raise ValueError("The regional manifest does not match its SHA-256 pin.")
    assets = list(asset_list(json.loads(raw)))
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.with_name(f".{output.name}.{manifest_sha256}.partial")
    staging.mkdir(mode=0o700, exist_ok=True)
    descriptor = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if output.exists() or output.is_symlink():
            raise ValueError("The destination folder already exists.")
        manifest_file = staging / "manifest.json"
        checked_size(manifest_file)
        manifest_file.write_bytes(raw)
        required = sum(max(0, count - checked_size(staging / name)) for name, _, count, _ in assets)
        if required > shutil.disk_usage(staging).free:
            raise ValueError("Free up storage for the regional bundle and retry.")
        for name, url, count, digest in assets:
            download_asset(opener, staging, name, url, count, digest)
        subprocess.run([sys.executable, VERIFIER, "verify", staging], check=True)
        if output.exists() or output.is_symlink():
            raise ValueError("The destination folder already exists.")
        staging.rename(output)
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest_url")
    parser.add_argument("manifest_sha256", help="SHA-256 from the trusted regional catalog")
    parser.add_argument("directory", type=Path, help="New destination folder for iOS Files import")
    args = parser.parse_args()
    try:
        download(build_opener(HTTPSRedirects()), args.manifest_url, args.manifest_sha256, args.directory.absolute())
    except (OSError, ValueError, KeyError, TypeError, HTTPException, subprocess.CalledProcessError) as error:
        print(f"Regional download failed: {error}", file=sys.stderr)
        return 1
    print(f"Downloaded verified regional bundle to {args.directory}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
