# 精確定位（WatchGPSBridge）

用 **Apple Watch Companion App** 取得精確 GPS，即時傳到 **iPhone**，並以 **每 1 萬點一個 GPX** 持續寫入 **iCloud Drive**；逾時未收到訊號會通知。捷徑只需定時打開 **iPhone App**。Mac 上用可上架的 **精確定位 Geotag** App 依照片拍攝時間寫入 EXIF GPS，並支援 GPX ⇄ 舊 geotag JSON 互轉。

## 為什麼一定要 Watch App？

Apple 不提供「內建 GPS 廣播給第三方 iPhone App」的 API。要穩定取得 Watch 高精度定位並做斷線提醒，必須安裝 Companion Watch App。

## 運作流程

1. 捷徑／手動打開 **iPhone「精確定位」**
2. iPhone 用 HealthKit `startWatchApp` **喚醒 Watch Companion**
3. Watch 以最高導航精度定位，並用運動工作階段維持背景 GPS
4. 點位經 WatchConnectivity 傳到 iPhone
5. iPhone **連續寫入** iCloud：`Documents/Tracks/track-….gpx`，每滿 **10,000** 點開新檔；記錄中會以 **Live Activity** 顯示在靈動島／鎖定畫面
6. 超過約 60 秒沒收到點位 → 每分鐘自動喚醒手錶；連續約 5 分鐘仍無訊息才本地通知
7. Mac 同步 iCloud 後，用 **精確定位 Geotag** 幫照片標 GPS

## 環境需求

- macOS + Xcode 15+（建 iOS／watchOS／macOS App）
- iPhone（iOS 17+）與支援 GPS 的 Apple Watch（watchOS 10+）
- Apple Developer 帳號（HealthKit + **iCloud Documents**；Mac App 用 sandbox）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 建置步驟（iPhone / Watch）

```bash
brew install xcodegen
./scripts/generate-xcodeproj.sh
open WatchGPSBridge.xcodeproj
```

版本：**1.0.0**（build 見 `project.yml` 的 `CURRENT_PROJECT_VERSION`）。

在 Xcode：

1. Signing 已固定為 Team `VHX5NF3JWK`、Automatic（見 `project.yml`）
2. Bundle ID：`com.invisibleworkshop.watchgpsbridge`／`com.invisibleworkshop.watchgpsbridge.watchkitapp`
3. Capabilities 啟用 **HealthKit** 與 **iCloud → iCloud Documents**  
   Container：`iCloud.com.invisibleworkshop.watchgpsbridge`（entitlements 已寫好）

### 上 TestFlight（建議；Watch 常無法用 Xcode 直裝）

1. [App Store Connect](https://appstoreconnect.apple.com) 新建 App（若尚未建立）  
   Bundle ID：`com.invisibleworkshop.watchgpsbridge`，名稱可用「精確定位」
2. Xcode → scheme **WatchGPSBridge** → **Any iOS Device (arm64)**  
   → **Product → Archive**
3. Organizer → **Distribute App** → **App Store Connect** → Upload  
   （Watch companion 會跟著 iPhone archive 一併上傳）
4. Connect 處理完 build 後，到 TestFlight 加測試者／裝置；iPhone 安裝後再裝 Watch App

請允許：Watch 定位、健康權限、iPhone 通知、iCloud。

## 儲存格式（iCloud）

Finder 路徑大致為：

```text
iCloud Drive / 精確定位 / Documents / Tracks /
  track-2026-10-23T04-00-00Z-part0001.gpx
  track-2026-10-23T05-12-11Z-part0002.gpx
  ...
```

每個檔案約 1 萬點（GPX 1.1）。目前開啟中的檔會持續覆寫進度；滿 1 萬點後封存並開新檔。可連續記錄，不設總上限。

舊版曾使用 geotag JSON（`TrackChunkFile`）；iPhone 開啟舊檔會讀取後改寫為 GPX。Mac App「格式互轉」可 GPX ⇄ JSON 雙向轉換。

## Mac App：精確定位 Geotag（可上架 Mac App Store）

原生 SwiftUI macOS App（App Sandbox），Bundle ID：`com.invisibleworkshop.watchgpsbridge.geotag`。

```bash
./scripts/generate-xcodeproj.sh
open WatchGPSBridge.xcodeproj
# scheme：PreciseGeotagMac → Archive → Distribute → Mac App Store
```

功能：

1. **照片 Geotag**：選軌跡目錄（GPX／舊 JSON）與照片目錄，修正 EXIF 時區並寫入 GPS  
2. **格式互轉**：GPX ⇄ geotag JSON（單檔或整個資料夾）

時區模式：

| 模式 | 例子 | 用途 |
|------|------|------|
| **保持牆上時間，改套目標時區**（預設） | `12:00+8` → `12:00+9` | 時區標籤錯了，當地牆上時間其實正確 |
| **同一瞬間換算** | `12:00+8` → `13:00+9` | 絕對時間不變，只換顯示時區 |

先不要勾「實際寫入」可預覽；確認後再寫入（會改原檔，請先備份）。

### 可選：Python CLI（開發／批次）

仍保留 `tools/geotag_photos.py`（支援 `.gpx` 與舊 `.json`）。日常請用 Mac App。

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r tools/requirements.txt
python tools/geotag_photos.py \
  --tracks "$HOME/Library/Mobile Documents/iCloud~com~invisibleworkshop~watchgpsbridge/Documents/Tracks" \
  --photos ~/Pictures/MyTrip \
  --source-tz GMT+8 \
  --target-tz GMT+9 \
  --mode retag \
  --recursive \
  --write
```

## 捷徑自動化

手錶 **無法**可靠用捷徑固定啟動 App。請只自動化手機。

**記錄以手機為準**：必須啟動「精確定位」才會監視手錶並寫入 iCloud；只對手錶開 GPS、手機沒在記錄 → **不會存檔**。

iOS **不提供**「判斷 App 是否還在背景」，時間自動化也**沒有「每小時」**（只有每天／週／月／年）。

### 建議設定（與方圓記帳相同：打開 App）

不要用「打開 URL」做自動化——本 App 有靈動島時，自訂 URL 容易再開一個獨立視窗。

1. **捷徑** → 新增捷徑「維持精確定位」  
   - 動作：**打開 App** → **精確定位**
2. **自動化** → 一天中的時間 → **每天** 多個整點 → 跑上面捷徑（關「執行前詢問」）
3. 若已在記錄中，每次打開會自動檢查訊號並視需要重喚醒手錶

一次性開始：App 內「開始手機記錄」或（可選）`watchgpsbridge://start`  
停止：App 內停止或 `watchgpsbridge://stop`

### 若想找 App 內建動作

捷徑 → 新增動作 → 搜尋 **精確定位** 或 **開始手機記錄**／**檢查並維持手機記錄**（出現在 App 底下，不是「執行 App Intent」這個總稱）。需已安裝並開啟過 App。

行為：

- 尚未開始／已按停止 → `ensure` 會略過寫入  
- 記錄中且近期有點 → 維持  
- App 被關掉或收不到點 → 打開精確定位並重喚醒手錶；失敗 → 通知

## 專案結構

```text
Shared/                 共用模型、GPXCodec
WatchGPSBridge/         iPhone（接收、iCloud 輪轉 GPX、通知、Intent）
WatchGPSBridgeWatch/    Watch Companion
PreciseGeotagMac/       macOS Geotag App（可上架）
tools/geotag_photos.py  可選 CLI
tools/geotag_lib.py     CLI 核心（含 GPX）
project.yml
```

## 可調參數

- 每檔點數：`LocationRecorder.pointsPerFile`（預設 10000）
- GPS 記錄間隔：App 設定（1／3／5／10 秒），同步到手錶
- 斷線門檻：`StaleSignalMonitor.staleThreshold`（預設 60 秒）
- 自動重喚醒間隔：`StaleSignalMonitor.rewakeCooldown`（預設 60 秒）
- 通知：連續 `notifyAfterRewakeAttempts` 次（預設 5，約 5 分鐘）仍無訊號才通知
- 照片匹配容許差：Mac App／`--max-delta-seconds`（預設 300）

## 限制

- 需 GPS 機型 Apple Watch  
- iCloud 需同一 Apple ID，並等到 Mac 同步完成再 geotag  
- 寫入 EXIF 會改原檔，請先備份  
- 本環境無法編譯 iOS；請在 Mac + 實機驗證  

## 授權

供學習與實作參考；請遵守 Apple 定位與健康資料使用規範。
