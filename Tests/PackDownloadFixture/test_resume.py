#!/usr/bin/env python3
"""Exercise URLSession resume against an interrupted, byte-range HTTP transfer on macOS."""

import http.server
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading


BODY = bytes(range(256)) * 8192
CUT = len(BODY) // 2
ETAG = '"pack-fixture-v1"'


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path != "/sample.zim":
            self.send_error(404)
            return
        byte_range = self.headers.get("Range")
        if byte_range is not None:
            match = re.fullmatch(r"bytes=(\d+)-", byte_range)
            if match is None or not 0 < int(match[1]) < len(BODY):
                self.send_error(416)
                return
            if self.headers.get("If-Range") != ETAG:
                self.send_error(412)
                return
            start = int(match[1])
            self.server.offsets.append(start)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{len(BODY) - 1}/{len(BODY)}")
        else:
            start = 0
            self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", ETAG)
        self.send_header("Content-Length", str(len(BODY) - start))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(BODY[start:] if byte_range else BODY[:CUT])
        self.wfile.flush()
        if not byte_range:
            # End the first response before its advertised length. Repeat on any full retry.
            self.connection.shutdown(socket.SHUT_RDWR)
        self.close_connection = True


def main():
    with tempfile.TemporaryDirectory(prefix="tfk-resume-") as work:
        root = Path(work)
        client = root / "verify-resume"
        (root / "expected").write_bytes(BODY)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", root / "module-cache", "-o", client,
                        Path(__file__).with_name("VerifyResume.swift")], check=True, timeout=60)
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            server.offsets = []
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}/sample.zim"
                subprocess.run([client, url, root], check=True, timeout=30, cwd=root)
                if not server.offsets:
                    raise RuntimeError("The client never requested a nonzero byte range")
                print(f"ETag-validated range offsets served: {server.offsets}")
            finally:
                server.shutdown()
                worker.join()


if __name__ == "__main__":
    main()
