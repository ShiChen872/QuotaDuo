#!/usr/bin/env python3
"""Build Resources/AppIcon.icns from Resources/AppIcon-1024.png."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "Resources" / "AppIcon-1024.png"
ICONSET = ROOT / "Resources" / "AppIcon.iconset"
ICNS = ROOT / "Resources" / "AppIcon.icns"

SIZES = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16" + "@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32" + "@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128" + "@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256" + "@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512" + "@2x.png"),
]


def main() -> None:
    if not SRC.exists():
        raise SystemExit(f"missing {SRC}")
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)
    for size, name in SIZES:
        out = ICONSET / name
        subprocess.run(
            ["sips", "-s", "format", "png", "-z", str(size), str(size), str(SRC), "--out", str(out)],
            check=True,
            capture_output=True,
        )
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    shutil.rmtree(ICONSET)
    print(f"wrote {ICNS} ({ICNS.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
