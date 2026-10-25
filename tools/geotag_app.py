#!/usr/bin/env python3
"""Mac GUI（tkinter，開發用）：指定軌跡／照片目錄與時區，修正 EXIF 時間後對應 GPS。

正式用途請改用原生 macOS App「精確定位 Geotag」（Xcode scheme：PreciseGeotagMac），
可上架 Mac App Store，並支援 GPX ⇄ geotag JSON 互轉。
"""

from __future__ import annotations

import sys
import threading
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

try:
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk
except ModuleNotFoundError as exc:  # pragma: no cover
    raise SystemExit(
        "此 App 需要 tkinter。\n"
        "macOS：請使用 python.org 安裝的 Python，或 brew install python-tk。\n"
        "也可改用 CLI：python tools/geotag_photos.py --help"
    ) from exc

from geotag_lib import (  # noqa: E402
    COMMON_TIMEZONES,
    FixedOffset,
    default_tracks_dir,
    parse_gmt_label,
    process_photos,
)


class GeotagApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("精確定位 · 照片 Geotag")
        self.geometry("780x640")
        self.minsize(700, 560)

        self.tracks_var = tk.StringVar(value=str(default_tracks_dir()))
        self.photos_var = tk.StringVar(value="")
        self.source_tz_var = tk.StringVar(value="GMT+8（台北／新加坡等）")
        self.target_tz_var = tk.StringVar(value="GMT+9（東京／首爾等）")
        self.custom_source_var = tk.StringVar(value="")
        self.custom_target_var = tk.StringVar(value="")
        self.mode_var = tk.StringVar(value="retag")
        self.delta_var = tk.StringVar(value="300")
        self.recursive_var = tk.BooleanVar(value=True)
        self.write_var = tk.BooleanVar(value=False)
        self.require_gps_var = tk.BooleanVar(value=True)

        self._build()

    def _build(self) -> None:
        pad = {"padx": 12, "pady": 6}
        root = ttk.Frame(self)
        root.pack(fill=tk.BOTH, expand=True)

        ttk.Label(root, text="精確定位 Geotag", font=("Helvetica", 18, "bold")).pack(
            anchor="w", **pad
        )
        ttk.Label(
            root,
            text="指定軌跡與照片目錄、目標時區；修正 EXIF 時間後再對應 GPS。",
            wraplength=720,
        ).pack(anchor="w", padx=12)

        form = ttk.Frame(root)
        form.pack(fill=tk.X, **pad)

        self._row_dir(form, 0, "軌跡目錄", self.tracks_var, self._pick_tracks)
        self._row_dir(form, 1, "照片目錄", self.photos_var, self._pick_photos)

        tz_frame = ttk.LabelFrame(root, text="照片時區")
        tz_frame.pack(fill=tk.X, **pad)

        labels = [z.label for z in COMMON_TIMEZONES]
        ttk.Label(tz_frame, text="原時區（錯誤標籤／解讀用）").grid(row=0, column=0, sticky="w", padx=8, pady=4)
        ttk.Combobox(tz_frame, textvariable=self.source_tz_var, values=labels, width=36).grid(
            row=0, column=1, sticky="w", padx=8, pady=4
        )
        ttk.Entry(tz_frame, textvariable=self.custom_source_var, width=12).grid(row=0, column=2, padx=4)
        ttk.Label(tz_frame, text="自訂如 GMT+8").grid(row=0, column=3, sticky="w")

        ttk.Label(tz_frame, text="目標時區（寫入 EXIF）").grid(row=1, column=0, sticky="w", padx=8, pady=4)
        ttk.Combobox(tz_frame, textvariable=self.target_tz_var, values=labels, width=36).grid(
            row=1, column=1, sticky="w", padx=8, pady=4
        )
        ttk.Entry(tz_frame, textvariable=self.custom_target_var, width=12).grid(row=1, column=2, padx=4)
        ttk.Label(tz_frame, text="自訂如 GMT+9").grid(row=1, column=3, sticky="w")

        mode_frame = ttk.Frame(tz_frame)
        mode_frame.grid(row=2, column=0, columnspan=4, sticky="w", padx=8, pady=8)
        ttk.Radiobutton(
            mode_frame,
            text="保持牆上時間，改套目標時區（12:00+8 → 12:00+9）※常見：時區標錯",
            variable=self.mode_var,
            value="retag",
        ).pack(anchor="w")
        ttk.Radiobutton(
            mode_frame,
            text="同一瞬間換算（12:00+8 → 13:00+9）",
            variable=self.mode_var,
            value="convert",
        ).pack(anchor="w")

        opts = ttk.LabelFrame(root, text="選項")
        opts.pack(fill=tk.X, **pad)
        ttk.Label(opts, text="GPS 最大時間差（秒）").grid(row=0, column=0, sticky="w", padx=8, pady=4)
        ttk.Entry(opts, textvariable=self.delta_var, width=8).grid(row=0, column=1, sticky="w")
        ttk.Checkbutton(opts, text="含子資料夾", variable=self.recursive_var).grid(
            row=0, column=2, padx=12
        )
        ttk.Checkbutton(opts, text="必須對到 GPS 才寫入", variable=self.require_gps_var).grid(
            row=0, column=3, padx=12
        )
        ttk.Checkbutton(
            opts, text="實際寫入檔案（取消則只預覽）", variable=self.write_var
        ).grid(row=1, column=0, columnspan=3, sticky="w", padx=8, pady=4)

        btns = ttk.Frame(root)
        btns.pack(fill=tk.X, **pad)
        self.run_btn = ttk.Button(btns, text="開始處理", command=self._start)
        self.run_btn.pack(side=tk.LEFT)
        ttk.Button(btns, text="清空日誌", command=lambda: self.log_text.delete("1.0", tk.END)).pack(
            side=tk.LEFT, padx=8
        )

        log_frame = ttk.LabelFrame(root, text="日誌")
        log_frame.pack(fill=tk.BOTH, expand=True, **pad)
        self.log_text = tk.Text(log_frame, height=18, wrap=tk.WORD)
        scroll = ttk.Scrollbar(log_frame, command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=scroll.set)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scroll.pack(side=tk.RIGHT, fill=tk.Y)

    def _row_dir(self, parent: ttk.Frame, row: int, label: str, var: tk.StringVar, cmd) -> None:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=4, pady=4)
        ttk.Entry(parent, textvariable=var, width=64).grid(row=row, column=1, sticky="ew", padx=4)
        ttk.Button(parent, text="選擇…", command=cmd).grid(row=row, column=2, padx=4)
        parent.columnconfigure(1, weight=1)

    def _pick_tracks(self) -> None:
        path = filedialog.askdirectory(title="選擇軌跡目錄（Tracks）")
        if path:
            self.tracks_var.set(path)

    def _pick_photos(self) -> None:
        path = filedialog.askdirectory(title="選擇照片目錄")
        if path:
            self.photos_var.set(path)

    def _resolve_tz(self, combo: str, custom: str) -> FixedOffset:
        custom = custom.strip()
        if custom:
            return parse_gmt_label(custom)
        for zone in COMMON_TIMEZONES:
            if zone.label == combo:
                return zone
        return parse_gmt_label(combo)

    def log(self, message: str) -> None:
        def append() -> None:
            self.log_text.insert(tk.END, message + "\n")
            self.log_text.see(tk.END)

        self.after(0, append)

    def _start(self) -> None:
        tracks = Path(self.tracks_var.get().strip()).expanduser()
        photos = Path(self.photos_var.get().strip()).expanduser()
        if not tracks.is_dir():
            messagebox.showerror("錯誤", f"軌跡目錄不存在：\n{tracks}")
            return
        if not photos.is_dir():
            messagebox.showerror("錯誤", f"照片目錄不存在：\n{photos}")
            return
        try:
            source_tz = self._resolve_tz(self.source_tz_var.get(), self.custom_source_var.get())
            target_tz = self._resolve_tz(self.target_tz_var.get(), self.custom_target_var.get())
            delta = int(self.delta_var.get().strip())
        except ValueError as exc:
            messagebox.showerror("錯誤", str(exc))
            return

        if self.write_var.get():
            ok = messagebox.askokcancel(
                "確認寫入",
                "將直接修改照片 EXIF（時間 + GPS）。\n請確認已備份。是否繼續？",
            )
            if not ok:
                return

        self.run_btn.configure(state=tk.DISABLED)
        self.log("—— 開始 ——")

        def worker() -> None:
            try:
                result = process_photos(
                    tracks_dir=tracks,
                    photos_dir=photos,
                    target_tz=target_tz,
                    source_tz=source_tz,
                    mode=self.mode_var.get(),
                    max_delta_seconds=delta,
                    recursive=self.recursive_var.get(),
                    write=self.write_var.get(),
                    require_gps=self.require_gps_var.get(),
                    log=self.log,
                )
                self.after(
                    0,
                    lambda: messagebox.showinfo(
                        "完成",
                        f"處理 {result.matched}\n跳過 {result.skipped}\n失敗 {result.failed}",
                    ),
                )
            except Exception as exc:
                self.log(f"[錯誤] {exc}")
                self.after(0, lambda: messagebox.showerror("錯誤", str(exc)))
            finally:
                self.after(0, lambda: self.run_btn.configure(state=tk.NORMAL))

        threading.Thread(target=worker, daemon=True).start()


def main() -> None:
    app = GeotagApp()
    app.mainloop()


if __name__ == "__main__":
    main()
