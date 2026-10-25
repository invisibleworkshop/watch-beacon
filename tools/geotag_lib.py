"""Core library: load Watch GPS tracks, correct photo timezones, write EXIF dates + GPS."""

from __future__ import annotations

import json
import re
from bisect import bisect_left
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Iterable, List, Optional, Sequence, Tuple

import piexif
from piexif import GPSIFD, ImageIFD

PHOTO_SUFFIXES = {".jpg", ".jpeg", ".tif", ".tiff", ".heic", ".heif"}

LogFn = Callable[[str], None]


@dataclass(frozen=True)
class TrackPoint:
    timestamp: datetime  # UTC
    latitude: float
    longitude: float
    altitude: float
    horizontal_accuracy: float


@dataclass(frozen=True)
class FixedOffset:
    """Fixed GMT/UTC offset (no DST), e.g. GMT+8 or GMT+9."""

    label: str
    offset: timedelta

    @property
    def tz(self) -> timezone:
        return timezone(self.offset)

    @property
    def exif_offset_bytes(self) -> bytes:
        total = int(self.offset.total_seconds())
        sign = "+" if total >= 0 else "-"
        total = abs(total)
        hours, rem = divmod(total, 3600)
        minutes = rem // 60
        return f"{sign}{hours:02d}:{minutes:02d}".encode("ascii")


COMMON_TIMEZONES: List[FixedOffset] = [
    FixedOffset("GMT+0 / UTC", timedelta(0)),
    FixedOffset("GMT+7（曼谷等）", timedelta(hours=7)),
    FixedOffset("GMT+8（台北／新加坡等）", timedelta(hours=8)),
    FixedOffset("GMT+9（東京／首爾等）", timedelta(hours=9)),
    FixedOffset("GMT+10", timedelta(hours=10)),
    FixedOffset("GMT-5", timedelta(hours=-5)),
    FixedOffset("GMT-7", timedelta(hours=-7)),
    FixedOffset("GMT-8", timedelta(hours=-8)),
]


def parse_gmt_label(text: str) -> FixedOffset:
    """Parse 'GMT+9', 'UTC+09:00', '+8', '9' into FixedOffset."""
    raw = text.strip().upper().replace("UTC", "GMT")
    match = re.fullmatch(
        r"(?:GMT)?\s*([+-]?)(\d{1,2})(?::?(\d{2}))?",
        raw.replace(" ", ""),
    )
    if not match:
        raise ValueError(f"無法解析時區：{text}（例：GMT+8、GMT+9、+09:00）")
    sign = -1 if match.group(1) == "-" else 1
    hours = int(match.group(2))
    minutes = int(match.group(3) or "0")
    if hours > 14 or minutes > 59:
        raise ValueError(f"時區超出範圍：{text}")
    offset = sign * timedelta(hours=hours, minutes=minutes)
    label = f"GMT{offset_to_label(offset)}"
    return FixedOffset(label=label, offset=offset)


def offset_to_label(offset: timedelta) -> str:
    total = int(offset.total_seconds())
    sign = "+" if total >= 0 else "-"
    total = abs(total)
    hours, rem = divmod(total, 3600)
    minutes = rem // 60
    if minutes:
        return f"{sign}{hours}:{minutes:02d}"
    return f"{sign}{hours}"


def parse_iso8601(value: str) -> datetime:
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _load_points_from_gpx(path: Path, log: Optional[LogFn] = None) -> List[TrackPoint]:
    import re
    from xml.etree import ElementTree as ET

    text = path.read_text(encoding="utf-8")
    # Strip default namespace for simpler parsing
    text = re.sub(r'\sxmlns="[^"]+"', "", text, count=1)
    root = ET.fromstring(text)
    points: List[TrackPoint] = []
    for trkpt in root.findall(".//trkpt"):
        try:
            lat = float(trkpt.attrib["lat"])
            lon = float(trkpt.attrib["lon"])
            ele_el = trkpt.find("ele")
            time_el = trkpt.find("time")
            acc_el = trkpt.find(".//{*}horizontalAccuracy")
            if acc_el is None:
                acc_el = trkpt.find(".//horizontalAccuracy")
            points.append(
                TrackPoint(
                    timestamp=parse_iso8601(time_el.text) if time_el is not None and time_el.text else datetime.now(timezone.utc),
                    latitude=lat,
                    longitude=lon,
                    altitude=float(ele_el.text) if ele_el is not None and ele_el.text else 0.0,
                    horizontal_accuracy=float(acc_el.text) if acc_el is not None and acc_el.text else -1.0,
                )
            )
        except (KeyError, TypeError, ValueError) as exc:
            if log:
                log(f"略過損壞 GPX 點位 ({path.name}): {exc}")
    return points


def load_tracks(tracks_dir: Path, log: Optional[LogFn] = None) -> List[TrackPoint]:
    files = sorted(list(tracks_dir.glob("*.gpx")) + list(tracks_dir.glob("*.json")))
    if not files:
        raise FileNotFoundError(f"在 {tracks_dir} 找不到 *.gpx／*.json 軌跡檔")

    points: List[TrackPoint] = []
    for path in files:
        if path.suffix.lower() == ".gpx":
            points.extend(_load_points_from_gpx(path, log=log))
            continue
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
                if log:
                    log(f"略過損壞點位 ({path.name}): {exc}")

    points.sort(key=lambda p: p.timestamp)
    deduped: List[TrackPoint] = []
    for point in points:
        if deduped and deduped[-1].timestamp == point.timestamp:
            if point.horizontal_accuracy >= 0 and (
                deduped[-1].horizontal_accuracy < 0
                or point.horizontal_accuracy < deduped[-1].horizontal_accuracy
            ):
                deduped[-1] = point
            continue
        deduped.append(point)
    return deduped


def iter_photos(photos_dir: Path, recursive: bool) -> Iterable[Path]:
    candidates = photos_dir.rglob("*") if recursive else photos_dir.glob("*")
    for path in candidates:
        if path.is_file() and path.suffix.lower() in PHOTO_SUFFIXES:
            yield path


def _rationally(number: float, precision: int = 100000) -> Tuple[int, int]:
    return int(abs(number) * precision), precision


def decimal_to_dms_rationals(
    decimal: float,
) -> Tuple[Tuple[int, int], Tuple[int, int], Tuple[int, int]]:
    value = abs(decimal)
    degrees = int(value)
    minutes_full = (value - degrees) * 60
    minutes = int(minutes_full)
    seconds = (minutes_full - minutes) * 60
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


def parse_exif_naive(text: str) -> Optional[datetime]:
    text = text.strip()
    for fmt in ("%Y:%m:%d %H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None


def read_wall_clock(path: Path) -> Optional[datetime]:
    """Read naive EXIF DateTimeOriginal / DateTime (wall clock numbers only)."""
    suffix = path.suffix.lower()
    if suffix in {".heic", ".heif"}:
        return read_heic_wall_clock(path)

    try:
        exif_dict = piexif.load(str(path))
    except Exception:
        return None

    for ifd_name, tag in (
        ("Exif", piexif.ExifIFD.DateTimeOriginal),
        ("Exif", piexif.ExifIFD.DateTimeDigitized),
        ("0th", ImageIFD.DateTime),
    ):
        raw = (exif_dict.get(ifd_name) or {}).get(tag)
        if not raw:
            continue
        text = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else str(raw)
        naive = parse_exif_naive(text)
        if naive:
            return naive
    return None


def read_heic_wall_clock(path: Path) -> Optional[datetime]:
    try:
        from PIL import Image
        from pillow_heif import register_heif_opener
    except ImportError:
        return None

    register_heif_opener()
    try:
        with Image.open(path) as img:
            exif = img.getexif()
            if not exif:
                return None
            raw = exif.get(36867) or exif.get(36868) or exif.get(306)
            if not raw:
                return None
            return parse_exif_naive(str(raw))
    except Exception:
        return None


def correct_photo_time(
    wall_clock: datetime,
    assumed_source_tz: FixedOffset,
    target_tz: FixedOffset,
    mode: str,
) -> datetime:
    """Return timezone-aware datetime in ``target_tz``.

    Modes:
    - ``retag``: keep wall-clock numbers, attach ``target_tz``
      (e.g. 12:00 wrongly tagged +8 → keep 12:00, write as +9).
      ``assumed_source_tz`` is unused for the math but kept for UI clarity.
    - ``convert``: interpret wall clock in ``assumed_source_tz``, convert to ``target_tz``
      (same absolute instant; 12:00+8 → 13:00+9).
    """
    _ = assumed_source_tz
    if mode == "convert":
        absolute = wall_clock.replace(tzinfo=assumed_source_tz.tz)
        return absolute.astimezone(target_tz.tz)
    # Default: retag — wall clock is the intended local time in the target zone.
    return wall_clock.replace(tzinfo=target_tz.tz)


def nearest_point(
    points: Sequence[TrackPoint],
    when_utc: datetime,
    max_delta: timedelta,
) -> Optional[Tuple[TrackPoint, timedelta]]:
    if not points:
        return None
    timestamps = [p.timestamp for p in points]
    idx = bisect_left(timestamps, when_utc)
    candidates: List[TrackPoint] = []
    if idx < len(points):
        candidates.append(points[idx])
    if idx > 0:
        candidates.append(points[idx - 1])
    best = min(candidates, key=lambda p: abs(p.timestamp - when_utc))
    delta = abs(best.timestamp - when_utc)
    if delta > max_delta:
        return None
    return best, delta


def format_exif_datetime(dt: datetime) -> bytes:
    local = dt
    return local.strftime("%Y:%m:%d %H:%M:%S").encode("ascii")


def apply_exif_dates_and_gps(
    exif_dict: dict,
    local_dt: datetime,
    target_tz: FixedOffset,
    point: Optional[TrackPoint],
) -> dict:
    """Update Create/Modify-style date tags, OffsetTime*, and optional GPS."""
    date_bytes = format_exif_datetime(local_dt)
    offset_bytes = target_tz.exif_offset_bytes

    zeroth = dict(exif_dict.get("0th") or {})
    exif = dict(exif_dict.get("Exif") or {})
    gps = dict(exif_dict.get("GPS") or {})

    # ModifyDate / DateTime
    zeroth[ImageIFD.DateTime] = date_bytes
    # Create / Original / Digitized
    exif[piexif.ExifIFD.DateTimeOriginal] = date_bytes
    exif[piexif.ExifIFD.DateTimeDigitized] = date_bytes

    # Timezone tags (EXIF 2.31)
    for tag in (
        getattr(piexif.ExifIFD, "OffsetTime", 0x9010),
        getattr(piexif.ExifIFD, "OffsetTimeOriginal", 0x9011),
        getattr(piexif.ExifIFD, "OffsetTimeDigitized", 0x9012),
    ):
        exif[tag] = offset_bytes

    if point is not None:
        gps = build_gps_ifd(point)

    exif_dict["0th"] = zeroth
    exif_dict["Exif"] = exif
    exif_dict["GPS"] = gps
    return exif_dict


def write_jpeg_exif(path: Path, local_dt: datetime, target_tz: FixedOffset, point: Optional[TrackPoint]) -> None:
    exif_dict = piexif.load(str(path))
    exif_dict = apply_exif_dates_and_gps(exif_dict, local_dt, target_tz, point)
    piexif.insert(piexif.dump(exif_dict), str(path))


def write_heic_exif(path: Path, local_dt: datetime, target_tz: FixedOffset, point: Optional[TrackPoint]) -> None:
    from PIL import Image
    from pillow_heif import register_heif_opener

    register_heif_opener()
    exif_dict = {"0th": {}, "Exif": {}, "GPS": {}, "1st": {}, "thumbnail": None}
    exif_dict = apply_exif_dates_and_gps(exif_dict, local_dt, target_tz, point)
    raw = piexif.dump(exif_dict)
    with Image.open(path) as img:
        img.save(path, exif=raw)


@dataclass
class ProcessResult:
    matched: int = 0
    skipped: int = 0
    failed: int = 0


def process_photos(
    tracks_dir: Path,
    photos_dir: Path,
    target_tz: FixedOffset,
    source_tz: FixedOffset,
    mode: str = "retag",
    max_delta_seconds: int = 300,
    recursive: bool = True,
    write: bool = False,
    require_gps: bool = True,
    log: Optional[LogFn] = None,
) -> ProcessResult:
    """Correct photo timezone, map GPS, optionally write EXIF.

    ``mode``:
      - ``retag``: 牆上時間不變，改套用目標時區（例：12:00 +8 標籤錯 → 12:00 +9）
      - ``convert``: 依來源時區解讀後換算到目標時區（例：12:00+8 → 13:00+9）
    """
    def _log(msg: str) -> None:
        if log:
            log(msg)

    points = load_tracks(tracks_dir, log=log)
    if not points:
        raise ValueError("軌跡檔沒有可用點位")

    _log(
        f"軌跡 {len(points)} 點："
        f"{points[0].timestamp.isoformat()} → {points[-1].timestamp.isoformat()}（UTC）"
    )
    _log(f"時區模式={mode}，來源={source_tz.label}，目標={target_tz.label}")

    max_delta = timedelta(seconds=max_delta_seconds)
    result = ProcessResult()

    for photo in iter_photos(photos_dir, recursive=recursive):
        wall = read_wall_clock(photo)
        if wall is None:
            _log(f"[跳過] 無拍攝時間：{photo}")
            result.skipped += 1
            continue

        local_dt = correct_photo_time(wall, source_tz, target_tz, mode=mode)
        when_utc = local_dt.astimezone(timezone.utc)

        hit = nearest_point(points, when_utc, max_delta)
        if hit is None:
            msg = (
                f"[跳過] 無 GPS（Δ>{max_delta_seconds}s）：{photo.name} "
                f"牆上 {wall.isoformat()} → {local_dt.isoformat()} / UTC {when_utc.isoformat()}"
            )
            if require_gps:
                _log(msg)
                result.skipped += 1
                continue
            point = None
            delta = None
            _log(msg.replace("[跳過]", "[僅改時區]"))
        else:
            point, delta = hit

        action = "寫入" if write else "預覽"
        gps_part = (
            f"→ GPS {point.latitude:.6f},{point.longitude:.6f} (Δ{delta.total_seconds():.1f}s)"
            if point and delta is not None
            else "→ 無 GPS"
        )
        _log(
            f"[{action}] {photo.name}: {wall.strftime('%Y-%m-%d %H:%M:%S')} "
            f"⇒ {local_dt.strftime('%Y-%m-%d %H:%M:%S')} {target_tz.label} {gps_part}"
        )

        if not write:
            result.matched += 1
            continue

        try:
            suffix = photo.suffix.lower()
            if suffix in {".jpg", ".jpeg", ".tif", ".tiff"}:
                write_jpeg_exif(photo, local_dt, target_tz, point)
            elif suffix in {".heic", ".heif"}:
                write_heic_exif(photo, local_dt, target_tz, point)
            else:
                raise RuntimeError(f"不支援的副檔名：{suffix}")
            result.matched += 1
        except Exception as exc:
            _log(f"[失敗] {photo.name}: {exc}")
            result.failed += 1

    _log(f"完成：處理 {result.matched}，跳過 {result.skipped}，失敗 {result.failed}")
    return result


def default_tracks_dir() -> Path:
    home = Path.home()
    candidates = [
        home / "Library/Mobile Documents/iCloud~com~invisibleworkshop~watchgpsbridge/Documents/Tracks",
        home / "Library/Mobile Documents/iCloud.com.invisibleworkshop.watchgpsbridge/Documents/Tracks",
    ]
    for path in candidates:
        if path.is_dir():
            return path
    return candidates[0]
