#!/bin/bash
# Create a synthetic one-page ZIM PDF larger than the buffered reader limit.
set -euo pipefail
destination=${1:?Pass an output ZIM path}
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work/large.pdf" <<'PY'
import sys

stream = b"BT /F1 18 Tf 50 600 Td (Large offline PDF fixture) Tj ET\n" + b" " * (33 * 1024 * 1024)
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
    b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"\nendstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
with open(sys.argv[1], "wb") as output:
    output.write(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(output.tell())
        output.write(f"{number} 0 obj\n".encode() + body + b"\nendobj\n")
    xref = output.tell()
    output.write(b"xref\n0 6\n0000000000 65535 f \n")
    for offset in offsets:
        output.write(f"{offset:010} 00000 n \n".encode())
    output.write(f"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
PY
cat > "$work/main.rs" <<'RS'
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    let pdf = std::fs::read(args.next().expect("PDF path"))?;
    let output = args.next().expect("ZIM path");
    let mut archive = zimru::writer::Creator::new();
    archive.set_compression(zimru::Compression::None);
    archive.try_add_item(zimru::writer::Item::new(
        "large.pdf", "Large offline PDF fixture", "application/pdf", pdf,
    ))?;
    archive.write_to(output)?;
    Ok(())
}
RS
cargo build --manifest-path .build/zimru/Cargo.toml --locked --release --lib --target-dir .build/zimru-host
rustc --edition=2021 "$work/main.rs" --extern zimru=.build/zimru-host/release/libzimru.rlib \
    -L dependency=.build/zimru-host/release/deps -o "$work/bundle"
"$work/bundle" "$work/large.pdf" "$destination"
