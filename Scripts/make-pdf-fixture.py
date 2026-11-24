"""Write the source folder for the PDF collection test archive.

Usage: python3 -I Scripts/make-pdf-fixture.py OUTPUT_DIR

Then pack it with zimru's zimwriterfs, as Scripts/make-pdf-fixture.sh does.
"""

import struct
import sys
import zlib
from pathlib import Path


def pdf(pages):
    """A PDF that draws each page's lines in Helvetica."""
    page_refs = " ".join(f"{4 + index * 2} 0 R" for index in range(len(pages)))
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Kids [{page_refs}] /Count {len(pages)} >>".encode(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    for index, lines in enumerate(pages):
        text = "BT /F1 14 Tf 72 720 Td 18 TL " + " ".join(
            "(" + line.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)") + ") '"
            for line in lines
        ) + " ET"
        stream = text.encode("latin-1")
        objects.extend([
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            b"/Resources << /Font << /F1 3 0 R >> >> /Contents %d 0 R >>" % (5 + index * 2),
            b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        ])
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)


def png(size=48):
    """A plain grey square, as zimwriterfs requires an illustration."""
    raw = b"".join(b"\x00" + b"\x80\x80\x80" * size for _ in range(size))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def main():
    root = Path(sys.argv[1])
    (root / "files").mkdir(parents=True, exist_ok=True)
    (root / "index.html").write_text(
        "<!doctype html><html><head><title>Fixture manuals</title></head>"
        "<body><h1>Fixture manuals</h1><p>Two offline documents.</p>"
        '<a href="files/Water Guide.pdf">Water guide</a></body></html>'
    )
    (root / "files" / "Water Guide.pdf").write_bytes(pdf([
        ["Boil water for one minute before drinking."],
        ["Ceramic filtration removes protozoa."],
    ]))
    (root / "files" / "Knots.pdf").write_bytes(pdf([["Tie a bowline to make a fixed loop."]]))
    (root / "illustration.png").write_bytes(png())


if __name__ == "__main__":
    main()
