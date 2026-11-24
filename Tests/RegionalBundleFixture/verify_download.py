"""Exercise the downloader using a synthetic bundle and a loopback HTTP server."""

from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import runpy
import threading
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


DOWNLOADER = Path(__file__).resolve().parents[2] / "Scripts/download-regional-bundle.py"
MANIFEST_URL = "https://example.invalid/bundles/fixture-v1/manifest.json"


@contextmanager
def publisher(bundle):
    attempts = []
    broken_ranges = set()
    corrupt_assets = set()
    ignore_ranges = set()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            name = self.path.rsplit("/", 1)[-1]
            payload = (bundle / name).read_bytes()
            if name == "manifest.json":
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            start, end = map(int, self.headers["Range"].removeprefix("bytes=").split("-"))
            assert end == len(payload) - 1
            attempts.append((name, start))
            if name in ignore_ranges:
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            self.send_response(206)
            range_start = start + 1 if name in broken_ranges else start
            self.send_header("Content-Range", f"bytes {range_start}-{end}/{len(payload)}")
            self.send_header("Content-Length", str(len(payload) - start))
            self.end_headers()
            if name == "routing.tfkroute" and start == 0 and attempts.count((name, 0)) == 1:
                self.wfile.write(payload[:512])
            elif name in corrupt_assets:
                self.wfile.write(bytes([payload[start] ^ 1]) + payload[start + 1:])
            else:
                self.wfile.write(payload[start:])

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        class LoopbackOpener:
            def open(self, request, *, timeout):
                url = f"http://127.0.0.1:{server.server_port}{urlsplit(request.full_url).path}"
                return urlopen(Request(url, headers=dict(request.header_items())), timeout=timeout)

        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            yield LoopbackOpener(), attempts, broken_ranges, corrupt_assets, ignore_ranges
        finally:
            server.shutdown()
            thread.join()


def expect_failure(action, message):
    try:
        action()
    except ValueError as error:
        assert message in str(error), error
    else:
        raise AssertionError(f"Expected failure: {message}")


def verify_download(bundle, output):
    download = runpy.run_path(DOWNLOADER)["download"]
    manifest_digest = hashlib.sha256((bundle / "manifest.json").read_bytes()).hexdigest()
    with publisher(bundle) as (opener, attempts, broken_ranges, corrupt_assets, ignore_ranges):
        def install():
            download(opener, MANIFEST_URL, manifest_digest, output)

        expect_failure(lambda: download(opener, MANIFEST_URL, "0" * 64, output), "manifest does not match")
        expect_failure(install, "Download interrupted for routing.tfkroute")
        assert not output.exists()
        assert attempts == [("places.sqlite", 0), ("routing.tfkroute", 0)]

        broken_ranges.add("routing.tfkroute")
        expect_failure(install, "Unexpected HTTP range")
        assert attempts[-1] == ("routing.tfkroute", 512)
        assert not output.exists()
        broken_ranges.clear()

        corrupt_assets.add("routing.tfkroute")
        expect_failure(install, "Checksum mismatch for routing.tfkroute")
        assert attempts[-1] == ("routing.tfkroute", 512)
        assert not output.exists()
        corrupt_assets.clear()

        install()
        assert [start for name, start in attempts if name == "routing.tfkroute"] == [0, 512, 512, 0]
        assert attempts.count(("places.sqlite", 0)) == 1
        assert sorted(file.name for file in output.iterdir()) == sorted(file.name for file in bundle.iterdir())
        for file in output.iterdir():
            assert file.read_bytes() == (bundle / file.name).read_bytes()

        restarted = output.with_name(f"{output.name}-restarted")
        staging = restarted.with_name(f".{restarted.name}.{manifest_digest}.partial")
        staging.mkdir()
        places = (bundle / "places.sqlite").read_bytes()
        (staging / "places.sqlite").write_bytes(places[:512])
        ignore_ranges.add("places.sqlite")
        download(opener, MANIFEST_URL, manifest_digest, restarted)
        assert ("places.sqlite", 512) in attempts
        assert (restarted / "places.sqlite").read_bytes() == places
