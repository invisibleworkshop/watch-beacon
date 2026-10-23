# 腕上定位（WatchGPSBridge）

用 **Apple Watch Companion App** 取得精確 GPS，即時傳到 **iPhone**，並以 **每 1 萬點一個 JSON** 持續寫入 **iCloud Drive**；逾時未收到訊號會通知。捷徑只需定時打開 **iPhone App**。Mac 上用附贈的 **Python 腳本** 依照片拍攝時間寫入 EXIF GPS。

## 為什麼一定要 Watch App？

Apple 不提供「內建 GPS 廣播給第三方 iPhone App」的 API。要穩定取得 Watch 高精度定位並做斷線提醒，必須安裝 Companion Watch App。

## 運作流程

1. 捷徑／手動打開 **iPhone「腕上定位」**
2. iPhone 用 HealthKit `startWatchApp` **喚醒 Watch Companion**
3. Watch 以最高導航精度定位，並用運動工作階段維持背景 GPS
4. 點位經 WatchConnectivity 傳到 iPhone
5. iPhone **連續寫入** iCloud：`Documents/Tracks/track-….json`，每滿 **10,000** 點開新檔
6. 超過約 60 秒沒收到點位 → 本地通知
7. Mac 同步 iCloud 後，執行 `tools/geotag_photos.py` 幫照片標 GPS

## 環境需求

- macOS + Xcode 15+（建 iOS／watchOS App）
- iPhone（iOS 17+）與支援 GPS 的 Apple Watch（watchOS 10+）
- Apple Developer 帳號（HealthKit + **iCloud Documents**）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Mac 處理照片：Python 3.10+

## 建置步驟（iPhone / Watch）

```bash
brew install xcodegen
./scripts/generate-xcodeproj.sh
open WatchGPSBridge.xcodeproj
```

在 Xcode：

1. 選 Team 簽章（iOS 與 Watch）
2. Bundle ID：`com.watchgpsbridge.app`／`com.watchgpsbridge.app.watchkitapp`
3. Capabilities 啟用 **HealthKit** 與 **iCloud → iCloud Documents**  
   Container：`iCloud.com.watchgpsbridge.app`（entitlements 已寫好）
4. 實機 Run（會一併安裝 Watch App）

請允許：Watch 定位、健康權限、iPhone 通知、iCloud。

## 儲存格式（iCloud）

Finder 路徑大致為：

```text
iCloud Drive / 腕上定位 / Documents / Tracks /
  track-2026-10-23T04-00-00Z-part0001.json
  track-2026-10-23T05-12-11Z-part0002.json
  ...
```

每個檔案約 1 萬點（pretty JSON 約 **2.5–3 MB**）。目前開啟中的檔會持續覆寫進度；滿 1 萬點後封存並開新檔。可連續記錄，不設總上限。

JSON 結構：

```json
{
  "schemaVersion": 1,
  "pointsPerFile": 10000,
  "createdAt": "...",
  "pointCount": 123,
  "points": [
    {
      "id": "...",
      "latitude": 25.03,
      "longitude": 121.56,
      "altitude": 12.5,
      "horizontalAccuracy": 4.0,
      "verticalAccuracy": 3.0,
      "speed": 1.2,
      "course": 90.0,
      "timestamp": "2026-10-23T04:10:00Z"
    }
  ]
}
```

## Mac：依照片時間寫入 EXIF GPS

```bash
cd /path/to/this/repo
python3 -m venv .venv
source .venv/bin/activate
pip install -r tools/requirements.txt

# 先 dry-run 預覽
python tools/geotag_photos.py \
  --tracks "$HOME/Library/Mobile Documents/iCloud~com~watchgpsbridge~app/Documents/Tracks" \
  --photos ~/Pictures/MyTrip \
  --max-delta-seconds 300 \
  --recursive

# 確認無誤後實際寫入
python tools/geotag_photos.py \
  --tracks "$HOME/Library/Mobile Documents/iCloud~com~watchgpsbridge~app/Documents/Tracks" \
  --photos ~/Pictures/MyTrip \
  --max-delta-seconds 300 \
  --recursive \
  --write
```

行為：

- 讀取所有軌跡 JSON，依時間排序
- 讀每張照片的 EXIF 拍攝時間（`DateTimeOriginal` 等）
- 找時間差在 `--max-delta-seconds` 內最近的 GPS 點
- 寫入 EXIF GPS（緯度／經度／海拔）
- 支援 JPEG／TIFF；HEIC 需 `pillow-heif`（建議重要底片先備份）

未加 `--write` 時只預覽，不改檔。

## 捷徑自動化

Watch **無法**可靠用捷徑固定啟動 App。請只自動化 iPhone：

- **打開 App** → 腕上定位  
- 或 App Intent：**開始 Watch GPS 記錄**  
- 或 URL：`watchgpsbridge://start`

## 專案結構

```text
Shared/                 共用模型
WatchGPSBridge/         iPhone（接收、iCloud 輪轉存檔、通知、Intent）
WatchGPSBridgeWatch/    Watch Companion
tools/geotag_photos.py  Mac 端照片 geotag
tools/requirements.txt
project.yml
```

## 可調參數

- 每檔點數：`LocationRecorder.pointsPerFile`（預設 10000）
- 斷線門檻：`StaleSignalMonitor.staleThreshold`（預設 60 秒）
- 照片匹配容許差：`--max-delta-seconds`（預設 300）

## 限制

- 需 GPS 機型 Apple Watch  
- iCloud 需同一 Apple ID，並等到 Mac 同步完成再跑腳本  
- 寫入 EXIF 會改原檔，請先備份  
- 本環境無法編譯 iOS；請在 Mac + 實機驗證  

## 授權

供學習與實作參考；請遵守 Apple 定位與健康資料使用規範。
