#!/usr/bin/env python3
"""Geotag photos from WatchGPSBridge track JSON files using EXIF timestamps.

Example (Mac, after iCloud sync):

  python3 -m venv .venv && source .venv/bin/activate
  pip install -r tools/requirements.txt

  python tools/geotag_photos.py \\
    --tracks ~/Library/Mobile\\ Documents/iCloud~com~watchgpsbridge~app/Documents/Tracks \\
    --photos ~/Pictures/Trip \\
    --max-delta-seconds 300 \\
    --write

Without --write the script only prints what it would do (dry-run).
"""

from __future__ import annotations

import argparse
import json
import sys
from bisect import bisect_left
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Tuple

try:
    import piexif
    from piexif import GPSIFD, ImageIFD
except ImportError:  # pragma: no cover
    print("請先安裝依賴：pip install -r tools/requirements.txt", file=sys.stderr)
    raise


PHOTO_SUFFIXES = {".jpg", ".jpeg", ".tif", ".tiff", ".heic", ".heif"}


@dataclass(frozen=True)
class TrackPoint:
    timestamp: datetime
    latitude: float
    longitude: float
    altitude: float
    horizontal_accuracy: float


def parse_iso8601(value: str) -> datetime:
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        # App writes ISO8601 with timezone; if missing, assume UTC.
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def load_tracks(tracks_dir: Path) -> List[TrackPoint]:
    files = sorted(tracks_dir.glob("*.json"))
    if not files:
        raise FileNotFoundError(f"在 {tracks_dir} 找不到 *.json 軌跡檔")

    points: List[TrackPoint] = []
    for path in files:
        with path.open("r", encoding="utf-8") as fh:
            payload = json.load(fh)

        raw_points = payload.get("points", payload if isinstance(payload, list) else [])
        for item in raw_points:
            try:
                points.append(
                    TrackPoint(
                        timestamp=parse_iso8601(item["timestamp"]),
                        latitude=float(item["latitude"]),
                        longitude=float(item["longitude"]),
                        altitude=float(item.get("altitude", 0.0)),
                        horizontal_accuracy=float(item.get("horizontalAccuracy", -1.0)),
                    )
                )
            except (KeyError, TypeError, ValueError) as exc:
                print(f"略過損壞點位 ({path.name}): {exc}", file=sys.stderr)

    points.sort(key=lambda p: p.timestamp)
    # Prefer more precise samples when timestamps collide.
    deduped: List[TrackPoint] = []
    for point in points:
        if deduped and deduped[-1].timestamp == point.timestamp:
            if (
                point.horizontal_accuracy >= 0
                and (
                    deduped[-1].horizontal_accuracy < 0
                    or point.horizontal_accuracy < deduped[-1].horizontal_accuracy
                )
            ):
                deduped[-1] = point
            continue
        deduped.append(point)
    return deduped


def iter_photos(photos_dir: Path, recursive: bool) -> Iterable[Path]:
    if recursive:
        candidates = photos_dir.rglob("*")
    else:
        candidates = photos_dir.glob("*")
    for path in candidates:
        if path.is_file() and path.suffix.lower() in PHOTO_SUFFIXES:
            yield path


def _rationally(number: float, precision: int = 100000) -> Tuple[int, int]:
    return int(abs(number) * precision), precision


def decimal_to_dms_rationals(decimal: float) -> Tuple[Tuple[int, int], Tuple[int, int], Tuple[int, int]]:
    negative = decimal < 0
    value = abs(decimal)
    degrees = int(value)
    minutes_full = (value - degrees) * 60
    minutes = int(minutes_full)
    seconds = (minutes_full - minutes) * 60
    _ = negative
    return ((degrees, 1), (minutes, 1), _rationally(seconds, 10000))


def build_gps_ifd(point: TrackPoint) -> dict:
    lat_ref = b"N" if point.latitude >= 0 else b"S"
    lon_ref = b"E" if point.longitude >= 0 else b"W"
    alt_ref = 0 if point.altitude >= 0 else 1
    return {
        GPSIFD.GPSVersionID: (2, 3, 0, 0),
        GPSIFD.GPSLatitudeRef: lat_ref,
        GPSIFD.GPSLatitude: decimal_to_dms_rationals(point.latitude),
        GPSIFD.GPSLongitudeRef: lon_ref,
        GPSIFD.GPSLongitude: decimal_to_dms_rationals(point.longitude),
        GPSIFD.GPSAltitudeRef: alt_ref,
        GPSIFD.GPSAltitude: _rationally(abs(point.altitude), 100),
        GPSIFD.GPSTimeStamp: (
            (point.timestamp.hour, 1),
            (point.timestamp.minute, 1),
            (point.timestamp.second, 1),
        ),
        GPSIFD.GPSDateStamp: point.timestamp.strftime("%Y:%m:%d").encode("ascii"),
    }


def read_photo_datetime(path: Path) -> Optional[datetime]:
    suffix = path.suffix.lower()
    if suffix in {".heic", ".heif"}:
        return read_heic_datetime(path)
    try:
        exif_dict = piexif.load(str(path))
    except Exception:
        return None

    for ifd_name in ("Exif", "0th"):
        ifd = exif_dict.get(ifd_name) or {}
        for tag in (ImageIFD.DateTime, piexif.ExifIFD.DateTimeOriginal, piexif.ExifIFD.DateTimeDigitized):
            raw = ifd.get(tag)
            if not raw:
                continue
            text = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else str(raw)
            dt = parse_exif_datetime(text, exif_dict)
            if dt:
                return dt
    return None


def parse_exif_datetime(text: str, exif_dict: dict) -> Optional[datetime]:
    text = text.strip()
    try:
        naive = datetime.strptime(text, "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None

    offset = None
    exif_ifd = exif_dict.get("Exif") or {}
    for tag in (piexif.ExifIFD.OffsetTimeOriginal, piexif.ExifIFD.OffsetTime, piexif.ExifIFD.OffsetTimeDigitized):
        raw = exif_ifd.get(tag)
        if not raw:
            continue
        value = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else str(raw)
        offset = parse_tz_offset(value)
        if offset is not None:
            break

    if offset is None:
        # Fall back to local timezone of the machine running the script.
        offset = datetime.now().astimezone().utcoffset() or timedelta(0)

    return naive.replace(tzinfo=timezone(offset)).astimezone(timezone.utc)


def parse_tz_offset(value: str) -> Optional[timedelta]:
    value = value.strip()
    if len(value) < 3 or value[0] not in "+-":
        return None
    sign = 1 if value[0] == "+" else -1
    try:
        hours = int(value[1:3])
        minutes = int(value[4:6]) if len(value) >= 6 and value[3] == ":" else 0
    except ValueError:
        return None
    return sign * timedelta(hours=hours, minutes=minutes)


def read_heic_datetime(path: Path) -> Optional[datetime]:
    try:
        from pillow_heif import register_heif_opener
        from PIL import Image
    except ImportError:
        print(
            f"略過 HEIC（未安裝 pillow-heif）：{path.name}。可改用 JPEG，或 pip install pillow-heif",
            file=sys.stderr,
        )
        return None

    register_heif_opener()
    try:
        with Image.open(path) as img:
            exif = img.getexif()
            if not exif:
                return None
            raw = exif.get(306) or exif.get(36867) or exif.get(36868)
            if not raw:
                return None
            # Rebuild a tiny dict so offset parsing can still work when present.
            exif_dict = {"Exif": {}, "0th": {ImageIFD.DateTime: str(raw).encode("utf-8")}}
            return parse_exif_datetime(str(raw), exif_dict)
    except Exception as exc:
        print(f"讀取 HEIC 時間失敗 {path.name}: {exc}", file=sys.stderr)
        return None


def nearest_point(
    points: Sequence[TrackPoint],
    when: datetime,
    max_delta: timedelta,
) -> Optional[Tuple[TrackPoint, timedelta]]:
    if not points:
        return None
    timestamps = [p.timestamp for p in points]
    idx = bisect_left(timestamps, when)
    candidates = []
    if idx < len(points):
        candidates.append(points[idx])
    if idx > 0:
        candidates.append(points[idx - 1])
    best = min(candidates, key=lambda p: abs(p.timestamp - when))
    delta = abs(best.timestamp - when)
    if delta > max_delta:
        return None
    return best, delta


def write_gps_jpeg(path: Path, point: TrackPoint) -> None:
    exif_dict = piexif.load(str(path))
    exif_dict["GPS"] = build_gps_ifd(point)
    raw = piexif.dump(exif_dict)
    piexif.insert(raw, str(path))


def write_gps_heic(path: Path, point: TrackPoint) -> None:
    """Best-effort HEIC write via pillow-heif; prefer converting to JPEG for reliability."""
    try:
        from pillow_heif import register_heif_opener
        from PIL import Image
    except ImportError as exc:
        raise RuntimeError("寫入 HEIC 需要 pillow-heif") from exc

    register_heif_opener()
    gps_bytes = piexif.dump({"GPS": build_gps_ifd(point), "0th": {}, "Exif": {}, "1st": {}, "thumbnail": None})
    with Image.open(path) as img:
        # pillow-heif may accept exif= on save depending on version.
        img.save(path, exif=gps_bytes)


def geotag(
    tracks_dir: Path,
    photos_dir: Path,
    max_delta_seconds: int,
    recursive: bool,
    write: bool,
) -> int:
    points = load_tracks(tracks_dir)
    if not points:
        print("軌跡檔沒有可用點位", file=sys.stderr)
        return 1

    print(
        f"已載入 {len(points)} 點 "
        f"（{points[0].timestamp.isoformat()} → {points[-1].timestamp.isoformat()}）"
    )
    max_delta = timedelta(seconds=max_delta_seconds)

    matched = skipped = failed = 0
    for photo in iter_photos(photos_dir, recursive=recursive):
        when = read_photo_datetime(photo)
        if when is None:
            print(f"[跳過] 無拍攝時間：{photo}")
            skipped += 1
            continue

        hit = nearest_point(points, when, max_delta)
        if hit is None:
            print(f"[跳過] 找不到 {max_delta_seconds}s 內的 GPS：{photo.name} @ {when.isoformat()}")
            skipped += 1
            continue

        point, delta = hit
        action = "寫入" if write else "預覽"
        print(
            f"[{action}] {photo.name} → "
            f"{point.latitude:.6f},{point.longitude:.6f} "
            f"(Δ{delta.total_seconds():.1f}s, ±{point.horizontal_accuracy:.1f}m)"
        )
        if not write:
            matched += 1
            continue

        try:
            suffix = photo.suffix.lower()
            if suffix in {".jpg", ".jpeg", ".tif", ".tiff"}:
                write_gps_jpeg(photo, point)
            elif suffix in {".heic", ".heif"}:
                write_gps_heic(photo, point)
            else:
                raise RuntimeError(f"不支援的副檔名：{suffix}")
            matched += 1
        except Exception as exc:
            print(f"[失敗] {photo.name}: {exc}", file=sys.stderr)
            failed += 1

    print(f"完成：匹配 {matched}，跳過 {skipped}，失敗 {failed}")
    if not write:
        print("（dry-run，未寫入。加上 --write 才會修改照片）")
    return 0 if failed == 0 else 2


def default_tracks_dir() -> Path:
    home = Path.home()
    # Public iCloud container path used when NSUbiquitousContainerIsDocumentScopePublic is true.
    candidates = [
        home / "Library/Mobile Documents/iCloud~com~watchgpsbridge~app/Documents/Tracks",
        home / "Library/Mobile Documents/iCloud.com.watchgpsbridge.app/Documents/Tracks",
    ]
    for path in candidates:
        if path.is_dir():
            return path
    return candidates[0]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="用腕上定位軌跡為照片寫入 EXIF GPS")
    parser.add_argument(
        "--tracks",
        type=Path,
        default=default_tracks_dir(),
        help="軌跡 JSON 資料夾（iCloud Tracks）",
    )
    parser.add_argument("--photos", type=Path, required=True, help="照片資料夾")
    parser.add_argument(
        "--max-delta-seconds",
        type=int,
        default=300,
        help="照片時間與 GPS 點最大允許差距（秒），預設 300",
    )
    parser.add_argument("--recursive", action="store_true", help="遞迴掃描照片子資料夾")
    parser.add_argument("--write", action="store_true", help="實際寫入 EXIF（預設只預覽）")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.tracks.exists():
        print(f"找不到軌跡資料夾：{args.tracks}", file=sys.stderr)
        print("請確認 iCloud 已同步，或用 --tracks 指定路徑。", file=sys.stderr)
        return 1
    if not args.photos.exists():
        print(f"找不到照片資料夾：{args.photos}", file=sys.stderr)
        return 1
    return geotag(
        tracks_dir=args.tracks,
        photos_dir=args.photos,
        max_delta_seconds=args.max_delta_seconds,
        recursive=args.recursive,
        write=args.write,
    )


if __name__ == "__main__":
    raise SystemExit(main())
