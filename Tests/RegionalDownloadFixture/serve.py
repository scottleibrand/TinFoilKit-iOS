"""Serve a synthetic regional bundle and interrupt its first place-index transfer."""

import argparse
import hashlib
import http.server
import json
from pathlib import Path
import socket
import ssl
import time

offset = 8192
validator = '"tfk-regional-fixture-v1"'


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    interrupted = False

    def do_GET(self):
        name = self.path.removeprefix("/bundle/")
        if name == "manifest.json":
            payload = self.server.manifest
        elif name in {"basemap.pmtiles", "places.sqlite", "routing.tfkroute"}:
            payload = (self.server.bundle / name).read_bytes()
        else:
            self.send_error(404)
            return

        status = 200
        start = 0
        interrupt = name == "places.sqlite" and not Handler.interrupted
        if name == "places.sqlite" and Handler.interrupted:
            if self.headers.get("Range") != f"bytes={offset}-" or self.headers.get("If-Range") != validator:
                self.send_error(412)
                return
            status = 206
            start = offset
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload) - start))
        self.send_header("ETag", validator)
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{len(payload) - 1}/{len(payload)}")
        self.end_headers()
        if interrupt:
            Handler.interrupted = True
            self.wfile.write(payload[:offset])
            self.wfile.flush()
            time.sleep(0.25)
            self.connection.shutdown(socket.SHUT_RDWR)
            self.close_connection = True
            print(f"Disconnected after {offset} bytes", flush=True)
        else:
            self.wfile.write(payload[start:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("certificate", type=Path)
    parser.add_argument("key", type=Path)
    parser.add_argument("configuration", type=Path)
    args = parser.parse_args()
    if (args.bundle / "places.sqlite").stat().st_size <= offset:
        parser.error("places.sqlite must exceed the interruption offset")

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.certificate, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.bundle = args.bundle
        base = f"https://127.0.0.1:{server.server_port}/bundle/"
        manifest = json.loads((args.bundle / "manifest.json").read_bytes())
        manifest["artifactBaseURL"] = base
        for asset in manifest["assets"].values():
            asset["url"] = base + asset["filename"]
        server.manifest = json.dumps(manifest).encode()
        args.configuration.write_text(json.dumps({
            "url": base + "manifest.json",
            "sha256": hashlib.sha256(server.manifest).hexdigest(),
            "interruptedBytes": offset,
        }))
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
