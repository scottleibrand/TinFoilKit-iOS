"""Collect the license notices for the Rust code linked into the app."""

import json
import sys
from pathlib import Path


def notice_files(package):
    root = Path(package["manifest_path"]).parent
    return sorted(
        path
        for path in root.iterdir()
        if path.is_file() and path.name.lower().startswith(("license", "copying", "notice"))
    )


def main():
    packages = json.load(sys.stdin)["packages"]
    crc = next(package for package in packages if package["name"] == "crc")
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    for package in packages:
        name, version = package["name"], package["version"]
        if name == "tfk-reader":
            continue
        files = notice_files(crc if name == "crc-catalog" else package)
        if not files:
            raise SystemExit(f"Missing license notices for {name} {version}")
        blocks = [f"{name} {version} ({package['license']})"]
        blocks.extend(f"{file.name}\n\n{file.read_text(encoding='utf-8')}" for file in files)
        (output / f"{name}-{version}.txt").write_text("\n\n".join(blocks), encoding="utf-8")


if __name__ == "__main__":
    main()
