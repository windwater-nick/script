# ====================================================================
#  Main.ps1 - Archive Password Tester v2.0.2 (Facade / 主入口點)
# ====================================================================

[CmdletBinding()]
param ()

# --------------------------------------------------------------------
# 0. 環境與編碼初始化
# --------------------------------------------------------------------
$OutputEncoding = [System.Text.Encoding]::UTF8
[System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 載入共用庫 (SharedUtils.ps1)
$sharedUtilsPath = Join-Path $PSScriptRoot "src\SharedUtils.ps1"

if (-not (Test-Path $sharedUtilsPath)) {
    Write-Host "[ERROR] 找不到共用庫檔案：$sharedUtilsPath" -ForegroundColor Red
    Write-Host "請確認目錄架構是否完整 (需包含 src\SharedUtils.ps1)。" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
    Read-Host "請按 Enter 鍵離開..."
    return
}

. $sharedUtilsPath

# 標頭印出函式
function Show-Banner {
    Clear-Host
    Write-Host "====================================================================" -ForegroundColor Cyan
    Write-Host "                Archive Password Tester v2.0.2 (Facade)             " -ForegroundColor Cyan
    Write-Host "====================================================================" -ForegroundColor Cyan
}

# --------------------------------------------------------------------
# 1. 前置檢查：搜尋壓縮檔 (Fast-Fail 情境一 & 多檔案選單)
# --------------------------------------------------------------------
$archiveFiles = Get-ChildItem -Path $PSScriptRoot -File | Where-Object { 
    $ext = $_.Extension.ToLower()
    $ext -eq ".rar" -or $ext -eq ".7z" -or $ext -eq ".zip" 
}

# [Fast-Fail 情境一] 找不到任何壓縮檔
if (-not $archiveFiles -or $archiveFiles.Count -eq 0) {
    Show-Banner
    Write-Host ""
    Write-Host "[ERROR] 找不到任何支援的壓縮檔！" -ForegroundColor Red
    Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "  搜尋副檔名 : .rar, .7z, .zip" -ForegroundColor Yellow
    Write-Host "  搜尋目錄   : $PSScriptRoot" -ForegroundColor Yellow
    Write-Host "  建議動作   : 請將待測試的壓縮檔直接放入專案根目錄後重新執行。" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[系統] 程式已安全中斷執行。" -ForegroundColor Red
    Write-Host ""
    Read-Host "請按 Enter 鍵離開..."
    return
}

# 判定壓縮檔選擇 (單一 vs 多個)
$targetArchive = $null
if ($archiveFiles.Count -eq 1) {
    $targetArchive = $archiveFiles[0]
} else {
    Show-Banner
    Write-Host ""
    Write-Host "[?] 偵測到多個壓縮檔，請選擇要測試的目標：" -ForegroundColor Yellow
    for ($i = 0; $i -lt $archiveFiles.Count; $i++) {
        $fileSizeMB = [math]::Round($archiveFiles[$i].Length / 1MB, 2)
        Write-Host "    [$($i + 1)] $($archiveFiles[$i].Name) ($fileSizeMB MB)" -ForegroundColor White
    }
    
    $selection = 0
    while ($selection -lt 1 -or $selection -gt $archiveFiles.Count) {
        $inputVal = Read-Host "請選擇 (1-$($archiveFiles.Count))"
        if ([int]::TryParse($inputVal, [ref]$selection) -and $selection -ge 1 -and $selection -le $archiveFiles.Count) {
            $targetArchive = $archiveFiles[$selection - 1]
        } else {
            Write-Host "輸入無效，請輸入有效的編號！" -ForegroundColor Red
        }
    }
}

$archiveSizeMB = [math]::Round($targetArchive.Length / 1MB, 2)

# --------------------------------------------------------------------
# 2. 前置檢查：搜尋字典檔 (Fast-Fail 情境二 & 情境三)
# --------------------------------------------------------------------
$dictPath = Join-Path $PSScriptRoot "password-list.txt"

# [Fast-Fail 情境二] 找不到字典檔 password-list.txt
if (-not (Test-Path $dictPath)) {
    Show-Banner
    Write-Host "[+] 目標壓縮檔 : $($targetArchive.Name) ($archiveSizeMB MB)" -ForegroundColor Green
    Write-Host ""
    Write-Host "[ERROR] 找不到密碼字典檔！" -ForegroundColor Red
    Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "  缺失檔案   : password-list.txt" -ForegroundColor Yellow
    Write-Host "  預期路徑   : $dictPath" -ForegroundColor Yellow
    Write-Host "  建議動作   : 請將密碼字典檔命名為 password-list.txt 並放入專案根目錄。" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[系統] 程式已安全中斷執行。" -ForegroundColor Red
    Write-Host ""
    Read-Host "請按 Enter 鍵離開..."
    return
}

# 讀取字典檔並檢查內容
$dictLines = [System.IO.File]::ReadAllLines($dictPath, [System.Text.Encoding]::UTF8)
$dictCount = $dictLines.Count

# [Fast-Fail 情境三] 字典檔為空白檔 (0 Bytes / 0 行)
if ($dictCount -eq 0) {
    $dictItem = Get-Item $dictPath
    Show-Banner
    Write-Host "[+] 目標壓縮檔 : $($targetArchive.Name) ($archiveSizeMB MB)" -ForegroundColor Green
    Write-Host ""
    Write-Host "[ERROR] 密碼字典檔內容無效！" -ForegroundColor Red
    Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "  檔案名稱   : password-list.txt ($($dictItem.Length) Bytes)" -ForegroundColor Yellow
    Write-Host "  問題說明   : 字典檔內未填入任何待測試的密碼 (總行數為 0)。" -ForegroundColor Yellow
    Write-Host "  建議動作   : 請在 password-list.txt 中寫入密碼 (每行一筆) 後重新執行。" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[系統] 程式已安全中斷執行。" -ForegroundColor Red
    Write-Host ""
    Read-Host "請按 Enter 鍵離開..."
    return
}

# --------------------------------------------------------------------
# 3. 系統環境與解密引擎偵測
# --------------------------------------------------------------------
# 判定壓縮檔格式類型
$archiveType = switch ($targetArchive.Extension.ToLower()) {
    ".rar" { "rar" }
    ".7z"  { "7z" }
    ".zip" { "zip" }
    default { "unknown" }
}

$psVersion = $PSVersionTable.PSVersion.ToString()
$envInfo = Get-EnvironmentCapabilities -RootDir $PSScriptRoot

# --------------------------------------------------------------------
# 4. 輸出主介面儀表板
# --------------------------------------------------------------------
Show-Banner
Write-Host "[+] 目標壓縮檔 : $($targetArchive.Name) ($archiveSizeMB MB)" -ForegroundColor Green
Write-Host "[+] 密碼字典檔 : password-list.txt (共 $dictCount 筆)" -ForegroundColor Green
Write-Host "[+] 執行環境   : PowerShell $psVersion ($([System.Environment]::OSVersion.Platform))" -ForegroundColor Gray
Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray

# 格式化輸出引擎詳細資訊
$unrarDetail = if ($envInfo.UnRarPath) { "$($envInfo.UnRarStatus) [$($envInfo.UnRarArch.ToUpper()), $($envInfo.UnRarSource)]" } else { "[未找到]" }
$sevenZipDetail = if ($envInfo.SevenZipPath) { "$($envInfo.SevenZipStatus) [$($envInfo.SevenZipArch.ToUpper()), $($envInfo.SevenZipSource)]" } else { "[未找到]" }
$scDetail = if ($envInfo.SharpCompressPath) { "$($envInfo.SharpCompressStatus) [$($envInfo.SharpCompressSource)]" } else { "[未找到]" }

$unrarColor = if ($envInfo.UnRarPath) { "White" } else { "DarkGray" }
$sevenZipColor = if ($envInfo.SevenZipPath) { "White" } else { "DarkGray" }
$scColor = if ($envInfo.SharpCompressPath) { "White" } else { "DarkGray" }

Write-Host "[+] 主要解密引擎 : UnRAR $unrarDetail" -ForegroundColor $unrarColor
Write-Host "[+] 備用解密引擎 : 7-Zip $sevenZipDetail" -ForegroundColor $sevenZipColor
Write-Host "[+] .NET 輔助庫  : SharpCompress $scDetail" -ForegroundColor $scColor
Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray

# --------------------------------------------------------------------
# 5. 計算 MD5 驗證碼與 Checkpoint 比對
# --------------------------------------------------------------------
Write-Host "[*] 正在計算檔案 MD5 哈希值以進行進度比對..." -ForegroundColor DarkGray
$archiveMD5 = Get-FileMD5Hash -FilePath $targetArchive.FullName
$dictMD5    = Get-FileMD5Hash -FilePath $dictPath

$cpResult = Get-ValidCheckpoint -RootDir $PSScriptRoot -ArchiveType $archiveType -CurrentArchiveMD5 $archiveMD5 -CurrentDictMD5 $dictMD5

$startIndex = 0

if ($null -ne $cpResult -and $cpResult.Status -eq "VALID") {
    $startIndex = $cpResult.Data.LastTestedIndex
    $savedTime  = $cpResult.Data.UpdatedTime
    Write-Host "[★] 偵測到有效的歷史測試進度紀錄！" -ForegroundColor Yellow
    Write-Host "    └── 上次儲存時間 : $savedTime" -ForegroundColor Gray
    Write-Host "    └── 將從第 $startIndex 筆密碼自動繼續測試。" -ForegroundColor Yellow
} 
elseif ($null -ne $cpResult -and $cpResult.Status.StartsWith("INVALID")) {
    Write-Host "[!] 警告：找到先前 Checkpoint 但與當前檔案不符 (MD5 不一致)，將從頭開始。" -ForegroundColor Red
} 
else {
    Write-Host "[+] 未發現有效 Checkpoint 進度，將從第 0 筆開始全新測試。" -ForegroundColor Gray
}

# --------------------------------------------------------------------
# 6. 線程數配置設定
# --------------------------------------------------------------------
# 動態偵測當前 CPU 的邏輯核心數 (線程數)
$maxLogicalCores = [Environment]::ProcessorCount
$defaultThreads = [math]::Max(1, [math]::Min(4, $maxLogicalCores - 1)) # 預設保留 1 核避免系統卡頓

Write-Host ""
$inputThreads = Read-Host "[?] 請輸入要啟動的多線程數量 (1-$maxLogicalCores) [預設: $defaultThreads]"

$Threads = 0

if ([string]::IsNullOrWhiteSpace($inputThreads) -or -not [int]::TryParse($inputThreads, [ref]$Threads)) {
    $Threads = $defaultThreads
} else {
    # 限制輸入範圍在 1 到 當前 CPU 最大線程數 之間
    $Threads = [math]::Max(1, [math]::Min($Threads, $maxLogicalCores))
}

Write-Host "[+] 系統已配置 $Threads 個平行處理線程 (CPU 最大支援: $maxLogicalCores)。" -ForegroundColor Cyan
Start-Sleep -Seconds 1

# --------------------------------------------------------------------
# 7. 路由分派至專屬子腳本執行
# --------------------------------------------------------------------
$subScript = switch ($archiveType) {
    "rar" { "Test-RarArchive.ps1" }
    "7z"  { "Test-7zArchive.ps1" }
    "zip" { "Test-ZipArchive.ps1" }
}

$subScriptPath = Join-Path $PSScriptRoot "src\$subScript"

if (-not (Test-Path $subScriptPath)) {
    Write-Host "[ERROR] 找不到專屬格式處理腳本：$subScriptPath" -ForegroundColor Red
    Write-Host "--------------------------------------------------------------------" -ForegroundColor Gray
    Read-Host "請按 Enter 鍵離開..."
    return
}

# 組態參數雜湊表
$subParams = @{
    ArchivePath    = $targetArchive.FullName
    ArchiveMD5     = $archiveMD5
    DictionaryPath = $dictPath
    DictionaryMD5  = $dictMD5
    TotalPasswords = $dictCount
    Threads        = $Threads
    StartIndex     = $startIndex
    EngineEnv      = $envInfo
}

# 調用專屬子腳本執行測試
& $subScriptPath @subParams
