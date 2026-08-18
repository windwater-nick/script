# GitHub Release Software Downloader


一個簡單的 Python 工具，用來自動從 GitHub Release 下載指定軟體的最新版本。

透過 `soft-list.yaml` 定義要下載的軟體，以及 `include / exclude` 規則，程式會自動檢查 GitHub 最新 Release、篩選檔案並下載。

## 功能


- 自動取得 GitHub 最新正式 Release

- 支援多個軟體批次下載

- 支援 `include / exclude` 檔名篩選

- 自動判斷本地是否已有檔案

- 舊檔案自動移至 `old/` 資料夾

- 顯示下載進度

- 下載失敗自動重試

- 支援 GitHub API Token

- 顯示 GitHub API 剩餘額度

- 支援自訂下載目錄與 Timeout


## 系統需求


- Python 3.x

- 可連線至 Internet

- GitHub 公開 Repository


## 安裝


安裝必要的 Python 套件：

```
pip install requests pyyaml
```
或：

```
pip3 install requests pyyaml
```
## 檔案結構


```
.
├── downloader.py
├── config.yaml
├── soft-list.yaml
└── download/
```

|檔案 |說明 |
|:--|
|`downloader.py` |主程式 |
|`config.yaml` |程式設定 |
|`soft-list.yaml` |軟體下載清單 |
|`download/` |軟體下載目錄 |


## 設定


### config.yaml


建立 `config.yaml`：

```
download:
  dir: /home/download
  timeout: 30
  show_progress: true

  retry:
    count: 3
    delay: 5

github:
  api_key:
  timeout: 15
```
### Download 設定


|設定 |說明 |預設值 |
|:--|
|`download.dir` |下載目錄 |`./download` |
|`download.timeout` |單次下載 Timeout（秒） |`30` |
|`download.show_progress` |是否顯示下載進度 |`true` |
|`download.retry.count` |最大嘗試次數 |`3` |
|`download.retry.delay` |重試等待時間（秒） |`5` |


### GitHub 設定


|設定 |說明 |預設值 |
|:--|
|`github.api_key` |GitHub API Token |無 |
|`github.timeout` |GitHub API Timeout（秒） |`15` |


如果沒有設定 `github.api_key`，程式會使用 GitHub 匿名 API 存取。

建議長期使用時設定 GitHub Token，以取得較高的 API Rate Limit。

## 軟體清單


在 `soft-list.yaml` 定義要下載的軟體。

例如：

```
- name: Rufus
  repo: pbatard/rufus
  include:
    - "p.exe"
  exclude:
    - "x86"
    - ".sig"

- name: balenaEtcher
  repo: balena-io/etcher
  include:
    - "win32"
  exclude:
    - ".rpm"
    - ".deb"
    - ".dmg"
    - "Setup"
    - "darwin"
    - "arm"
    - "linux"
    - ".json"
    - "code"

- name: Ventoy
  repo: ventoy/Ventoy
  include:
    - "windows"
  exclude:
    - "linux"
    - ".txt"
    - ".iso"
    - "code"
```
### 欄位說明


|欄位 |說明 |
|:--|
|`name` |軟體名稱，同時作為下載資料夾名稱 |
|`repo` |GitHub Repository，例如 `pbatard/rufus` |
|`include` |檔名必須包含其中任一字串 |
|`exclude` |檔名包含其中任一字串時排除 |


`include` 與 `exclude` 比對時不分大小寫。

### 篩選規則


例如：

```
include:
  - "windows"

exclude:
  - "arm"
  - ".zip"
```
代表：

>檔名必須包含 `windows`，但如果同時包含 `arm` 或 `.zip`，則不下載。


如果沒有設定 `include`，則所有 Asset 都會符合，再套用 `exclude` 規則。

## 使用方式


直接執行：

```
python3 downloader.py
```
程式會依序執行：

```
讀取 config.yaml
      ↓
建立 GitHub Session
      ↓
檢查 GitHub API 狀態
      ↓
讀取 soft-list.yaml
      ↓
取得最新 Release
      ↓
篩選符合條件的 Assets
      ↓
檢查本地檔案
      ↓
需要更新？
  ├─ 否 → 顯示「已是最新版本」
  └─ 是
       ↓
    歸檔舊檔案
       ↓
    下載新檔案
```
## 下載結果


例如：

```
/home/download/
├── Rufus/
│   ├── rufus-x64.exe
│   └── old/
│       └── rufus-old.exe
│
├── balenaEtcher/
│   ├── balenaEtcher-win32-x64.exe
│   └── old/
│
└── Ventoy/
    ├── ventoy-windows.zip
    └── old/
```
當最新 Release 的檔案已經存在時：

```
已是最新版本
```
程式不會重複下載。

## 舊版本管理


當偵測到需要下載新版本時，程式會將目前軟體目錄中不屬於最新版本的檔案移至：

```
old/
```
例如：

```
Rufus/
├── rufus-new.exe
└── old/
    └── rufus-old.exe
```
舊版本不會直接刪除。

## GitHub API Token


如果需要設定 GitHub Token：

```
github:
  api_key: YOUR_GITHUB_TOKEN
```
程式啟動時會自動檢查：


- Token 是否有效

- GitHub 帳號

- API 剩餘額度

- API 額度重置時間


如果 Token 無效，程式會自動降級為匿名 API 存取。

## 執行畫面


啟動時可能看到：

```
============================================================
正在檢查 GitHub API KEY 狀態與剩餘額度...
[成功] API KEY 正確可用！ (使用者: username)
       剩餘存取次數: 4999 / 5000
       配額重置時間: 00:00:00
============================================================

== Rufus (pbatard/rufus) ==
下載: rufus-x64.exe
  └─ [████████████████████] 100.0% (1.5MB / 1.5MB)

== balenaEtcher (balena-io/etcher) ==
已是最新版本
```
## 錯誤處理


程式針對常見 GitHub HTTP 狀態提供中文提示：


|HTTP |說明 |
|:--|
|`401` |API Key / Token 無效或已過期 |
|`403` |已達 API 存取次數限制 |
|`404` |Repository 不存在或設為私有 |
|`422` |請求無法處理，可能沒有 Release |
|`500` |GitHub 伺服器內部錯誤 |
|`502` |GitHub Gateway 錯誤 |
|`503` |GitHub 服務暫時不可用 |


網路或 API 發生錯誤時，程式會依照 `retry` 設定自動重試。

## 注意事項


1. 程式使用 GitHub `releases/latest` API，主要取得最新正式 Release。

2. 沒有正式 Release 的 Repository 無法透過此程式下載。

3. `include` 採用「符合任一字串」的方式篩選。

4. `exclude` 優先於 `include`。

5. 檔名比對不分大小寫。

6. 下載前會將舊檔案移至 `old/`。

7. `retry.count` 目前代表**包含第一次下載在內的最大嘗試次數**。

8. `download.dir` 必須具有寫入權限。

9. GitHub API Token 建議不要直接提交至公開 Git Repository。


## License


請依專案需求自行設定 License。
