#!/bin/bash
set -euo pipefail
python3 - "${1:?Usage: verify-architectures.sh path/to/InfraProxy.app}" <<'PY'
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
assert root.is_dir(), f"Missing bundle: {root}"
magic = {bytes.fromhex(x) for x in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
checked = set()
for path in root.rglob("*"):
    if not path.is_file() or path.resolve() in checked:
        continue
    with path.open("rb") as stream:
        if stream.read(4) not in magic:
            continue
    architectures = set(subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split())
    assert {"arm64", "x86_64"} <= architectures, f"Missing Universal 2 slice: {path}: {architectures}"
    checked.add(path.resolve())
assert (root / "Contents/MacOS/InfraProxy").resolve() in checked
print(f"PASS: all {len(checked)} bundled Mach-O binaries contain arm64 and x86_64")
PY
