import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest


script = Path(__file__).resolve().parents[2] / "Scripts" / "build-regional-routing-pack.py"
spec = importlib.util.spec_from_file_location("routing_pack", script)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class RoutingPackTests(unittest.TestCase):
    def test_pack_matches_swift_wire_format(self):
        tile = b"route bytes"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            graph = root / "tiles.tar"
            output = root / "city.tfkroute"
            with tarfile.open(graph, "w") as archive:
                index = tarfile.TarInfo("index.bin")
                index.size = 16
                archive.addfile(index, io.BytesIO(struct.pack("<QII", 1536, (123 << 3) | 2, len(tile))))
                entry = tarfile.TarInfo("2/000/123.gph")
                entry.size = len(tile)
                archive.addfile(entry, io.BytesIO(tile))
            self.assertEqual(builder.validate_graph(graph), 1)
            metadata = {"schemaVersion": 1, "region": "São Paulo", "engineVersion": "3.9.2"}
            builder.write_pack(graph, output, metadata)

            data = output.read_bytes()
            magic, length = struct.unpack_from("<8sI", data)
            self.assertEqual(magic, b"TFKROUTE")
            manifest = json.loads(data[12:12 + length])
            graph_bytes = data[12 + length:]
            self.assertEqual(graph_bytes, graph.read_bytes())
            self.assertEqual(manifest, dict(metadata, graphSHA256=hashlib.sha256(graph_bytes).hexdigest(),
                                             graphByteCount=len(graph_bytes)))

    def test_rejects_wrong_tile_index(self):
        with tempfile.TemporaryDirectory() as directory:
            graph = Path(directory) / "tiles.tar"
            with tarfile.open(graph, "w") as archive:
                index = tarfile.TarInfo("index.bin")
                index.size = 16
                archive.addfile(index, io.BytesIO(struct.pack("<QII", 42, 0, 1)))
                entry = tarfile.TarInfo("2/000/123.gph")
                entry.size = 1
                archive.addfile(entry, io.BytesIO(b"X"))
            with self.assertRaisesRegex(ValueError, "does not match tile"):
                builder.validate_graph(graph)


if __name__ == "__main__":
    unittest.main()
