# 腕上定位（WatchGPSBridge）

用 **Apple Watch Companion App** 取得精確 GPS，即時傳到 **iPhone** 記錄；若超過約 60 秒沒收到訊號，iPhone 會發本地通知。捷徑只需定時打開 **iPhone App**（不需在 Watch 上用捷徑啟動）。

## 為什麼一定要 Watch App？

Apple 不提供「內建 GPS 廣播給第三方 iPhone App」的 API。要穩定取得 Watch 那顆高精度定位，並做斷線提醒，必須在 Watch 上跑 Companion App（本專案已附上，可極簡操作）。

## 運作流程

1. 捷徑／通知／手動打開 **iPhone「腕上定位」**
2. iPhone 透過 HealthKit `startWatchApp` **喚醒 Watch Companion**
3. Watch 以 `kCLLocationAccuracyBestForNavigation` 定位，並用 **運動工作階段** 維持背景 GPS
4. 點位經 **WatchConnectivity** 傳到 iPhone 並寫入本機 JSON
5. iPhone 監看最後收包時間；逾時 → **「Apple Watch GPS 中斷」通知**

## 環境需求

- macOS + Xcode 15+
- iPhone（iOS 17+）與支援 GPS 的 Apple Watch（watchOS 10+）
- Apple Developer 帳號（實機簽章、HealthKit）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（產生 `.xcodeproj`）

## 建置步驟

```bash
brew install xcodegen
./scripts/generate-xcodeproj.sh
open WatchGPSBridge.xcodeproj
```

在 Xcode：

1. 選你的 **Team** 簽章（iOS 與 Watch target 都要）
2. 確認 Bundle ID：
   - iPhone：`com.watchgpsbridge.app`
   - Watch：`com.watchgpsbridge.app.watchkitapp`
3. Signing & Capabilities 需有 **HealthKit**（entitlements 已預設）
4. 將 iPhone + Watch 配對後，對 **WatchGPSBridge** scheme 實機 Run（會一併安裝 Watch App）

首次執行請在 **Watch** 與 **iPhone** 都允許：

- 定位（Watch：使用 App 期間／永遠）
- 健康／運動相關權限
- 通知（iPhone：斷線提醒）

## 捷徑自動化（重點）

Watch **無法**可靠地用捷徑固定啟動 App。請只自動化 **iPhone**：

### 方式 A：打開 App

1. 捷徑 App → 自動化 → 特定時間  
2. 動作：**打開 App** → 選「腕上定位」  
3. 打開 App 後可手動按「喚醒 Watch 並開始記錄」，或搭配方式 B

### 方式 B：App Intent（建議）

1. 捷徑中加入動作：**開始 Watch GPS 記錄**  
2. 此 Intent 會打開 App 並呼叫喚醒 Watch + 開始傳送 GPS  

### 方式 C：URL Scheme

```text
watchgpsbridge://start
```

其他：`watchgpsbridge://stop`、`watchgpsbridge://status`

## 專案結構

```text
Shared/                 共用 GPS 資料模型與訊息格式
WatchGPSBridge/         iPhone：接收、儲存、斷線監控、App Intent
WatchGPSBridgeWatch/    Watch：精確 GPS + 運動工作階段 + 傳送
project.yml             XcodeGen 專案定義
```

## 可調參數

- 斷線門檻：`StaleSignalMonitor.staleThreshold`（預設 60 秒）
- 軌跡檔：iPhone Documents/`watch-gps-track.json`

## 限制與注意

- 需 **GPS 機型** Apple Watch；室內或訊號差時精度會變差  
- 系統可能在極端省電／未佩戴時暫停定位；這正是通知要提醒檢查的情況  
- 本專案在 Linux CI 環境無法編譯執行，請在 Mac + 實機驗證  
- Bundle ID / Team 請依你的開發者帳號調整

## 授權

供學習與實作參考；請遵守 Apple 定位與健康資料使用規範。
