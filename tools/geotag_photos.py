#!/usr/bin/env python3
"""CLI for WatchGPSBridge photo timezone correction + GPS geotag.

Prefer the GUI on Mac:

  python tools/geotag_app.py

CLI example:

  python tools/geotag_photos.py \\
    --tracks ~/Library/Mobile\\ Documents/iCloud~com~invisibleworkshop~watchgpsbridge/Documents/Tracks \\
    --photos ~/Pictures/Trip \\
    --source-tz GMT+8 \\
    --target-tz GMT+9 \\
    --mode retag \\
    --write
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from geotag_lib import (  # noqa: E402
    COMMON_TIMEZONES,
    default_tracks_dir,
    parse_gmt_label,
    process_photos,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="修正照片時區並寫入 EXIF GPS（精確定位軌跡）"
    )
    parser.add_argument("--tracks", type=Path, default=default_tracks_dir())
    parser.add_argument("--photos", type=Path, required=True)
    parser.add_argument("--source-tz", default="GMT+8", help="原時區，例 GMT+8")
    parser.add_argument("--target-tz", default="GMT+9", help="目標時區，例 GMT+9")
    parser.add_argument(
        "--mode",
        choices=("retag", "convert"),
        default="retag",
        help="retag=保持牆上時間改時區；convert=同一瞬間換算",
    )
    parser.add_argument("--max-delta-seconds", type=int, default=300)
    parser.add_argument("--recursive", action="store_true")
    parser.add_argument("--write", action="store_true")
    parser.add_argument(
        "--allow-without-gps",
        action="store_true",
        help="對不到 GPS 時仍只改時區",
    )
    parser.add_argument("--list-timezones", action="store_true")
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    if args.list_timezones:
        for zone in COMMON_TIMEZONES:
            print(f"{zone.label}\t{zone.exif_offset_bytes.decode()}")
        return 0

    if not args.tracks.exists():
        print(f"找不到軌跡資料夾：{args.tracks}", file=sys.stderr)
        return 1
    if not args.photos.exists():
        print(f"找不到照片資料夾：{args.photos}", file=sys.stderr)
        return 1

    result = process_photos(
        tracks_dir=args.tracks,
        photos_dir=args.photos,
        target_tz=parse_gmt_label(args.target_tz),
        source_tz=parse_gmt_label(args.source_tz),
        mode=args.mode,
        max_delta_seconds=args.max_delta_seconds,
        recursive=args.recursive,
        write=args.write,
        require_gps=not args.allow_without_gps,
        log=print,
    )
    if not args.write:
        print("（dry-run，未寫入。加上 --write 才會修改照片）")
    return 0 if result.failed == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
