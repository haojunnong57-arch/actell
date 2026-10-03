#!/usr/bin/env python3
"""Verify imported source against the exact saved archives; no network/device access."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {
    "esp32-iphone-coredevice-protocol-v0.3.tar.gz":
        (362648, "79702eba413323c38610d1b714e99b85137cfe5a0a13446790af50f643637420"),
    "PhoneAgent-iOS-source.zip":
        (54367, "57922ed3703d6a0288e5a9dfb014440959d356fd16853faae68b3b9ce138e434"),
}


def check(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


def destination(name):
    parts = PurePosixPath(name).parts
    check(len(parts) > 1 and ".." not in parts and not name.startswith("/"), name)
    rel = PurePosixPath(*parts[1:]).as_posix()
    if parts[0] == "ios-agent-app":
        return "ios-app/" + rel
    check(parts[0] == "esp32-iphone-bridge", "unexpected archive root: " + name)
    return {"README.md": "README.firmware.md",
            "SOURCE_MANIFEST.json": "SOURCE_MANIFEST.firmware.json"}.get(rel, rel)


def main():
    manifest = json.loads((ROOT / "docs/import-manifest.json").read_text())
    rows = manifest["source_files"]
    indexed = {row["source"]: row for row in rows}
    check(len(indexed) == len(rows) == 190, "expected 190 unique source entries")
    checked = set()
    for name, (size, digest) in EXPECTED.items():
        archive = ROOT / "archives" / name
        data = archive.read_bytes()
        check(len(data) == size and hashlib.sha256(data).hexdigest() == digest,
              "archive size/hash: " + name)
        if name.endswith(".tar.gz"):
            with tarfile.open(archive) as handle:
                members = handle.getmembers()
                check(all(m.isfile() for m in members), "non-file archive member")
                entries = [(m.name, handle.extractfile(m).read()) for m in members]
        else:
            with zipfile.ZipFile(archive) as handle:
                entries = [(n, handle.read(n)) for n in handle.namelist()]
        for source, content in entries:
            check(source not in checked and source in indexed, "source entry: " + source)
            checked.add(source)
            relative = destination(source)
            row = indexed[source]
            check(row["path"] == relative, "path mapping: " + source)
            target = ROOT / relative
            check(target.is_file() and not target.is_symlink(), "missing/file type: " + relative)
            check(target.read_bytes() == content, "source bytes differ: " + relative)
            check(row["bytes"] == len(content) and row["sha256"] == hashlib.sha256(content).hexdigest(),
                  "import manifest: " + relative)
        print("PASS:", name, "size/hash and", len(entries), "imported files")
    check(checked == set(indexed), "unverified source entries")
    print("PASS: all 190 imported files are byte-identical to the two original archives")
    print("Scope: source integrity only; not a build, type-check, device or interoperability test")


if __name__ == "__main__":
    main()
