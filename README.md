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

## Mac App：修正時區 + 對應 GPS

照片 EXIF 時區常是錯的（例如人在 GMT+9，相機仍標 GMT+8）。用 App 指定：

1. **軌跡目錄**（iCloud `Tracks`）
2. **照片目錄**
3. **原時區 / 目標時區**（例 GMT+8 → GMT+9）
4. 寫回 EXIF：**DateTime / DateTimeOriginal / DateTimeDigitized**、**OffsetTime\***，以及對到的 **GPS**

```bash
cd /path/to/this/repo
python3 -m venv .venv
source .venv/bin/activate
pip install -r tools/requirements.txt

# 圖形介面（建議）
python tools/geotag_app.py
```

時區模式：

| 模式 | 例子 | 用途 |
|------|------|------|
| **保持牆上時間，改套目標時區**（預設） | `12:00+8` → `12:00+9` | 時區標籤錯了，當地牆上時間其實正確 |
| **同一瞬間換算** | `12:00+8` → `13:00+9` | 絕對時間不變，只換顯示時區 |

先不要勾「實際寫入」可預覽；確認後再寫入（會改原檔，請先備份）。

CLI 同等功能：

```bash
python tools/geotag_photos.py \
  --tracks "$HOME/Library/Mobile Documents/iCloud~com~watchgpsbridge~app/Documents/Tracks" \
  --photos ~/Pictures/MyTrip \
  --source-tz GMT+8 \
  --target-tz GMT+9 \
  --mode retag \
  --recursive \
  --write
```

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
tools/geotag_app.py      Mac 圖形 App（目錄 + 時區 + 寫入 EXIF）
tools/geotag_photos.py  同等 CLI
tools/geotag_lib.py     核心邏輯
tools/requirements.txt
project.yml
```

## 可調參數

- 每檔點數：`LocationRecorder.pointsPerFile`（預設 10000）
- 斷線門檻：`StaleSignalMonitor.staleThreshold`（預設 60 秒）
- 照片匹配容許差：App／`--max-delta-seconds`（預設 300）

## 限制

- 需 GPS 機型 Apple Watch  
- iCloud 需同一 Apple ID，並等到 Mac 同步完成再跑腳本  
- 寫入 EXIF 會改原檔，請先備份  
- 本環境無法編譯 iOS；請在 Mac + 實機驗證  

## 授權

供學習與實作參考；請遵守 Apple 定位與健康資料使用規範。
